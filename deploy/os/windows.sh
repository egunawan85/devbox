# os/windows.sh — Windows Server OS module for the devbox CLI (the 'windows' profile).
# Implements the OS contract (os_*) that lib/common.sh calls; sourced after common.sh when
# OS=windows. The functions, roughly in lifecycle order:
#   os_render_firstboot        -> provision.ps1 via Azure Custom Script Extension
#   os_box_ready               -> first-boot readiness probe over SSH
#   os_configure               -> clone/pull + install.ps1 + verify over SSH
#   os_install_toolchain       -> project build stack (VS Build Tools, LocalDB, NuGet) via run-command
#   os_vault_start             -> OpenBao as a Windows service (boots sealed)
#   os_install_session_secrets -> session-count materializer (watchdog + 4624/4634 events)
#
# Depends on helpers from common.sh (log/warn/die, ssh_box) — common is sourced first.

# The Windows first-boot template this module renders. SCRIPT_DIR is set by the entrypoint.
WIN_TEMPLATE="$SCRIPT_DIR/azure/provision.ps1"

# os_render_firstboot — render provision.ps1: inject the authorized public keys (raw, one
# per line) at the marker and substitute the SSH port. Emitted to stdout; the azure provider
# runs it via the Custom Script Extension. Mirrors the Linux render_cloud_init, but keys are
# bare (Windows authorized_keys format), not the YAML list cloud-init uses.
os_render_firstboot() {
  [ -f "$WIN_TEMPLATE" ] || die "missing first-boot template: $WIN_TEMPLATE"
  local f keys=""
  for f in $SSH_PUBKEY_FILES; do
    [ -f "$f" ] || die "ssh public key not found: $f"
    keys="${keys}$(cat "$f")
"
  done
  KEYS_BLOCK="$keys" awk '
    $0 == "__AUTHORIZED_KEYS_BLOCK__" { printf "%s", ENVIRON["KEYS_BLOCK"]; next }
    { print }
  ' "$WIN_TEMPLATE" \
    | sed -e "s/__SSH_PORT__/$SSH_PORT/g"
}

# os_box_ready HOST — 0 once first-boot is complete: sshd is up on our port AND provision.ps1
# wrote C:\devbox-ready. The login shell is PowerShell once provisioning is done, but invoke
# powershell explicitly so the check is shell-agnostic.
os_box_ready() {
  ssh_box "$1" 'powershell -NoProfile -Command "if (Test-Path C:\devbox-ready) { exit 0 } else { exit 1 }"' 2>/dev/null
}

# win_ps HOST — run a PowerShell script (read from stdin) on the box via -EncodedCommand.
# EncodedCommand delivers the whole script cohesively; `powershell -Command -` reads stdin
# line-by-line and breaks multi-line blocks (if/else). No agent forwarding is used (Windows
# OpenSSH server doesn't implement it — see os_configure). Host key already pinned by caller.
win_ps() {
  local host=$1 enc
  # Prepend $ProgressPreference=SilentlyContinue: the "Preparing modules" progress stream
  # otherwise makes PowerShell CLIXML-wrap stdout over SSH, corrupting our marker output.
  enc=$( { echo "\$ProgressPreference='SilentlyContinue'"; cat; } | iconv -t UTF-16LE | base64 | tr -d '\n')
  ssh -p "$SSH_PORT" -o StrictHostKeyChecking=yes -o ConnectTimeout=20 \
      "$DEVBOX_USER@$host" "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
}

