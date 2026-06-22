# os/windows.sh — Windows Server OS module for the devbox CLI (the 'windows' profile).
# Implements the OS contract (os_*) that lib/common.sh calls; sourced after common.sh when
# OS=windows. The contract surface exists now so the windows profile loads and dispatches;
# each function is filled in by its slice (see docs/plans/devbox.md, Phase 2b):
#   os_render_firstboot        -> provision.ps1 via Azure Custom Script Extension   (#7)
#   os_box_ready               -> first-boot readiness probe over SSH               (#7)
#   os_configure               -> clone/pull + install.ps1 + verify over SSH        (#8, #9)
#   os_vault_start             -> OpenBao as a Windows service (boots sealed)        (#11)
#   os_autoseal_arm            -> auto-seal via a Scheduled Task                      (#11)
#   os_install_session_secrets -> session-count materializer (watchdog + events)     (#12)
#
# Depends on helpers from common.sh (log/warn/die, ssh_box) — common is sourced first.

_win_todo() { die "windows: $1 is not implemented yet ($2) — see docs/plans/devbox.md Phase 2b"; }

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

# os_configure HOST — clone/pull the repo over the forwarded agent, run install.ps1, and
# verify the toolchain + guard. The host-key pin happens in common (cmd_configure) before
# this. The remote default shell is PowerShell; we feed each script via stdin to
# `powershell -Command -` to avoid quoting hell. GitHub's host keys were pinned at first boot.
os_configure() {
  local host=$1
  log "cloning/pulling repo + running install.ps1"
  # Unquoted heredoc: bash fills in REPO_* (validated conf); \$ keeps PowerShell vars literal.
  ssh -A -p "$SSH_PORT" -o StrictHostKeyChecking=yes -o ConnectTimeout=15 \
      "$DEVBOX_USER@$host" 'powershell -NoProfile -ExecutionPolicy Bypass -Command -' <<EOF || die "windows configure: clone/install failed"
\$ErrorActionPreference = 'Stop'
\$env:GIT_SSH_COMMAND = 'ssh -o StrictHostKeyChecking=yes'
\$repo = '$REPO_DIR'; \$branch = '$REPO_BRANCH'; \$url = '$REPO_URL'
if (Test-Path (Join-Path \$repo '.git')) {
  git -C \$repo fetch origin \$branch; if (\$LASTEXITCODE) { exit 1 }
  git -C \$repo checkout \$branch;     if (\$LASTEXITCODE) { exit 1 }
  git -C \$repo pull --ff-only;        if (\$LASTEXITCODE) { exit 1 }
} else {
  git clone --branch \$branch \$url \$repo; if (\$LASTEXITCODE) { exit 1 }
}
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path \$repo 'claude-config\install.ps1')
exit \$LASTEXITCODE
EOF
  log "verifying toolchain + guard"
  ssh -p "$SSH_PORT" -o StrictHostKeyChecking=yes -o ConnectTimeout=15 \
      "$DEVBOX_USER@$host" 'powershell -NoProfile -ExecutionPolicy Bypass -Command -' <<'EOF' || die "windows configure: verify failed"
$bad = 0
foreach ($c in 'git','gh','node','claude') {
  if (Get-Command $c -ErrorAction SilentlyContinue) { Write-Host "  ok    $c" } else { Write-Host "  FAIL  $c"; $bad++ }
}
$guard = '{"tool_input":{"command":"git push"}}' | node (Join-Path $HOME '.claude\hooks\git-write-guard.js')
if ("$guard" -match '"permissionDecision":"ask"') { Write-Host "  ok    git-write-guard fires" } else { Write-Host "  FAIL  git-write-guard"; $bad++ }
if ($bad -eq 0) { Write-Host "verify: all checks passed" } else { Write-Host "verify: $bad check(s) failed"; exit 1 }
EOF
}
os_vault_start()             { _win_todo "OpenBao Windows service"                  "#11"; }
os_autoseal_arm()            { _win_todo "auto-seal Scheduled Task"                 "#11"; }
# Soft skip (not a hard stop): session-secrets is opt-in, and configure must still complete.
os_install_session_secrets() { log "windows session-secrets materializer not installed yet (#12) — skipping"; }
