# common.sh — the generic (provider- and OS-agnostic) layer of the devbox CLI.
# Sourced by the `devbox` entrypoint. Holds helpers, profile/conf resolution, the
# orchestration subcommands, and the vault HTTP-API flow. Provider-specific code
# (DigitalOcean/Azure) lives under providers/, OS-specific code (Linux/Windows) under
# os/ — both are sourced by load_conf once the profile's PROVIDER/OS are known.
#
# Relies on SCRIPT_DIR being set by the entrypoint before this file is sourced.

# ---- profile + conf resolution ------------------------------------------
# A profile names a target (its config + provider + OS). Default 'linux' preserves the
# original single-box behavior: no flag => deploy/devbox.conf. Other profiles read
# deploy/targets/<profile>.conf. DEVBOX_CONF still overrides the path outright (back-compat).
DEVBOX_PROFILE="${DEVBOX_PROFILE:-linux}"

resolve_conf() {
  case "$DEVBOX_PROFILE" in
    ''|*[!a-zA-Z0-9._-]*) die "invalid profile name: '$DEVBOX_PROFILE' (use letters/digits/._-)" ;;
  esac
  if [ -n "${DEVBOX_CONF:-}" ]; then
    CONF=$DEVBOX_CONF
  elif [ "$DEVBOX_PROFILE" = linux ]; then
    CONF=$SCRIPT_DIR/devbox.conf                 # default profile == original path (back-compat)
  else
    CONF=$SCRIPT_DIR/targets/$DEVBOX_PROFILE.conf
  fi
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

load_conf() {
  [ -f "$CONF" ] || die "no config at $CONF for profile '$DEVBOX_PROFILE' (copy devbox.conf.example to devbox.conf, or add deploy/targets/$DEVBOX_PROFILE.conf)"
  # shellcheck disable=SC1090
  . "$CONF"
  # Provider/OS for this profile. Defaults keep the original linux profile working with a
  # devbox.conf that predates these keys (DigitalOcean + Linux). New profiles set them.
  : "${PROVIDER:=digitalocean}" "${OS:=linux}"
  case "$PROVIDER" in ''|*[!a-z]*) die "PROVIDER must be lowercase letters, got '$PROVIDER'";; esac
  case "$OS"       in ''|*[!a-z]*) die "OS must be lowercase letters, got '$OS'";; esac
  : "${DROPLET_NAME:?}" "${REGION:?}" "${SIZE:?}" "${IMAGE:?}" "${TAG:?}"
  : "${FIREWALL_NAME:?}" "${DEVBOX_USER:?}" "${SSH_PORT:?}" "${SSH_PUBKEY_FILES:?}"
  : "${REPO_URL:?}" "${REPO_BRANCH:?}" "${REPO_DIR:?}"
  # Validate the values that get interpolated into sed/ssh/cloud-init (guards L1).
  case "$SSH_PORT" in ''|*[!0-9]*) die "SSH_PORT must be numeric, got '$SSH_PORT'";; esac
  [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || die "SSH_PORT out of range"
  case "$DEVBOX_USER" in ''|*[!a-zA-Z0-9_-]*) die "DEVBOX_USER has invalid chars: '$DEVBOX_USER'";; esac
  # Vault defaults (used by `up` and `vault …`).
  : "${VAULT_MOUNT:=secret}"
  : "${SECRETS_DIR:=$HOME/devbox-secrets}"
  VAULT_KEYS_FILE="${VAULT_KEYS_FILE:-$HOME/.config/devbox/vault-keys.json}"
  # Optional: session-secrets manifest (maps vault projects -> app .env paths on the box).
  # If present, `configure`/`up` installs the login-time materializer (see os_install_session_secrets).
  SECRETS_MAP="${SECRETS_MAP:-$SCRIPT_DIR/secrets.map}"
  # Optional: auto-seal TTL. If set (systemd duration, e.g. 5min), the vault re-seals that
  # long after each unseal — a hard timer, reset on every unseal. Empty = off (stay unsealed).
  : "${AUTOSEAL_TTL:=}"
  # Alphanumeric only (e.g. 300, 5min, 1h) — it's interpolated into a systemd unit, so no
  # spaces/specials. Empty = off. systemd validates the actual duration when it loads.
  case "$AUTOSEAL_TTL" in
    *[!0-9a-zA-Z]*) die "AUTOSEAL_TTL invalid: '$AUTOSEAL_TTL' (single token like 300, 5min, 1h)" ;;
  esac
  # Provisioning resilience (bad-VM detector). DigitalOcean occasionally hands you a
  # droplet that boots "active" but is wedged at the hypervisor (no ping, no SSH, console
  # won't attach) — not a config problem. These knobs let `up` detect that fast (via a
  # scoped ICMP liveness probe) and recreate on a fresh host instead of a long timeout.
  : "${LIVENESS_PROBE:=on}"        # on|off — temporarily allow ICMP from your IP to probe liveness
  : "${LIVENESS_TIMEOUT:=240}"     # secs: no ping AND no SSH within this => declare bad VM
  : "${READINESS_TIMEOUT:=1200}"   # secs: overall budget for cloud-init to finish the install
  : "${PROVISION_ATTEMPTS:=2}"     # total create attempts (>1 => auto-recreate on a bad VM)
  : "${PROBE_INTERVAL:=10}"        # secs between probes
  : "${DEATH_STREAK:=6}"           # consecutive missed pings (after being alive) => died mid-install
  # Source this profile's provider + OS modules (names validated above, lowercase only).
  # Done here so every subcommand has the prov_*/os_* contract available after load_conf.
  if [ -z "${_MODULES_LOADED:-}" ]; then
    local provmod="$SCRIPT_DIR/providers/$PROVIDER.sh" osmod="$SCRIPT_DIR/os/$OS.sh"
    [ -f "$provmod" ] || die "no provider module for PROVIDER='$PROVIDER' ($provmod)"
    [ -f "$osmod" ]   || die "no OS module for OS='$OS' ($osmod)"
    # shellcheck disable=SC1090
    . "$provmod"; . "$osmod"; _MODULES_LOADED=1
  fi
}