# os_configure HOST — deliver the repo to the box, run install.ps1, verify toolchain + guard.
# Windows can't pull from GitHub via a forwarded agent (the OpenSSH *server* on Windows does
# not implement agent forwarding — confirmed even on v10), so instead the operator's machine
# PUSHES the repo (a tar of REPO_BRANCH) over the already-authenticated SSH session via scp
# (SFTP — binary-clean, unlike piping a tarball through the PowerShell login shell). The box
# never authenticates to GitHub for the config (nothing at rest). Project repos
# (runegate/qrypto-omni) use interactive `gh auth login` + HTTPS in a dev session — see A4.
# Host-key pin happens in common (cmd_configure) before this.
os_configure() {
  local host=$1
  need git; need scp; need iconv; need base64
  log "pushing repo ($REPO_BRANCH) to the box + running install.ps1"
  local repotop tarball
  repotop=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel) || die "configure: operator side is not a git repo"
  tarball=$(mktemp "${TMPDIR:-/tmp}/devbox-payload.XXXXXX")
  git -C "$repotop" archive --format=tar.gz -o "$tarball" "$REPO_BRANCH" \
    || { rm -f "$tarball"; die "configure: 'git archive $REPO_BRANCH' failed (does the branch exist locally?)"; }
  # SFTP is binary-clean. Lands at the SSH default dir (the user home) as payload.tgz.
  scp -q -P "$SSH_PORT" -o StrictHostKeyChecking=yes "$tarball" "$DEVBOX_USER@$host:payload.tgz" \
    || { rm -f "$tarball"; die "configure: scp of payload failed"; }
  rm -f "$tarball"
  # Extract into REPO_DIR + run install.ps1 (cohesive script via win_ps). Unquoted heredoc:
  # bash fills in $REPO_DIR; \$ keeps PowerShell vars literal.
  win_ps "$host" <<EOF || die "windows configure: extract/install failed"
\$ErrorActionPreference='Stop'; \$ProgressPreference='SilentlyContinue'
\$repo='$REPO_DIR'
New-Item -ItemType Directory -Force -Path \$repo | Out-Null
tar -xzf "\$env:USERPROFILE\payload.tgz" -C \$repo
if (\$LASTEXITCODE) { exit 1 }
Remove-Item "\$env:USERPROFILE\payload.tgz" -Force
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path \$repo 'claude-config\install.ps1')
exit \$LASTEXITCODE
EOF
  # Disable Azure CLI token-cache encryption for the box user. On this Windows Server profile
  # the CLI can't encrypt its MSAL token cache via DPAPI, so `az login` — which the operator
  # runs in an SSH session ON the box (RDP is firewalled off) — dies with
  # "Encryption failed: [WinError 5] ... Consider disable encryption." A User-scope env var
  # fixes it for every future `az` in that user's sessions (verified: Windows OpenSSH loads
  # HKCU env per session, so new SSH sessions inherit it) without needing elevation or az to
  # be installed yet. Idempotent — re-setting the same value is a no-op. Runs every configure,
  # so it self-heals. Tokens then sit unencrypted under the user's ~/.azure, acceptable on a
  # single-operator box that already holds these credentials.
  log "ensuring Azure CLI token-cache encryption is disabled on the box (DPAPI WinError 5 workaround)"
  win_ps "$host" <<'EOF' || die "windows configure: could not set AZURE_CORE_ENCRYPT_TOKEN_CACHE on the box"
[Environment]::SetEnvironmentVariable('AZURE_CORE_ENCRYPT_TOKEN_CACHE','false','User')
$v = [Environment]::GetEnvironmentVariable('AZURE_CORE_ENCRYPT_TOKEN_CACHE','User')
if ($v -ne 'false') { Write-Output "  FAIL  AZURE_CORE_ENCRYPT_TOKEN_CACHE not set (got '$v')"; exit 1 }
Write-Output "  ok    AZURE_CORE_ENCRYPT_TOKEN_CACHE=$v (User scope)"
EOF
  log "verifying toolchain + guard"
  win_ps "$host" <<'EOF' || die "windows configure: verify failed"
