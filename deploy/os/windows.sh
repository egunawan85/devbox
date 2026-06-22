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

os_render_firstboot()        { _win_todo "first-boot render (provision.ps1)"        "#7"; }
os_box_ready()               { _win_todo "readiness probe"                          "#7"; }
os_configure()               { _win_todo "configure (clone + install.ps1 + verify)" "#8/#9"; }
os_vault_start()             { _win_todo "OpenBao Windows service"                  "#11"; }
os_autoseal_arm()            { _win_todo "auto-seal Scheduled Task"                 "#11"; }
os_install_session_secrets() { _win_todo "session-count materializer"               "#12"; }