# NON-forwarded ssh (no -A). Used to wait/verify/pin the host key, so the agent is
# never exposed to an unverified host on first contact (M2). accept-new pins the key
# on first use, then refuses a changed key thereafter.
ssh_box() {
  local ip=$1; shift
  ssh -p "$SSH_PORT" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "$DEVBOX_USER@$ip" "$@"
}


# ---- subcommands -----------------------------------------------------------

cmd_render() { load_conf; os_render_firstboot; }

# Wait until the box reports ready (OS-defined readiness), up to READINESS_TIMEOUT. No
# provider liveness probe here — that runs only during provisioning (prov_provision).
wait_box_ready() {
  local ip=$1 t0=$SECONDS
  log "waiting for $ip:$SSH_PORT to finish first-boot setup"
  while :; do
    os_box_ready "$ip" && { log "box is ready"; return 0; }
    [ $((SECONDS - t0)) -ge "$READINESS_TIMEOUT" ] && return 1
    sleep "$PROBE_INTERVAL"
  done
}

cmd_status() { load_conf; prov_ready; prov_status; }

cmd_down() {
  load_conf; prov_ready
  local yes=0; [ "${1:-}" = "--yes" ] && yes=1
  local ip; ip=$(prov_ip)
  [ -n "$ip" ] || log "no box named '$DROPLET_NAME' to destroy"
  if [ "$yes" -ne 1 ]; then
    printf 'Destroy box "%s" (%s) and firewall "%s"? [y/N] ' \
      "$DROPLET_NAME" "${ip:-none}" "$FIREWALL_NAME" >&2
    read -r ans; case "$ans" in y|Y|yes) ;; *) die "aborted" ;; esac
  fi
  prov_destroy "$ip"
}