$bad = 0
foreach ($c in 'git','gh','node','claude') {
  if (Get-Command $c -ErrorAction SilentlyContinue) { Write-Output "  ok    $c" } else { Write-Output "  FAIL  $c"; $bad++ }
}
$guard = '{"tool_input":{"command":"git push"}}' | node (Join-Path $HOME '.claude\hooks\git-write-guard.js')
if ("$guard" -match '"permissionDecision":"ask"') { Write-Output "  ok    git-write-guard fires" } else { Write-Output "  FAIL  git-write-guard"; $bad++ }
if ($bad -eq 0) { Write-Output "verify: all checks passed" } else { Write-Output "verify: $bad check(s) failed"; exit 1 }
EOF
}
# os_vault_start HOST -- install OpenBao + run it as a Windows Service (auto-start, boots
# sealed -- E7), then echo the seal-status JSON for vault_bringup. The install needs admin, so
# it runs via az run-command (SYSTEM); vault-service.ps1 emits the status between markers,
# which we extract clean (robust against PowerShell/CLIXML noise on the wire).
os_vault_start() {
  local host=$1 script="$SCRIPT_DIR/azure/vault-service.ps1" out
  need az; need perl
  [ -f "$script" ] || die "missing vault service script: $script"
  perl -ne 'exit 1 if /[^\x00-\x7f]/' "$script" || die "vault-service.ps1 has non-ASCII bytes -- make it pure ASCII"
  out=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
    --command-id RunPowerShellScript --scripts "@$script" --query "value[].message" -o tsv 2>&1) \
    || { printf '{"error":"vault-service run-command failed"}'; return 0; }
  local json; json=$(printf '%s' "$out" | tr -d '\r' | sed -n 's/.*__VAULTJSON__\(.*\)__ENDVAULTJSON__.*/\1/p')
  [ -n "$json" ] && printf '%s' "$json" || printf '{"error":"vault-service produced no status (see C:\\ProgramData\\devbox\\openbao.log)"}'
}
# Auto-seal is optional (off unless AUTOSEAL_TTL is set). The Scheduled-Task implementation is
# a later slice; until then, no-op silently when off and warn (don't die) when a TTL is set so
# `vault up` still completes.
os_autoseal_arm() { [ -n "${AUTOSEAL_TTL:-}" ] && log "windows auto-seal (Scheduled Task) not implemented yet (#11) -- ignoring AUTOSEAL_TTL=$AUTOSEAL_TTL"; return 0; }
# ---- session secrets (vault -> app .env while an SSH session is live; wiped at last logout) ----
# Windows analog of the Linux login-time materializer. No tmpfs + no logind here, so a SYSTEM
# Scheduled Task (60s poll + boot + 4624/4634 logon/logoff events) ref-counts eddyg's live SSH
# sessions and materializes/wipes each mapped project's .env on the encrypted disk (spec E8
# Windows clause). Opt-in: only runs when a local secrets.map exists.

# Validate + normalize the manifest -> "<project> <abs-dest>" lines on stdout (Windows paths).
win_validate_secrets_map() {
  local f=$1 proj dest rest out=""
  while read -r proj dest rest || [ -n "$proj" ]; do   # || ... = also process a final line with no trailing newline
    case "$proj" in ''|\#*) continue ;; esac
    [ -n "$dest" ] || { echo "secrets.map: project '$proj' has no dest path" >&2; return 1; }
    case "$proj" in *[!a-zA-Z0-9._-]*) echo "secrets.map: invalid project name '$proj'" >&2; return 1 ;; esac
    case "$dest" in [A-Za-z]:[/\\]*) ;; *) echo "secrets.map: dest must be an absolute Windows path (C:\\... or C:/...): '$dest'" >&2; return 1 ;; esac
    case "$dest" in *..*) echo "secrets.map: dest must not contain '..': '$dest'" >&2; return 1 ;; esac
    out="${out}${proj} ${dest}
"
  done < "$f"
  printf '%s' "$out"
}

