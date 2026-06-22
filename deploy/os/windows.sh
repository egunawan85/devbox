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

os_configure()               { _win_todo "configure (clone + install.ps1 + verify)" "#8/#9"; }
os_vault_start()             { _win_todo "OpenBao Windows service"                  "#11"; }
os_autoseal_arm()            { _win_todo "auto-seal Scheduled Task"                 "#11"; }
os_install_session_secrets() { _win_todo "session-count materializer"               "#12"; }