# One command, end to end: provision (if absent) -> configure -> vault ready -> load all
# ~/devbox-secrets/<proj>.env. Idempotent: re-running an existing box re-converges.
cmd_up() {
  load_conf; prov_ready
  local ip
  if [ -n "$(prov_exists)" ]; then
    ip=$(prov_wait_ip) || die "box '$DROPLET_NAME' exists but has no public IP yet — wait a moment and re-run (NOT creating a duplicate)"
    log "box '$DROPLET_NAME' already exists at $ip"
    wait_box_ready "$ip" || die "existing box '$DROPLET_NAME' ($ip) is not becoming ready — it may be wedged; '$(basename "$0") down' then '$(basename "$0") up' to recreate"
  else
    prov_provision              # sets PROVISIONED_IP; auto-recreates on a bad VM; dies on failure
    ip="$PROVISIONED_IP"
  fi
  cmd_configure --host "$ip"
  VAULT_HOST="$ip"            # reuse this IP for the vault steps (no extra lookups)
  vault_bringup              # start OpenBao + init/unseal as needed
  vault_load_all             # push every ~/devbox-secrets/<proj>.env
  log "devbox ready — connect: $(basename "$0") ssh"
}

cmd_configure() {
  load_conf
  local host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) host=$2; shift 2 ;;
      --os)   [ "$2" = "$OS" ] || die "configure --os '$2' conflicts with profile '$DEVBOX_PROFILE' (OS=$OS) — use -p PROFILE to pick the target"; shift 2 ;;
      *) die "configure: unknown arg $1" ;;
    esac
  done
  if [ -z "$host" ]; then prov_ready; host=$(prov_ip); fi
  [ -n "$host" ] || die "no host — pass --host or provision first"
  # Pin the box host key WITHOUT forwarding the agent first, so the agent is never
  # exposed to an unverified host (M2). After this, -A uses strict verification.
  ssh_box "$host" 'exit 0'   # pin host key; 'exit 0' is a no-op in both bash and PowerShell
  log "configuring $DEVBOX_USER@$host (clone/pull repo + install config)"
  os_configure "$host"                # OS-specific: clone/pull + install + verify
  os_install_session_secrets "$host"  # opt-in: only if a local secrets.map exists
  log "done — connect with: $(basename "$0") ssh"
}

cmd_ssh() {
  load_conf
  local ip; ip=$(prov_ip 2>/dev/null || true)
  [ -n "$ip" ] || { prov_ready; ip=$(prov_ip); }
  [ -n "$ip" ] || die "no box named '$DROPLET_NAME'"
  ssh_box "$ip" 'exit 0'   # pin host key (no agent) before forwarding (M2); cross-shell no-op
  exec ssh -A -p "$SSH_PORT" -o StrictHostKeyChecking=yes "$DEVBOX_USER@$ip"
}

# ---- vault (prod-mode OpenBao on the box, gated by SSH) --------------------

resolve_host() {
  local h; h=$(prov_ip 2>/dev/null || true)
  [ -n "$h" ] || { prov_ready; h=$(prov_ip); }
  [ -n "$h" ] || die "no box named '$DROPLET_NAME'"
  printf '%s' "$h"
}

# Use the IP `up` already resolved (VAULT_HOST) if set, else look it up.
vault_host() { if [ -n "${VAULT_HOST:-}" ]; then printf '%s' "$VAULT_HOST"; else resolve_host; fi; }

# Convert a KEY=value .env file -> a flat JSON object (handles spaces/`=` in values).
# Runs on the laptop; jq does the escaping. Robust: lines that aren't a valid
# `NAME=value` (comments, blanks, junk) are skipped, not errored (capture(...)? ).
env_to_json() {
  command -v jq >/dev/null 2>&1 || die "jq not found on this machine"
  jq -Rn '
    [ inputs
      | capture("^\\s*(?:export\\s+)?(?<k>[A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(?<v>.*?)\\r?$")?
    ] | map({(.k): .v}) | add // {}
  ' "$1"
}

# ---- auto-seal TTL (optional) -----------------------------------------------
# OpenBao has no native unseal TTL, so a systemd timer on the box re-seals it N after each
# unseal. Sealing needs sudo-on-sys/seal, which the scoped devbox-app token lacks — so we
# mint a SEAL-ONLY token (policy: sys/seal only; cannot read any secret) for the timer to
# use. Root stays on the laptop; the box gains only the ability to LOCK, never to read.

