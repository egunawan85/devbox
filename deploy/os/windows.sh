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

# win_ps HOST — run a PowerShell script (read from stdin) on the box via -EncodedCommand.
# EncodedCommand delivers the whole script cohesively; `powershell -Command -` reads stdin
# line-by-line and breaks multi-line blocks (if/else). No agent forwarding is used (Windows
# OpenSSH server doesn't implement it — see os_configure). Host key already pinned by caller.
win_ps() {
  local host=$1 enc
  enc=$(iconv -t UTF-16LE | base64 | tr -d '\n')
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
os_vault_start()             { _win_todo "OpenBao Windows service"                  "#11"; }
os_autoseal_arm()            { _win_todo "auto-seal Scheduled Task"                 "#11"; }
# Soft skip (not a hard stop): session-secrets is opt-in, and configure must still complete.
os_install_session_secrets() { log "windows session-secrets materializer not installed yet (#12) — skipping"; }