os_install_session_secrets() {
  local host=$1
  [ -f "$SECRETS_MAP" ] || { log "no secrets.map at $SECRETS_MAP -- skipping session-secrets (windows)"; return 0; }
  local clean; clean=$(win_validate_secrets_map "$SECRETS_MAP") || die "invalid $SECRETS_MAP (see above)"
  [ -n "$clean" ] || { log "secrets.map has no mappings -- skipping session-secrets setup"; return 0; }
  need az; need perl
  local script="$SCRIPT_DIR/azure/session-secrets-install.ps1"
  [ -f "$script" ] || die "missing session-secrets installer: $script"
  perl -ne 'exit 1 if /[^\x00-\x7f]/' "$script" || die "session-secrets-install.ps1 has non-ASCII bytes -- make it pure ASCII"
  ssh_box "$host" 'exit 0'
  log "installing session-secrets watchdog (vault -> .env/file while logged in; wiped at last logout) on $host"
  # 1) push the validated manifest to the user profile (writable without admin); data on stdin.
  local pushscript res
  pushscript=$(cat <<'PS'
$d = "C:\Users\eddyg\.devbox"
New-Item -ItemType Directory -Force -Path $d | Out-Null
Set-Content -Path (Join-Path $d "secrets.map") -Value ([Console]::In.ReadToEnd()) -Encoding ascii -NoNewline
Write-Output '__VAULTJSON__{"ok":true}__ENDVAULTJSON__'
PS
)
  res=$(printf '%s\n' "$clean" | win_vault_secret "$host" "$pushscript")
  printf '%s' "$res" | grep -q '"ok":true' || die "failed to push secrets.map to $host"
  # 2) install the watchdog + register the SYSTEM Scheduled Task (copies the map into ProgramData).
  local out json
  out=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
    --command-id RunPowerShellScript --scripts "@$script" --query "value[].message" -o tsv 2>&1) \
    || die "session-secrets install (run-command) failed"
  json=$(printf '%s' "$out" | tr -d '\r' | sed -n 's/.*__SSJSON__\(.*\)__ENDSSJSON__.*/\1/p')
  printf '%s' "$json" | grep -q '"ok":true' \
    || die "session-secrets install did not complete: ${json:-no status} (see C:\\ProgramData\\devbox\\session-secrets.log)"
  log "session-secrets installed -- materializes on SSH login, wipes at last logout (60s watchdog + logon/logoff events)."
}

# win_session_refresh HOST -- re-run the watchdog now (materializes for any live session). Used
# by `vault refresh` after (re)loading secrets, so an open session sees new values immediately.
win_session_refresh() {
  local host=$1
  az vm run-command invoke -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" --command-id RunPowerShellScript \
    --scripts 'if (Get-ScheduledTask -TaskName devbox-secrets -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName devbox-secrets; Start-Sleep 2; Write-Output "ssrefreshed" } else { Write-Output "ssnotinstalled" }' \
    --query "value[].message" -o tsv 2>&1 | grep -aq 'ssrefreshed' \
    && echo "devbox-secrets: re-materialized for any active session" \
    || echo "devbox-secrets: session-secrets not installed (no secrets.map) -- nothing to refresh"
}

