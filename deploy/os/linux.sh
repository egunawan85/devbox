# os/linux.sh — Linux (Ubuntu) OS module for the devbox CLI. Implements the OS contract
# (os_*) that lib/common.sh calls; sourced after common.sh when OS=linux. Holds the
# cloud-init first-boot render, the readiness probe, the session-secrets materializer
# (tmpfs + logind), and the OpenBao vault lifecycle (systemd unit + auto-seal timer).
# Depends on helpers from common.sh (log/warn/die, ssh_box) — common is sourced first.

# The Linux first-boot template this module renders. SCRIPT_DIR is set by the entrypoint.
TEMPLATE="$SCRIPT_DIR/cloud-init.yaml"

render_cloud_init() { # -> stdout
  local f keys=""
  for f in $SSH_PUBKEY_FILES; do
    [ -f "$f" ] || die "ssh public key not found: $f"
    keys="${keys}      - $(cat "$f")
"
  done
  # Inject the key block at the marker via awk ENVIRON (handles multi-line cleanly,
  # unlike -v; no temp file to leak — L2), then substitute the simple scalars
  # (validated in load_conf, so no sed-injection — L1).
  local out
  out=$(KEYS_BLOCK="$keys" awk '
    $0 == "__AUTHORIZED_KEYS_BLOCK__" { printf "%s", ENVIRON["KEYS_BLOCK"]; next }
    { print }
  ' "$TEMPLATE" \
    | sed -e "s/__DEVBOX_USER__/$DEVBOX_USER/g" -e "s/__SSH_PORT__/$SSH_PORT/g")
  # Guard: a single non-ASCII byte (smart quote, em-dash, NBSP) makes DO's cloud-init
  # datasource reject the ENTIRE user-data as "empty cloud config" -- silently skipping
  # the users block, packages, and runcmd. Fail loudly here instead of shipping a box
  # that boots without the eddyg user or toolchain. (LC_ALL=C + POSIX classes so this
  # works on BSD grep too -- `grep -P` is GNU-only and not present on macOS.)
  local nonascii
  nonascii=$(printf '%s' "$out" | LC_ALL=C grep -n '[^[:print:][:space:]]' || true)
  if [ -n "$nonascii" ]; then
    printf '%s\n' "$nonascii" >&2
    die "rendered cloud-init contains non-ASCII byte(s) (see line(s) above) -- DO's cloud-init would silently discard the whole config. Replace them with ASCII."
  fi
  printf '%s\n' "$out"
}

# os_box_ready HOST — 0 when first-boot is complete: cloud-init done AND the devbox-ready
# marker present. Probed over SSH (non-blocking) so the provider can interleave a liveness
# probe during provisioning. This is the OS-defined readiness signal (contract).
os_box_ready() {
  ssh_box "$1" 'cloud-init status 2>/dev/null | grep -q "status: done" && test -f /var/lib/cloud/devbox-ready' 2>/dev/null
}

# ---- session secrets (login-time vault -> app .env / raw file on tmpfs) -----
# Optional feature, opt-in by the presence of a local secrets.map. On SSH login it
# materializes each mapped vault project into its dest path — KEY=value lines for an
# env project, verbatim bytes for a file-mode one (reserved __file__ key) — as a
# symlink into /dev/shm tmpfs (RAM, never disk); on the LAST logout/disconnect it
# wipes them.
# Lifecycle is a systemd *user* service: logind keeps the user manager alive while any
# session exists and stops it at the last one (incl. dropped connections), so cleanup is
# reference-counted natively. The vault must be unsealed (from the laptop) first.

# Validate + normalize the local manifest -> "<project> <abs-dest>" lines on stdout.
validate_secrets_map() {
  local f=$1 proj dest rest out=""
  while read -r proj dest rest || [ -n "$proj" ]; do   # || ... = also process a final line with no trailing newline
    case "$proj" in ''|\#*) continue ;; esac
    [ -n "$dest" ] || { echo "secrets.map: project '$proj' has no dest path" >&2; return 1; }
    case "$proj" in *[!a-zA-Z0-9._-]*) echo "secrets.map: invalid project name '$proj'" >&2; return 1 ;; esac
    case "$dest" in /*) ;; *) echo "secrets.map: dest must be an absolute path: '$dest'" >&2; return 1 ;; esac
    case "$dest" in *..*) echo "secrets.map: dest must not contain '..': '$dest'" >&2; return 1 ;; esac
    out="${out}${proj} ${dest}
"
  done < "$f"
  printf '%s' "$out"
}

install_session_secrets() {
  local host=$1
  [ -f "$SECRETS_MAP" ] || { log "no secrets.map at $SECRETS_MAP — skipping session-secrets setup"; return 0; }
  local clean; clean=$(validate_secrets_map "$SECRETS_MAP") || die "invalid $SECRETS_MAP (see above)"
  [ -n "$clean" ] || { log "secrets.map has no mappings — skipping session-secrets setup"; return 0; }
  ssh_box "$host" 'true'
  log "installing session-secrets (login-time vault -> .env/file materialization) on $host"
  # 1) static hook script + systemd user unit + enable (idempotent).
  ssh_box "$host" 'bash -s' <<'EOF'
set -eu
mkdir -p "$HOME/.config/devbox" "$HOME/.config/systemd/user/default.target.wants"
cat > "$HOME/.config/devbox/session-secrets.sh" <<'HOOK'
#!/usr/bin/env bash
# devbox session-secrets: vault -> app .env / raw file on tmpfs (RAM) while logged in;
# wiped at last logout. Driven by ~/.config/devbox/secrets.map. Managed by
# devbox-secrets.service.
set -uo pipefail
RAM=/dev/shm/devbox-secrets
MAP="$HOME/.config/devbox/secrets.map"
ENVF="$HOME/.config/devbox/vault.env"
[ -f "$MAP" ] || exit 0
case "${1:-}" in
  in)
    [ -f "$ENVF" ] || exit 0
    . "$ENVF"
    if ! curl -fsS --max-time 3 "$BAO_ADDR/v1/sys/seal-status" 2>/dev/null | jq -e '.sealed==false' >/dev/null 2>&1; then
      echo "devbox-secrets: vault sealed/down — unseal from your laptop, then: systemctl --user restart devbox-secrets" >&2
      exit 0
    fi
    # The token is periodic (768h): renew on every materialization so routine use keeps
    # it alive. A dead one heals on the next laptop unseal (ensure_app_token).
    bao token renew >/dev/null 2>&1 \
      || echo "devbox-secrets: token renew failed (expired?) — run 'devbox vault unseal' from the laptop to re-issue it" >&2
    mkdir -p "$RAM"; chmod 700 "$RAM"
    while read -r proj dest rest || [ -n "$proj" ]; do   # || ... = also handle a final line with no trailing newline
      case "$proj" in ''|\#*) continue ;; esac
      [ -n "${dest:-}" ] || continue
      if [ -e "$dest" ] && [ ! -L "$dest" ]; then
        echo "devbox-secrets: $dest exists and is not our symlink — skipping (move it aside to use the vault copy)" >&2
        continue
      fi
      # </dev/null: don't let bao drain the MAP lines from the loop's stdin.
      json=$(bao kv get -mount=secret -format=json "$proj" 2>/dev/null </dev/null)
      if [ -z "$json" ]; then
        echo "devbox-secrets: could not read secret/$proj — skipping (is it loaded?)" >&2
        continue
      fi
      # File mode (reserved __file__ key, base64 raw bytes): decode verbatim; the
      # project name already carries the real extension, so no .env suffix.
      # Env mode: rebuild KEY=value lines, as always.
      if printf '%s' "$json" | jq -e '.data.data | has("__file__")' >/dev/null 2>&1; then
        out="$RAM/$proj"
        if ! ( umask 077; printf '%s' "$json" | jq -r '.data.data.__file__' | base64 -d > "$out" ) || [ ! -s "$out" ]; then
          echo "devbox-secrets: could not decode file-mode secret/$proj — skipping" >&2
          rm -f "$out"; continue
        fi
      else
        out="$RAM/$proj.env"
        if ! ( umask 077; printf '%s' "$json" | jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' > "$out" ) || [ ! -s "$out" ]; then
          echo "devbox-secrets: could not parse secret/$proj — skipping" >&2
          rm -f "$out"; continue
        fi
      fi
      mkdir -p "$(dirname "$dest")"
      ln -sfn "$out" "$dest"
    done < "$MAP"
    ;;
  out)
    while read -r proj dest rest || [ -n "$proj" ]; do
      case "$proj" in ''|\#*) continue ;; esac
      [ -n "${dest:-}" ] || continue
      [ -L "$dest" ] && rm -f "$dest"          # only remove OUR symlink, never a real file
      rm -f "$RAM/$proj.env" "$RAM/$proj"      # env-mode and file-mode names; at most one exists
    done < "$MAP"
    rmdir "$RAM" 2>/dev/null || true
    ;;
  *) echo "usage: session-secrets.sh in|out" >&2; exit 2 ;;
esac
HOOK
chmod 700 "$HOME/.config/devbox/session-secrets.sh"
cat > "$HOME/.config/systemd/user/devbox-secrets.service" <<'UNIT'
[Unit]
Description=Materialize devbox vault secrets to tmpfs while logged in

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=%h/.config/devbox/session-secrets.sh in
ExecStop=%h/.config/devbox/session-secrets.sh out

[Install]
WantedBy=default.target
UNIT
# Enable by hand (robust without an active user manager): symlink into default.target.wants.
ln -sf "$HOME/.config/systemd/user/devbox-secrets.service" \
       "$HOME/.config/systemd/user/default.target.wants/devbox-secrets.service"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user start devbox-secrets.service 2>/dev/null || true   # materialize now for this session
loginctl disable-linger "$(id -un)" 2>/dev/null || true             # stop user mgr at last logout
EOF
  # 2) push the validated manifest (data) over stdin, owner-only. Trailing newline matters:
  # $(...) stripped it from $clean, and `while read` would skip an unterminated final line.
  printf '%s\n' "$clean" | ssh_box "$host" 'umask 077; cat > "$HOME/.config/devbox/secrets.map"'
  log "session-secrets installed — on login each mapped project materializes to its .env (tmpfs); wiped at last logout."
}

# Start the OpenBao server on the box: prod mode, `file` storage (encrypted at rest),
# listener bound to 127.0.0.1 only (SSH login is the access gate — E1). Echoes the
# seal-status JSON (or {"error":...}). Idempotent.
#
# Runs under a systemd unit (devbox-vault.service) so the vault AUTO-STARTS — sealed —
# on every boot. That's the fix for the reboot gap: previously `bao server` was nohup'd
# and died on reboot, so `vault unseal` hit a dead server; now the server is back up
# (sealed) after a reboot and `vault unseal` reopens it from your laptop key as designed.
vault_start() {
  local host=$1
  ssh_box "$host" 'true'
  ssh_box "$host" 'bash -s' <<'EOF'
set -eu
umask 077                                   # owner-only files/dirs
command -v bao >/dev/null 2>&1 || { echo '{"error":"bao not installed"}'; exit 0; }
me=$(id -un)
cfgdir="$HOME/.config/devbox"
mkdir -p "$cfgdir/openbao-data"
cfg="$cfgdir/openbao.hcl"
if [ ! -f "$cfg" ]; then
  cat > "$cfg" <<HCL
storage "file" {
  path = "$cfgdir/openbao-data"
}
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
disable_mlock = true
ui            = false
HCL
fi
# Install/refresh the systemd unit (idempotent: only rewrite + reload if changed).
baobin=$(command -v bao)
unit=/etc/systemd/system/devbox-vault.service
want="[Unit]
Description=devbox OpenBao vault (prod mode, localhost-only)
After=network-online.target
Wants=network-online.target

[Service]
User=$me
ExecStart=$baobin server -config=$cfg
Restart=on-failure
RestartSec=2
StandardOutput=append:$cfgdir/openbao.log
StandardError=append:$cfgdir/openbao.log

[Install]
WantedBy=multi-user.target"
if [ "$(sudo cat "$unit" 2>/dev/null || true)" != "$want" ]; then
  printf '%s\n' "$want" | sudo tee "$unit" >/dev/null
  sudo systemctl daemon-reload
fi
sudo systemctl enable devbox-vault >/dev/null 2>&1 || true   # start sealed on every boot
export BAO_ADDR="http://127.0.0.1:8200"
# Ensure it's running under systemd. If a legacy nohup instance holds the port (older
# boxes), clear it first so systemd can bind — systemd then owns it across reboots.
if ! systemctl is-active --quiet devbox-vault; then
  pkill -f 'bao server' 2>/dev/null || true
  sleep 1
  sudo systemctl start devbox-vault || true
  for i in $(seq 1 30); do curl -fsS "$BAO_ADDR/v1/sys/seal-status" >/dev/null 2>&1 && break; sleep 0.5; done
fi
curl -fsS "$BAO_ADDR/v1/sys/seal-status" 2>/dev/null \
  || echo '{"error":"server not responding (check: journalctl -u devbox-vault, or '"$cfgdir"'/openbao.log)"}'
EOF
}

# Arm/refresh the auto-seal timer. No-op if AUTOSEAL_TTL is empty. Call after each unseal.
autoseal_arm() {
  local host=$1
  [ -n "${AUTOSEAL_TTL:-}" ] || return 0
  ensure_sealer_token "$host"
  ssh_box "$host" "AUTOSEAL_TTL='$AUTOSEAL_TTL' bash -s" <<'EOF'
set -eu
home="$HOME"; baobin="$(command -v bao)"
svc=/etc/systemd/system/devbox-vault-autoseal.service
tmr=/etc/systemd/system/devbox-vault-autoseal.timer
wantsvc="[Unit]
Description=devbox auto-seal the vault (TTL after unseal)
[Service]
Type=oneshot
User=$(id -un)
ExecStart=/bin/sh -c 'BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=\"\$(cat $home/.config/devbox/seal-token)\" exec $baobin operator seal'"
wanttmr="[Timer]
OnActiveSec=$AUTOSEAL_TTL
AccuracySec=1s"
changed=0
[ "$(sudo cat "$svc" 2>/dev/null || true)" = "$wantsvc" ] || { printf '%s\n' "$wantsvc" | sudo tee "$svc" >/dev/null; changed=1; }
[ "$(sudo cat "$tmr" 2>/dev/null || true)" = "$wanttmr" ] || { printf '%s\n' "$wanttmr" | sudo tee "$tmr" >/dev/null; changed=1; }
[ "$changed" = 0 ] || sudo systemctl daemon-reload
sudo systemctl restart devbox-vault-autoseal.timer    # (re)start the countdown from now
EOF
  log "auto-seal armed — vault re-seals ${AUTOSEAL_TTL} after unseal (timer reset now)"
}

# ---- machine identity (box-to-box SSH — spec A6) ----------------------------
# Every Linux box gets its OWN resident ed25519 keypair at ~/.ssh/id_ed25519: the box is
# the SSH *client* that drives other deployments (e.g. the win-test appliance), and an
# unattended run — a scheduled /win-test with no human logged in — has no forwarded agent
# to lean on. The key is generated ON the box (never a copy of a device key) and has NO
# passphrase (an unattended client has no keychain/human to unlock one); the compensating
# controls are scope + revocability — it grants only what explicitly authorizes its
# pubkey, and removing that pubkey from a target's authorized_keys revokes it.
# Idempotent (D3): generate only if absent; NEVER overwrite an existing key; re-derive a
# missing .pub from the private half. Lives in configure (not cloud-init) so both a
# fresh box (`up` runs configure) and an already-deployed box (its next configure/up)
# converge on it from one implementation.
ensure_machine_identity() {
  local host=$1
  log "ensuring machine SSH identity on $host (~/.ssh/id_ed25519)"
  ssh_box "$host" 'bash -s' <<'EOF'
set -eu
umask 077
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
key="$HOME/.ssh/id_ed25519"
if [ ! -f "$key" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$key" -C "devbox-machine@$(hostname)"
  echo "machine-identity: generated $key (ed25519, no passphrase)"
elif [ ! -f "$key.pub" ]; then
  # -P '' supplies the (empty) passphrase non-interactively; a passphrase-protected
  # private key fails loudly here instead of hanging on a prompt.
  ssh-keygen -y -P '' -f "$key" > "$key.pub"
  echo "machine-identity: re-derived $key.pub from the existing private key"
else
  echo "machine-identity: $key already present -- leaving it untouched"
fi
chmod 600 "$key"; chmod 644 "$key.pub"   # assert perms even if the files pre-existed
EOF
}

# ---- operator tools (the box operates OTHER deployments) ---------------------
# The Linux box is the operator for the win-test appliance: both the /win-test runner
# (`az vm start` per run) and `devbox -p win-test up` run ON the box and need the Azure
# CLI. Ensure it's installed — Microsoft's apt repo, keyring fetched over TLS (same
# pattern as the gh install in cloud-init). Lives in configure, like the machine
# identity, so one implementation converges fresh AND already-deployed boxes; fast no-op
# once az is on PATH. `az login` stays manual/interactive (spec E6 spirit) — az's token
# cache appears only after the operator logs in, and is revocable in Azure AD.
ensure_operator_tools() {
  local host=$1
  ssh_box "$host" 'bash -s' <<'EOF'
set -eu
command -v az >/dev/null 2>&1 && { echo "operator-tools: azure-cli already installed -- nothing to do"; exit 0; }
echo "operator-tools: installing azure-cli (Microsoft apt repo)"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/microsoft.gpg
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $codename main" \
  | sudo tee /etc/apt/sources.list.d/azure-cli.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq azure-cli
command -v az >/dev/null 2>&1 || { echo "operator-tools: azure-cli install FAILED (az not on PATH)" >&2; exit 1; }
echo "operator-tools: installed $(az version --output tsv --query '"azure-cli"' 2>/dev/null || echo azure-cli)"
EOF
}

# os_configure HOST — ensure the machine identity + operator tools, clone/pull the repo
# over the forwarded agent, install the config, and verify the toolchain + guard. The
# host-key pin happens in common before this call.
os_configure() {
  local host=$1
  ensure_machine_identity "$host"
  log "ensuring operator tools on $host (azure-cli)"
  ensure_operator_tools "$host"
  ssh -A -p "$SSH_PORT" -o StrictHostKeyChecking=yes -o ConnectTimeout=15 \
      "$DEVBOX_USER@$host" "bash -s" <<EOF
set -euo pipefail
# GitHub's host keys were pre-seeded into /etc/ssh/ssh_known_hosts by cloud-init;
# require them (no TOFU) so a MITM on first clone can't harvest the forwarded agent (M3).
export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=yes'
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch origin "$REPO_BRANCH" && git -C "$REPO_DIR" checkout "$REPO_BRANCH" && git -C "$REPO_DIR" pull --ff-only
else
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
fi
sh "$REPO_DIR/claude-config/install.sh"
EOF
  log "verifying toolchain + guard"
  ssh_box "$host" "bash -s" <<'EOF'
set -u
ok=0; bad=0
check() { if eval "$2" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad+1)); fi; }
check "git"     "git --version"
check "gh"      "gh --version"
check "node"    "node --version"
check "claude"  "claude --version"
check "az"      "command -v az"
guard=$(printf '{"tool_input":{"command":"git push"}}' | node "$HOME/.claude/hooks/git-write-guard.js")
case "$guard" in *'"permissionDecision":"ask"'*) echo "  ok    git-write-guard fires" ;; *) echo "  FAIL  git-write-guard"; bad=$((bad+1)) ;; esac
[ "$bad" -eq 0 ] && echo "verify: all checks passed" || { echo "verify: $bad check(s) failed"; exit 1; }
EOF
}

# ---- test prerequisites (Layer B — spec T6) ----------------------------------
# What any project needs to run Docker-backed integration tests and Playwright /
# headless-Chromium tests on the box WITHOUT a per-project sudo step. Three parts, each
# idempotent on its own, all converged on every `up` and by the `toolchain` subcommand:
#   1. Docker Engine — Ubuntu's docker.io (the one install path; no docker-ce repo),
#      enabled + started, and DEVBOX_USER added to the `docker` group. docker-group
#      membership is root-equivalent, so it goes to the box's single primary user only,
#      exactly like its passwordless sudo. Takes effect at the NEXT login (a fresh SSH
#      session — an already-open shell keeps its old group set).
#   2. The shared libraries headless Chromium needs — the apt set `playwright install-deps
#      chromium` would install (PLAYWRIGHT_CHROMIUM_DEPS below), so a project's own
#      `npx playwright install chromium` then works unprivileged (Node LTS is on the box).
#      No browser build is installed here: its version is pinned by each project's
#      Playwright package, so projects download their own into ~/.cache/ms-playwright.
#   3. An AppArmor profile granting `userns` to Playwright's Chromium binaries only.
#      Ubuntu 24.04 ships kernel.apparmor_restrict_unprivileged_userns=1, under which
#      Chromium can't create the user namespace its own sandbox needs and fails to launch.
#      The profile is the targeted fix: flags=(unconfined) + userns for the binaries under
#      the user's ~/.cache/ms-playwright and nothing else. It is a capability GRANT, not a
#      confinement profile. We never flip the sysctl (that weakens the whole box) and never
#      run Chromium with --no-sandbox. Installed only while the sysctl reads 1 (with it
#      at 0 nothing blocks the sandbox and the profile has nothing to grant).
#
# PLAYWRIGHT_CHROMIUM_DEPS = the `tools` + `chromium` package lists for 'ubuntu24.04-x64'
# (arm64 spreads the same list) in Playwright's registry source,
#   packages/playwright-core/src/server/registry/nativeDeps.ts  (main, 2026-09-12).
# Pinned here rather than running `npx playwright install-deps` on each converge: that
# would fetch an unpinned npm package every run and hand it sudo, while the apt list is
# deterministic and a dpkg check makes the re-run a fast no-op (same pattern as every
# other package this repo installs). If a newer Playwright adds a library, update the list.
PLAYWRIGHT_CHROMIUM_DEPS="xvfb fonts-noto-color-emoji fonts-unifont libfontconfig1 libfreetype6
  xfonts-cyrillic xfonts-scalable fonts-liberation fonts-ipafont-gothic fonts-wqy-zenhei
  fonts-tlwg-loma-otf fonts-freefont-ttf
  libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64
  libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6
  libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2"

install_test_prereqs() {
  local host=$1
  log "installing test prerequisites on $host (Docker Engine + docker group, Playwright Chromium libs, AppArmor userns grant)"
  ssh_box "$host" "PW_DEPS='$(echo $PLAYWRIGHT_CHROMIUM_DEPS)' bash -s" <<'EOF'
set -eu
me=$(id -un)
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# 1+2) packages: Docker Engine + the Chromium shared libraries. One apt transaction, and
#      only for what's missing — a converged box never touches apt.
missing_pw=""
for p in $PW_DEPS; do pkg_installed "$p" || missing_pw="$missing_pw $p"; done
if ! pkg_installed docker.io || [ -n "$missing_pw" ]; then
  sudo apt-get update -qq
  if ! pkg_installed docker.io; then
    echo "test-prereqs: installing docker.io"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
  fi
  if [ -n "$missing_pw" ]; then
    echo "test-prereqs: installing Playwright Chromium libs:$missing_pw"
    # --no-install-recommends is what `playwright install-deps` itself passes.
    # shellcheck disable=SC2086  # intentional word-splitting of the package list
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $missing_pw
  fi
  for p in docker.io $PW_DEPS; do pkg_installed "$p" || { echo "test-prereqs: package $p still missing after install" >&2; exit 1; }; done
else
  echo "test-prereqs: docker.io + Playwright Chromium libs already installed -- nothing to do"
fi

# 1) Docker daemon on now and on every boot (enable --now is idempotent), then wait for
#    the API so the verify step below can't race a still-starting daemon.
sudo systemctl enable --now docker >/dev/null 2>&1 || { echo "test-prereqs: systemctl enable --now docker failed" >&2; exit 1; }
for _ in $(seq 1 30); do sudo docker info >/dev/null 2>&1 && break; sleep 1; done
sudo docker info >/dev/null 2>&1 || { echo "test-prereqs: docker daemon not answering (journalctl -u docker)" >&2; exit 1; }
if id -nG "$me" | tr ' ' '\n' | grep -qx docker; then
  echo "test-prereqs: $me already in the docker group"
else
  sudo usermod -aG docker "$me"
  echo "test-prereqs: added $me to the docker group (root-equivalent) -- takes effect at the next login"
fi

# 3) AppArmor userns grant for Playwright's Chromium. Attachment covers both browser
#    layouts Playwright has shipped: chromium-NNNN/chrome-linux/chrome (older) and
#    chromium-NNNN/chrome-linux64/chrome + chromium_headless_shell-NNNN/
#    chrome-headless-shell-linux64/chrome-headless-shell (current). The grant is scoped to
#    THIS user's cache — the same single-primary-user stance as the docker group.
restrict=$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo "")
if [ "$restrict" != "1" ]; then
  echo "test-prereqs: kernel.apparmor_restrict_unprivileged_userns=${restrict:-absent} -- Chromium's sandbox needs no AppArmor grant here; profile not installed"
elif ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "test-prereqs: userns is restricted but apparmor_parser is missing -- cannot install the Playwright grant" >&2; exit 1
else
  prof=/etc/apparmor.d/playwright-chromium
  want="abi <abi/4.0>,
include <tunables/global>

# devbox (deploy/os/linux.sh) -- managed file, edits are overwritten on the next converge.
# Grants unprivileged user namespaces to Playwright's Chromium builds under this user's
# ~/.cache/ms-playwright, so Chromium's own sandbox can start while
# kernel.apparmor_restrict_unprivileged_userns=1 (the Ubuntu 24.04 default).
# flags=(unconfined) + userns only: a capability grant, NOT a confinement profile.
profile playwright-chromium $HOME/.cache/ms-playwright/chromium*/chrome*/{chrome,headless_shell,chrome-headless-shell} flags=(unconfined) {
  userns,

  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/playwright-chromium>
}"
  if [ "$(sudo cat "$prof" 2>/dev/null || true)" != "$want" ]; then
    printf '%s\n' "$want" | sudo tee "$prof" >/dev/null
    sudo chmod 0644 "$prof"
    sudo apparmor_parser -r "$prof"       # load now; apparmor.service reloads /etc/apparmor.d on boot
    echo "test-prereqs: installed + loaded AppArmor profile playwright-chromium ($prof)"
  elif ! sudo grep -q '^playwright-chromium ' /sys/kernel/security/apparmor/profiles; then
    sudo apparmor_parser -r "$prof"
    echo "test-prereqs: AppArmor profile playwright-chromium was on disk but not loaded -- loaded it"
  else
    echo "test-prereqs: AppArmor profile playwright-chromium already loaded"
  fi
  # A SECOND profile attaching to the same binaries (e.g. a per-project one a test script
  # wrote) makes the attachment ambiguous: the kernel logs "conflicting profile
  # attachments", runs Chromium plain-unconfined, and the grant is lost -- the sandbox
  # fails exactly as if no profile existed. Flag it here; the verify step fails on it.
  others=$(sudo find /etc/apparmor.d -maxdepth 1 -type f ! -name playwright-chromium -exec grep -l 'ms-playwright' {} + 2>/dev/null || true)
  [ -z "$others" ] || echo "test-prereqs: WARNING: other AppArmor profile(s) also attach to ms-playwright binaries: $(echo $others) -- keep exactly one (see 'verify' below)" >&2
fi
EOF
  # Verify in a NEW ssh session: group membership is computed at login, so this is the
  # honest "docker without sudo" check (the install session above still had the old groups).
  log "verifying test prerequisites"
  ssh_box "$host" "PW_DEPS='$(echo $PLAYWRIGHT_CHROMIUM_DEPS)' bash -s" <<'EOF'
set -u
bad=0
check() { if eval "$2" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad+1)); fi; }
pw_libs_ok() { local p; for p in $PW_DEPS; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || return 1; done; }
check "docker daemon enabled"            "systemctl is-enabled --quiet docker"
check "docker without sudo (new login)"  "docker info"
n=0; for p in $PW_DEPS; do n=$((n+1)); done
check "playwright chromium libs ($n pkgs)" "pw_libs_ok"
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null)" = "1" ]; then
  check "apparmor playwright-chromium loaded" "sudo grep -q '^playwright-chromium ' /sys/kernel/security/apparmor/profiles"
  others=$(sudo find /etc/apparmor.d -maxdepth 1 -type f ! -name playwright-chromium -exec grep -l 'ms-playwright' {} + 2>/dev/null || true)
  if [ -n "$others" ]; then
    echo "  FAIL  apparmor: only one profile attaches to ms-playwright (also: $(echo $others))"
    echo "        two matching profiles = 'conflicting profile attachments' -> Chromium runs without the userns grant."
    echo "        fix: sudo apparmor_parser -R <file> && sudo rm <file>   (or park it: ln -s <file> /etc/apparmor.d/disable/)"
    bad=$((bad+1))
  else
    echo "  ok    apparmor: only one profile attaches to ms-playwright"
  fi
else
  echo "  skip  apparmor playwright-chromium (userns not restricted on this box)"
fi
if [ "$bad" -eq 0 ]; then
  echo "verify: all checks passed"
  echo "note: a project verifies the browser itself after 'npx playwright install chromium':"
  echo "      ~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome --headless --no-first-run --disable-gpu --dump-dom about:blank  # must exit 0"
else
  echo "verify: $bad check(s) failed"; exit 1
fi
EOF
}

# ---- OS contract (called by lib/common.sh) ---------------------------------
os_render_firstboot()        { render_cloud_init; }
os_vault_start()             { vault_start "$1"; }
os_autoseal_arm()            { autoseal_arm "$1"; }
os_install_session_secrets() { install_session_secrets "$1"; }
# Linux's project toolchain layer = the general-purpose test prerequisites (Docker +
# Playwright Chromium libs + AppArmor grant). Fast no-op once converged, so `up` runs it
# every time, and `toolchain` re-runs it on its own.
os_install_toolchain()       { install_test_prereqs "$1"; }
# The self-deallocation idle-monitor is a Windows-appliance concern (win-test spec L); no-op here.
os_install_idle_monitor()    { :; }