# Mint the seal-only token on the box (idempotent — only if absent), using the laptop's
# root token over stdin (never on argv, never stored on the box).
ensure_sealer_token() {
  local host=$1
  [ -f "$VAULT_KEYS_FILE" ] || die "no $VAULT_KEYS_FILE — can't mint the seal-only token (init first)"
  local root; root=$(jq -r '.root_token' "$VAULT_KEYS_FILE")
  [ -n "$root" ] && [ "$root" != null ] || die "could not read root token from $VAULT_KEYS_FILE"
  # Inline command (NOT a heredoc) so the root token piped on stdin reaches `$(cat)`; the
  # policy goes via a temp file (not secret) so it doesn't compete for stdin. Token stays
  # off argv. Idempotent: no-op if a seal-token already exists.
  printf '%s' "$root" | ssh_box "$host" '
    set -eu; umask 077
    export BAO_ADDR=http://127.0.0.1:8200
    tf="$HOME/.config/devbox/seal-token"
    [ -s "$tf" ] && exit 0
    export BAO_TOKEN="$(cat)"
    mkdir -p "$HOME/.config/devbox"
    pol=$(mktemp)
    printf "%s" "path \"sys/seal\" { capabilities = [\"update\",\"sudo\"] }" > "$pol"
    bao policy write devbox-sealer "$pol" >/dev/null
    rm -f "$pol"
    tok=$(bao token create -policy=devbox-sealer -period=768h -format=json | jq -r .auth.client_token)
    [ -n "$tok" ] && [ "$tok" != null ] || { echo SEALER_TOKEN_FAILED >&2; exit 1; }
    printf "%s" "$tok" > "$tf"; chmod 600 "$tf"
  '
}

# Bring the vault to READY: start the server, then init (fresh box) or unseal (sealed)
# as needed. Idempotent. Used by both `up` and `vault up`.
vault_bringup() {
  local host; host=$(vault_host)
  log "bringing up the vault on $host"
  local status err inited sealed
  status=$(os_vault_start "$host")
  err=$(printf '%s' "$status" | jq -r '.error // empty' 2>/dev/null || true)
  [ -z "$err" ] || die "vault: $err (see ~/.config/devbox/openbao.log on the box)"
  # NB: jq '//' treats boolean false as empty, so read raw and compare explicitly:
  # initialized only if exactly "true"; sealed unless exactly "false".
  inited=$(printf '%s' "$status" | jq -r '.initialized' 2>/dev/null || echo false)
  sealed=$(printf '%s' "$status" | jq -r '.sealed'      2>/dev/null || echo true)
  if   [ "$inited" != "true"  ]; then vault_init
  elif [ "$sealed" != "false" ]; then vault_unseal
  else log "vault already initialized + unsealed."; fi
  os_autoseal_arm "$host"   # (re)arm the auto-seal timer if AUTOSEAL_TTL is set
}

# `devbox vault up` — same readiness as part of `devbox up`.
vault_up() { vault_bringup; }