# os_install_toolchain HOST — Layer B: install the project build toolchain (VS Build Tools +
# Test Tools, SQL Server Express LocalDB, NuGet, PS7, Azure CLI, go-sqlcmd, rsync) via az
# run-command (as SYSTEM). Called by `up` AND the `toolchain` subcommand. Convergent, not
# once-only: the box records the sha256 of the toolchain.ps1 that last COMPLETED
# (C:\devbox-toolchain-rev), and the install is skipped only while the local script hashes the
# same — so later `up`s stay fast, but editing toolchain.ps1 makes the next `toolchain`/`up`
# re-apply it. The script's steps are individually idempotent (choco -y, guarded LocalDB, VS
# installer self-skips), so a re-apply costs minutes, not the full ~20-30 min.
# Windows is always the Azure provider (spec P1), so run-command + RESOURCE_GROUP here is fine.
os_install_toolchain() {
  local host=$1 script="$SCRIPT_DIR/azure/toolchain.ps1" want have
  need az; need perl
  [ -f "$script" ] || die "missing toolchain script: $script"
  want=$(perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$script")
  have=$(ssh_box "$host" 'powershell -NoProfile -Command "if (Test-Path C:\devbox-toolchain-rev) { Get-Content C:\devbox-toolchain-rev }"' 2>/dev/null | tr -d '[:space:]') || have=""
  if [ -n "$have" ] && [ "$have" = "$want" ]; then
    log "project toolchain already at rev ${want:0:12} on $host -- skipping"
    return 0
  fi
  # Guard: a non-ASCII byte (e.g. an em-dash) is read on the box as Windows-1252, where 0x94
  # becomes a smart-quote that closes a PowerShell string early and breaks the whole script.
  perl -ne 'exit 1 if /[^\x00-\x7f]/' "$script" || die "toolchain.ps1 contains non-ASCII bytes (they corrupt over run-command) -- make it pure ASCII"
  log "installing project toolchain on $host (VS Build Tools + Test Tools + SQL LocalDB + SQL Express on 1433 + NuGet/PS7/Azure CLI/rsync; ~20-30 min fresh, minutes to re-converge)"
  az vm run-command invoke -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
    --command-id RunPowerShellScript --scripts "@$script" --query "value[].message" -o tsv \
    || die "toolchain install (run-command) failed -- see C:\\devbox-toolchain.log on the box"
  # run-command reports success even when the script itself errors, so confirm the ready
  # marker: toolchain.ps1 deletes it up front and rewrites it only on success, so its
  # presence reflects THIS run, never a stale earlier one.
  ssh_box "$host" 'powershell -NoProfile -Command "if (Test-Path C:\devbox-toolchain-ready) { exit 0 } else { exit 1 }"' \
    || die "toolchain did not complete (no C:\\devbox-toolchain-ready) -- check C:\\devbox-toolchain.log via '$(basename "$0") -p $DEVBOX_PROFILE ssh'"
  # Record which script rev completed; the skip above holds until toolchain.ps1 changes.
  ssh_box "$host" "powershell -NoProfile -Command \"Set-Content -Path C:\devbox-toolchain-rev -Value '$want' -Encoding ascii\"" \
    || die "could not record toolchain rev on $host"
}

# os_install_idle_monitor HOST — the appliance's self-deallocation watcher (win-test spec
# L3/L4). Only for profiles that OPT IN by setting IDLE_MINUTES in their conf — a workspace
# box must never turn itself off. Called by `up` AND the `toolchain` subcommand.
# Three idempotent layers, re-ensured on every call:
#   1. a system-assigned managed identity on the VM — how the box calls ARM to deallocate
#      itself with no credential stored on it (the watcher gets tokens from IMDS);
#   2. the single-action custom role devbox-self-deallocator (deallocate, nothing else),
#      scoped to THIS VM only and granted to that identity — a compromised box can turn
#      itself off, and that is all;
#   3. the box-side watcher + its 5-min scheduled task (deploy/azure/idle-monitor.ps1,
#      rendered with IDLE_MINUTES), converged by RENDERED-script hash like the toolchain —
#      so both script edits and an IDLE_MINUTES change re-apply on the next run.
os_install_idle_monitor() {
  local host=$1 script="$SCRIPT_DIR/azure/idle-monitor.ps1"
  [ -n "${IDLE_MINUTES:-}" ] || return 0
  need az; need perl
  [ -f "$script" ] || die "missing idle-monitor script: $script"

  log "ensuring managed identity + deallocate-only role on $DROPLET_NAME"
  az vm identity assign -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" >/dev/null \
    || die "could not assign a system-assigned identity to $DROPLET_NAME"
  local principal vmid
  principal=$(az vm show -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" --query identity.principalId -o tsv)
  vmid=$(az vm show -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" --query id -o tsv)
  [ -n "$principal" ] && [ -n "$vmid" ] || die "could not read the VM's identity/id"
  if [ -z "$(az role definition list --name devbox-self-deallocator --query '[0].roleName' -o tsv)" ]; then
    az role definition create --role-definition "{
      \"Name\": \"devbox-self-deallocator\",
      \"Description\": \"May deallocate a VM. Nothing else. Used by devbox appliance self-shutdown.\",
      \"Actions\": [\"Microsoft.Compute/virtualMachines/deallocate/action\"],
      \"AssignableScopes\": [\"/subscriptions/$SUBSCRIPTION_ID\"]
    }" >/dev/null || die "could not create the devbox-self-deallocator role definition"
    log "created custom role devbox-self-deallocator (deallocate action only)"
  fi
  if [ -z "$(az role assignment list --assignee "$principal" --role devbox-self-deallocator --scope "$vmid" --query '[0].id' -o tsv 2>/dev/null)" ]; then
    # A freshly minted principal can 404 in AAD for a minute — retry, don't fail the up.
    local granted=0 i
    for i in 1 2 3 4 5; do
      if az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
           --role devbox-self-deallocator --scope "$vmid" >/dev/null 2>&1; then granted=1; break; fi
      log "role assignment not accepted yet (AAD propagation) -- retry $i/5 in 15s"
      sleep 15
    done
    [ "$granted" = 1 ] || die "could not grant devbox-self-deallocator to the VM's identity"
  fi

  local rendered want have
  rendered=$(mktemp)
  perl -pe "s/__IDLE_MINUTES__/$IDLE_MINUTES/g" "$script" > "$rendered"
  # Guard: a non-ASCII byte (e.g. an em-dash) is read on the box as Windows-1252, where 0x94
  # becomes a smart-quote that closes a PowerShell string early and breaks the whole script.
  perl -ne 'exit 1 if /[^\x00-\x7f]/' "$rendered" \
    || { rm -f "$rendered"; die "idle-monitor.ps1 contains non-ASCII bytes (they corrupt over run-command) -- make it pure ASCII"; }
  want=$(perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$rendered")
  have=$(ssh_box "$host" 'powershell -NoProfile -Command "if (Test-Path C:\devbox-idlemon-rev) { Get-Content C:\devbox-idlemon-rev }"' 2>/dev/null | tr -d '[:space:]') || have=""
  if [ -n "$have" ] && [ "$have" = "$want" ]; then
    log "idle-monitor already at rev ${want:0:12} on $host -- skipping"
    rm -f "$rendered"
    return 0
  fi
  log "installing idle-monitor on $host (deallocates after $IDLE_MINUTES idle minutes; checks every 5)"
  az vm run-command invoke -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
    --command-id RunPowerShellScript --scripts "@$rendered" --query "value[].message" -o tsv \
    || { rm -f "$rendered"; die "idle-monitor install (run-command) failed -- see C:\\devbox-idle-monitor-install.log on the box"; }
  rm -f "$rendered"
  # run-command reports success even when the script itself errors, so confirm the ready
  # marker the installer clears up front and rewrites only on success.
  ssh_box "$host" 'powershell -NoProfile -Command "if (Test-Path C:\devbox-idlemon-ready) { exit 0 } else { exit 1 }"' \
    || die "idle-monitor did not complete (no C:\\devbox-idlemon-ready) -- check C:\\devbox-idle-monitor-install.log via '$(basename "$0") -p $DEVBOX_PROFILE ssh'"
  ssh_box "$host" "powershell -NoProfile -Command \"Set-Content -Path C:\devbox-idlemon-rev -Value '$want' -Encoding ascii\"" \
    || die "could not record idle-monitor rev on $host"
}

# ---- vault data path (PowerShell-native; called via OS branch from common.sh) ---------------
# bao.exe (installed by vault-service.ps1) + Invoke-RestMethod to the localhost API; no jq/curl.
# Each box-side script wraps its result in __VAULTJSON__...__ENDVAULTJSON__ so we parse it clean
# despite any CLIXML/banner noise on the wire. The vault binary + env files live under
# C:\Program Files\OpenBao and C:\ProgramData\devbox (the Windows analog of ~/.config/devbox).

# win_vault_run HOST -- run a PowerShell script (read from this fn's stdin) on the box and echo
# the marker-wrapped text. For calls with NO secret input (init, status, server-up check).
win_vault_run() {
  local host=$1 out
  out=$(win_ps "$host") || return 1
  printf '%s' "$out" | tr -d '\r' | sed -n 's/.*__VAULTJSON__\(.*\)__ENDVAULTJSON__.*/\1/p'
}

# win_vault_secret HOST SCRIPT -- run SCRIPT on the box with a SECRET piped to its stdin (the
# script reads it via [Console]::In). The script goes via -EncodedCommand (argv, not secret);
# the secret stays on stdin, never on argv (E5). Echoes marker-wrapped output.
win_vault_secret() {
  local host=$1 script=$2 enc out
  enc=$(printf "%s\n%s" "\$ProgressPreference='SilentlyContinue'" "$script" | iconv -t UTF-16LE | base64 | tr -d '\n')
  out=$(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=yes -o ConnectTimeout=25 \
        "$DEVBOX_USER@$host" "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc") || return 1
  printf '%s' "$out" | tr -d '\r' | sed -n 's/.*__VAULTJSON__\(.*\)__ENDVAULTJSON__.*/\1/p'
}

# win_vault_init -- operator init (1-of-1) -> unseal -> enable kv-v2 -> scoped devbox-app token
# -> write the box's vault.env + token, and return the init JSON (unseal key + root) to the
# laptop. Keys are generated on the box and travel back over the SSH channel; never on argv.
win_vault_init() {
  command -v jq >/dev/null 2>&1 || die "jq not found on this machine"
  local host; host=$(vault_host)
  ssh_box "$host" 'exit 0'
  log "initializing + unsealing vault on $host (1 key share, single unseal key)"
  local script out
  script=$(cat <<'PS'
$ErrorActionPreference='Stop'
$bao='C:\Program Files\OpenBao\bao.exe'; $env:BAO_ADDR='http://127.0.0.1:8200'
$st = Invoke-RestMethod -UseBasicParsing -Uri "$($env:BAO_ADDR)/v1/sys/seal-status"
if ($st.initialized) { Write-Output '__VAULTJSON__{"error":"ALREADY_INITIALIZED"}__ENDVAULTJSON__'; exit 0 }
$initRaw = (& $bao operator init -key-shares=1 -key-threshold=1 -format=json | Out-String).Trim()
$init = $initRaw | ConvertFrom-Json
Invoke-RestMethod -UseBasicParsing -Method Put -Uri "$($env:BAO_ADDR)/v1/sys/unseal" -Body (@{key=$init.unseal_keys_b64[0]} | ConvertTo-Json) | Out-Null
$env:BAO_TOKEN = $init.root_token
& $bao secrets enable -path=secret kv-v2 | Out-Null
$pol = @'
path "secret/data/*" { capabilities = ["create","read","update","delete"] }
path "secret/metadata/*" { capabilities = ["read","list","delete"] }
'@
$pol | & $bao policy write devbox-app - | Out-Null
$apptok = ((& $bao token create -policy=devbox-app -period=768h -format=json | Out-String) | ConvertFrom-Json).auth.client_token
$dir='C:\ProgramData\devbox'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Content -Path (Join-Path $dir 'vault.env') -Value @("BAO_ADDR=$($env:BAO_ADDR)", "BAO_TOKEN=$apptok") -Encoding ascii
$apptok | Set-Content -Path (Join-Path $dir 'bao-token') -Encoding ascii -NoNewline
Write-Output "__VAULTJSON__$($init | ConvertTo-Json -Compress)__ENDVAULTJSON__"
PS
)
  out=$(printf '%s\n' "$script" | win_vault_run "$host") || die "vault init failed -- is the server up ('vault up') and not already initialized ('vault unseal')?"
  case "$out" in *ALREADY_INITIALIZED*) die "this box's vault is already initialized -- use '$(basename "$0") -p $DEVBOX_PROFILE vault unseal'" ;; esac
  [ -n "$out" ] || die "vault init produced no keys"
  umask 077; mkdir -p "$(dirname "$VAULT_KEYS_FILE")"
  printf '%s' "$out" > "$VAULT_KEYS_FILE"; chmod 600 "$VAULT_KEYS_FILE"
  log "vault initialized + unsealed. Keys saved to $VAULT_KEYS_FILE"
  warn "KEEP $VAULT_KEYS_FILE SAFE -- it holds this box's unseal key + root token (the box itself has only a scoped token)."
}

# win_vault_unseal -- re-unseal from the saved laptop key. Key is piped on stdin, never argv.
win_vault_unseal() {
  command -v jq >/dev/null 2>&1 || die "jq not found on this machine"
  local host; host=$(vault_host)
  ssh_box "$host" 'exit 0'
  local upscript; upscript=$(cat <<'PS'
try { Write-Output "__VAULTJSON__$((Invoke-RestMethod -UseBasicParsing 'http://127.0.0.1:8200/v1/sys/seal-status' | ConvertTo-Json -Compress))__ENDVAULTJSON__" } catch { Write-Output '__VAULTJSON__{}__ENDVAULTJSON__' }
PS
)
  local up; up=$(printf '%s\n' "$upscript" | win_vault_run "$host")
  # Check the server RESPONDED with a seal-status (the 'sealed' key exists), not the truthiness
  # of .sealed -- `jq -e .sealed` exits 1 when sealed=false, which falsely tripped "not
  # responding" on an already-unsealed vault.
  printf '%s' "$up" | jq -e 'has("sealed")' >/dev/null 2>&1 || die "vault server not responding on $host -- run '$(basename "$0") -p $DEVBOX_PROFILE vault up'"
  [ -f "$VAULT_KEYS_FILE" ] || die "no saved keys at $VAULT_KEYS_FILE -- init this box first ('$(basename "$0") -p $DEVBOX_PROFILE vault init')"
  local unseal; unseal=$(jq -r '.unseal_keys_b64[0]' "$VAULT_KEYS_FILE")
  [ -n "$unseal" ] && [ "$unseal" != null ] || die "could not read unseal key from $VAULT_KEYS_FILE"
  local resp
  resp=$(printf '%s' "$unseal" | win_vault_secret "$host" '
$ErrorActionPreference="Stop"
$key = [Console]::In.ReadToEnd().Trim()
$r = Invoke-RestMethod -UseBasicParsing -Method Put -Uri "http://127.0.0.1:8200/v1/sys/unseal" -Body (@{key=$key} | ConvertTo-Json)
Write-Output "__VAULTJSON__$($r | ConvertTo-Json -Compress)__ENDVAULTJSON__"
')
  [ "$(printf '%s' "$resp" | jq -r '.sealed' 2>/dev/null)" = "false" ] || die "unseal failed (vault still sealed) -- verify the key in $VAULT_KEYS_FILE matches this box"
  log "vault unsealed."
}

# win_vault_load PROJ MOUNT HOST -- push a project's secrets (JSON on stdin) into the box's
# vault at <mount>/<proj>. The JSON (secret values) stays on stdin -> bao kv put stdin; the
# box-side token comes from C:\ProgramData\devbox\vault.env. proj/mount are validated by caller.
win_vault_load() {
  local proj=$1 mount=$2 host=$3 script
  log "loading secrets -> vault $mount/$proj on $host"
  # Build the PS script via an interpolating heredoc: bash fills in $mount/$proj, \$ keeps
  # PowerShell vars literal, and " needs no escaping (heredocs treat it literally).
  script=$(cat <<EOF
\$ErrorActionPreference='Stop'
\$bao='C:\Program Files\OpenBao\bao.exe'
Get-Content 'C:\ProgramData\devbox\vault.env' -ErrorAction SilentlyContinue | ForEach-Object { if (\$_ -match '^([^=]+)=(.*)\$') { Set-Item "env:\$(\$matches[1])" \$matches[2] } }
if (-not \$env:BAO_TOKEN) { Write-Output '__VAULTJSON__{"error":"vault not up"}__ENDVAULTJSON__'; exit 1 }
\$OutputEncoding = New-Object Text.UTF8Encoding \$false   # encode the pipe to bao as UTF-8
\$sr = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding \$false))
\$json = \$sr.ReadToEnd()   # read stdin as explicit UTF-8 (console InputEncoding would mangle non-ASCII)
\$json | & \$bao kv put -mount='$mount' '$proj' - | Out-Null
if (\$LASTEXITCODE -ne 0) { Write-Output '__VAULTJSON__{"error":"kv put failed"}__ENDVAULTJSON__'; exit 1 }
Write-Output '__VAULTJSON__{"ok":true}__ENDVAULTJSON__'
EOF
)
  local res; res=$(win_vault_secret "$host" "$script")   # secrets JSON arrives on this fn's stdin
  printf '%s' "$res" | grep -q '"ok":true' \
    || die "vault load failed on $host (${res:-no response}) -- is the vault unsealed? (devbox -p $DEVBOX_PROFILE vault unseal)"
  log "loaded. On the box: bao kv get -mount=$mount $proj"
}

# win_vault_status -- print the human-readable seal status.
win_vault_status() {
  local host; host=$(vault_host)
  ssh_box "$host" 'exit 0'
  local stscript; stscript=$(cat <<'PS'
try { Write-Output "__VAULTJSON__$((Invoke-RestMethod -UseBasicParsing 'http://127.0.0.1:8200/v1/sys/seal-status' | ConvertTo-Json -Compress))__ENDVAULTJSON__" } catch { Write-Output '__VAULTJSON____ENDVAULTJSON__' }
PS
)
  local s; s=$(printf '%s\n' "$stscript" | win_vault_run "$host")
  if [ -z "$s" ]; then echo "OpenBao: not running -- run: $(basename "$0") -p $DEVBOX_PROFILE vault up"; return 0; fi
  echo "OpenBao: running (localhost-only); initialized=$(printf '%s' "$s" | jq -r .initialized) sealed=$(printf '%s' "$s" | jq -r .sealed)"
}