# Push every ~/devbox-secrets/<project>.env into the vault (used by `up`).
vault_load_all() {
  [ -d "$SECRETS_DIR" ] || { log "no secrets dir ($SECRETS_DIR) — skipping secret load"; return 0; }
  local any=0 f
  for f in "$SECRETS_DIR"/*.env; do
    [ -e "$f" ] || continue
    any=1
    vault_load "$(basename "$f" .env)"
  done
  [ "$any" = 1 ] || log "no <project>.env files in $SECRETS_DIR — skipping secret load"
}

# First time on a box: initialize (single unseal key), unseal, enable the kv mount,
# install the root token on the box, and save the unseal key + root token to the
# LAPTOP keys file. Re-init per box: a fresh box gets fresh keys.
vault_init() {
  command -v jq >/dev/null 2>&1 || die "jq not found on this machine"
  local host; host=$(vault_host)
  ssh_box "$host" 'exit 0'   # pin host key; 'exit 0' is a no-op in both bash and PowerShell
  log "initializing + unsealing vault on $host (1 key share, single unseal key)"
  local out
  out=$(ssh_box "$host" 'bash -s' <<'EOF'
set -eu
umask 077
export BAO_ADDR="http://127.0.0.1:8200"
st=$(curl -fsS "$BAO_ADDR/v1/sys/seal-status" 2>/dev/null) || { echo "SERVER_NOT_UP" >&2; exit 4; }
[ "$(printf '%s' "$st" | jq -r '.initialized')" = "false" ] || { echo "ALREADY_INITIALIZED" >&2; exit 3; }
# Init output (unseal key + root token) stays in box memory; never on argv.
out=$(bao operator init -key-shares=1 -key-threshold=1 -format=json)
unseal=$(printf '%s' "$out" | jq -r '.unseal_keys_b64[0]')
roottok=$(printf '%s' "$out" | jq -r '.root_token')
# OpenBao's `operator unseal -` treats '-' as a LITERAL key (no stdin support), and the
# no-arg form demands a TTY — so unseal via the HTTP API with the key in the JSON body
# fed on stdin (-d @-). The key stays off argv (E5); it never appears in ps/cmdline.
printf '{"key":"%s"}' "$unseal" | curl -fsS -X PUT -d @- "$BAO_ADDR/v1/sys/unseal" >/dev/null
[ "$(curl -fsS "$BAO_ADDR/v1/sys/seal-status" | jq -r '.sealed')" = "false" ] || { echo "UNSEAL_FAILED" >&2; exit 6; }
export BAO_TOKEN="$roottok"                                      # root used only for setup, here
bao secrets enable -path=secret kv-v2 >/dev/null                 # fail loud (L3): no '|| true'
# Least-privilege (M2): a policy scoped to the kv mount + a token bound to it. The BOX
# gets this scoped token (not root); root stays only in the laptop keys file.
printf 'path "secret/data/*" { capabilities = ["create","read","update","delete"] }\npath "secret/metadata/*" { capabilities = ["read","list","delete"] }\n' \
  | bao policy write devbox-app - >/dev/null
apptok=$(bao token create -policy=devbox-app -period=768h -format=json | jq -r '.auth.client_token')
[ -n "$apptok" ] && [ "$apptok" != "null" ] || { echo "TOKEN_CREATE_FAILED" >&2; exit 5; }
mkdir -p "$HOME/.config/devbox"
printf 'export BAO_ADDR=%s\nexport BAO_TOKEN=%s\n' "$BAO_ADDR" "$apptok" > "$HOME/.config/devbox/vault.env"
printf '%s' "$apptok" > "$HOME/.bao-token"
printf '%s' "$out"                                                # emit init JSON (root+unseal) for the laptop
EOF
) || die "vault init failed — is the server up ('$(basename "$0") vault up') and not already initialized ('$(basename "$0") vault unseal')?"
  [ -n "$out" ] || die "vault init produced no keys"
  umask 077; mkdir -p "$(dirname "$VAULT_KEYS_FILE")"
  printf '%s' "$out" > "$VAULT_KEYS_FILE"
  chmod 600 "$VAULT_KEYS_FILE"   # assert 0600 even if the file pre-existed (L4)
  log "vault initialized + unsealed. Keys saved to $VAULT_KEYS_FILE"
  warn "KEEP $VAULT_KEYS_FILE SAFE — it holds this box's unseal key + root token (the box itself only has a scoped token)."
}

# Re-unseal an already-initialized box (e.g. after a reboot) using the saved key.
vault_unseal() {
  command -v jq >/dev/null 2>&1 || die "jq not found on this machine"
  local host; host=$(vault_host)
  ssh_box "$host" 'exit 0'   # pin host key; 'exit 0' is a no-op in both bash and PowerShell
  # The server must be up to accept an unseal. With the systemd unit it auto-starts
  # (sealed) on boot; if it's somehow down, point at `vault up` instead of a raw curl error.
  ssh_box "$host" 'curl -fsS --max-time 5 http://127.0.0.1:8200/v1/sys/seal-status >/dev/null 2>&1' \
    || die "the vault server isn't responding on $host — run '$(basename "$0") vault up' (it starts the server, then unseals)"
  if [ ! -f "$VAULT_KEYS_FILE" ]; then
    # No saved key. If the box's vault is nonetheless initialized, the unseal key was
    # lost (e.g. init's SSH stream dropped before save) → it's unrecoverable (M1).
    local inited
    inited=$(ssh_box "$host" 'curl -fsS http://127.0.0.1:8200/v1/sys/seal-status 2>/dev/null' 2>/dev/null \
      | jq -r '.initialized' 2>/dev/null || echo unknown)
    [ "$inited" != "true" ] || die "this box's vault is initialized but no unseal key is saved at $VAULT_KEYS_FILE — it is UNRECOVERABLE. Tear down and re-provision: $(basename "$0") down, then up, then vault init"
    die "no saved keys at $VAULT_KEYS_FILE — init this box first: $(basename "$0") vault init"
  fi
  local unseal; unseal=$(jq -r '.unseal_keys_b64[0]' "$VAULT_KEYS_FILE")
  [ -n "$unseal" ] && [ "$unseal" != "null" ] || die "could not read unseal key from $VAULT_KEYS_FILE"
  # Unseal via the HTTP API (key in the JSON body on stdin) — OpenBao's CLI `unseal -`
  # treats '-' as a literal key and the no-arg form needs a TTY. Key stays off argv (E5).
  local resp
  resp=$(printf '{"key":"%s"}' "$unseal" | ssh_box "$host" \
    'curl -fsS -X PUT -d @- http://127.0.0.1:8200/v1/sys/unseal')
  [ "$(printf '%s' "$resp" | jq -r '.sealed' 2>/dev/null)" = "false" ] \
    || die "unseal failed (vault still sealed) — verify the key in $VAULT_KEYS_FILE matches this box"
  log "vault unsealed."
  os_autoseal_arm "$host"   # (re)arm the auto-seal timer if AUTOSEAL_TTL is set
}

# Push a project's local .env into the box's vault at <mount>/<project>.
vault_load() {
  local proj=${1:-}; [ -n "$proj" ] || die "usage: $(basename "$0") vault load <project>"
  case "$proj"        in ''|-*|*[!a-zA-Z0-9._-]*) die "invalid project name: '$proj'";; esac
  case "$VAULT_MOUNT" in ''|-*|*[!a-zA-Z0-9._-]*) die "invalid VAULT_MOUNT: '$VAULT_MOUNT'";; esac
  local f="$SECRETS_DIR/$proj.env"
  [ -f "$f" ] || die "no secrets file at $f"
  local host json; host=$(vault_host)
  json=$(env_to_json "$f") || die "failed to parse $f"
  ssh_box "$host" 'exit 0'   # pin host key; 'exit 0' is a no-op in both bash and PowerShell
  # Friendly pre-check: a sealed vault would otherwise give a raw 503 (L1).
  local sealed
  sealed=$(ssh_box "$host" 'curl -fsS http://127.0.0.1:8200/v1/sys/seal-status 2>/dev/null' 2>/dev/null \
    | jq -r '.sealed' 2>/dev/null || echo unknown)
  [ "$sealed" != "true" ] || die "vault is sealed — run: $(basename "$0") vault unseal"
  log "loading $f -> vault $VAULT_MOUNT/$proj on $host"
  # The JSON travels on STDIN (in memory — never written to the box's disk). The remote
  # command is inline (NOT a heredoc), so stdin stays free to carry the data into
  # `bao kv put -`. proj/mount are validated above, so inlining them is safe.
  printf '%s' "$json" | ssh_box "$host" \
    "set -eu; . \"\$HOME/.config/devbox/vault.env\" 2>/dev/null || { echo 'vault not up; run: devbox vault up' >&2; exit 1; }; exec bao kv put -mount='$VAULT_MOUNT' '$proj' -" \
    >/dev/null
  log "loaded. On the box: bao kv get -mount=$VAULT_MOUNT $proj"
}

# Push local .env(s) into the vault, then re-materialize them on the box for any
# active login session by restarting the session-secrets user service. With no
# project, refreshes every ~/devbox-secrets/*.env. The on-box restart is best
# effort: with no active session there is nothing to re-materialize — secrets
# land on the next login anyway. This saves a logout/login round-trip when you've
# edited a .env and want a live session to see the new values.
vault_refresh() {
  local proj=${1:-}
  if [ -n "$proj" ]; then
    vault_load "$proj"
  else
    vault_load_all
  fi
  local host; host=$(vault_host)
  log "re-materializing secrets for any active session on $host"
  ssh_box "$host" 'bash -s' <<'EOF'
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
# No user manager == no live session; secrets materialize fresh on next login.
if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "devbox-secrets: no active login session — secrets will materialize on next login"
  exit 0
fi
if systemctl --user restart devbox-secrets.service 2>/dev/null; then
  echo "devbox-secrets: re-materialized for the active session"
else
  echo "devbox-secrets: service not installed or restart failed — check 'systemctl --user status devbox-secrets'" >&2
fi
EOF
}

vault_status() {
  local host; host=$(vault_host)
  ssh_box "$host" 'exit 0'   # pin host key; 'exit 0' is a no-op in both bash and PowerShell
  ssh_box "$host" 'export BAO_ADDR="http://127.0.0.1:8200"
    s=$(curl -fsS "$BAO_ADDR/v1/sys/seal-status" 2>/dev/null) || { echo "OpenBao: not running — run: devbox vault up"; exit 0; }
    echo "OpenBao: running (localhost-only); initialized=$(printf "%s" "$s" | jq -r .initialized) sealed=$(printf "%s" "$s" | jq -r .sealed)"'
}

cmd_vault() {
  load_conf   # sets VAULT_MOUNT / SECRETS_DIR / VAULT_KEYS_FILE defaults
  local action=${1:-}; shift || true
  case "$action" in
    up)      vault_up ;;
    init)    vault_init ;;
    unseal)  vault_unseal ;;
    load)    vault_load "$@" ;;
    refresh) vault_refresh "$@" ;;
    status)  vault_status ;;
    *) die "usage: $(basename "$0") vault up | init | unseal | load <project> | refresh [project] | status" ;;
  esac
}

# Install the project build toolchain on the box (Layer B). Separate from `up` because it's
# long (~20-30 min) and project-specific; run it once after the box is configured.
cmd_toolchain() {
  load_conf
  local host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) host=$2; shift 2 ;;
      *) die "toolchain: unknown arg $1" ;;
    esac
  done
  if [ -z "$host" ]; then prov_ready; host=$(prov_ip); fi
  [ -n "$host" ] || die "no host — pass --host or provision first"
  ssh_box "$host" 'exit 0'   # pin host key before the install
  os_install_toolchain "$host"
  log "toolchain install complete"
}

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  # Global flags before the subcommand: -p/--profile selects the target (default 'linux').
  while [ $# -gt 0 ]; do
    case "${1:-}" in
      -p|--profile) [ $# -ge 2 ] || die "-p/--profile needs a value"; DEVBOX_PROFILE=$2; shift 2 ;;
      --profile=*)  DEVBOX_PROFILE=${1#*=}; shift ;;
      -p?*)         DEVBOX_PROFILE=${1#-p}; shift ;;
      *) break ;;
    esac
  done
  resolve_conf
  local sub=${1:-help}; shift || true
  case "$sub" in
    up)        cmd_up "$@" ;;
    configure) cmd_configure "$@" ;;
    ssh)       cmd_ssh "$@" ;;
    status)    cmd_status "$@" ;;
    render)    cmd_render "$@" ;;
    toolchain) cmd_toolchain "$@" ;;
    vault)     cmd_vault "$@" ;;
    down)      cmd_down "$@" ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command: $sub" ;;
  esac
}
