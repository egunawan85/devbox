#!/usr/bin/env bash
# idle-monitor.sh -- a Linux test appliance's self-deallocation watcher.
#
# Installed by the devbox CLI (os/linux.sh: install_idle_monitor) as
# /usr/local/lib/devbox/idle-monitor.sh and run as root by a systemd timer every five
# minutes. Appliance profiles only: the CLI installs it when the profile sets
# IDLE_MINUTES, because a box that turns itself off is right for a test appliance and
# wrong for a workspace.
#
# It deallocates the VM when no run is ACTIVE and the box has been IDLE past the limit:
#   active = the run lock is held. The runner holds it with flock(2) for as long as it
#            lives, and the kernel drops it when that process dies, so a run that was
#            killed outright cannot pin the box; there is no stale lock to clean up.
#   idle   = the newer of the run heartbeat and the boot time is older than the limit.
#            Boot time, so a box that was just started has a full window before its
#            first heartbeat.
# Deallocation is a control-plane call (compute billing stops; an OS shutdown would
# leave the VM allocated and billed) made with the VM's system-assigned managed
# identity, fetched from the instance metadata service. No credential is stored on the
# box, and the subscription, resource group and VM name are self-discovered. The CLI
# grants that identity one action -- deallocate -- on this one VM.
#
# Settings come from /etc/devbox/idle-monitor.env (written by the CLI): IDLE_MINUTES and
# STATE_DIR (where the runner keeps run.lock and last-activity). IDLE_MONITOR_DRY_RUN=1
# reports the decision without calling Azure, and IDLE_MONITOR_NOW / IDLE_MONITOR_BOOT
# (epoch seconds) stand in for the clock, which is how the tests drive it.
set -uo pipefail

ENV_FILE="${IDLE_MONITOR_ENV:-/etc/devbox/idle-monitor.env}"
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
IDLE_MINUTES="${IDLE_MINUTES:-10}"
STATE_DIR="${STATE_DIR:-/srv/ci/.lin-test}"
LOG="${IDLE_MONITOR_LOG:-/var/log/devbox-idle-monitor.log}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG" 2>/dev/null || true; [ -t 1 ] && echo "$*"; return 0; }
# One rotation keeps about the last megabyte without unbounded growth.
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then mv -f "$LOG" "$LOG.1"; fi

case "$IDLE_MINUTES" in ''|*[!0-9]*) log "ERROR: IDLE_MINUTES is not a number: '$IDLE_MINUTES'"; exit 0 ;; esac

lock="$STATE_DIR/run.lock"
hb="$STATE_DIR/last-activity"

# 1. Active run? A non-blocking attempt on the same lock the runner takes: it fails
#    exactly while a run holds it. (A queued run is waiting on a holder, so a queue
#    always reads as active too.) Once taken, the lock is KEPT until this script ends,
#    so no run can start between the decision below and the deallocate call. Opened
#    read-only, and only if the runner has already made it: this script is root, and a
#    root-owned lock file would shut the runner out.
if [ -e "$lock" ]; then
  exec 8<"$lock"
  if ! flock -n 8; then
    log "run active (lock held) -- staying up"
    exit 0
  fi
fi
heartbeat_time() { stat -c %Y "$hb" 2>/dev/null || echo 0; }

# 2. Idle long enough?
now="${IDLE_MONITOR_NOW:-$(date +%s)}"
since="${IDLE_MONITOR_BOOT:-$(awk '/^btime /{print $2}' /proc/stat)}"
hbt=$(heartbeat_time)
[ "$hbt" -gt "$since" ] && since=$hbt
idle_s=$(( now - since ))
if [ "$idle_s" -lt $(( IDLE_MINUTES * 60 )) ]; then
  log "idle $(( idle_s / 60 )) min < $IDLE_MINUTES -- staying up"
  exit 0
fi

# 3. Deallocate self.
log "idle $(( idle_s / 60 )) min >= $IDLE_MINUTES -- deallocating"
if [ "${IDLE_MONITOR_DRY_RUN:-0}" = 1 ]; then log "dry run: not calling Azure"; exit 0; fi

imds=http://169.254.169.254/metadata
md=$(curl -fsS --max-time 10 -H Metadata:true "$imds/instance/compute?api-version=2021-02-01") \
  || { log "ERROR: instance metadata unavailable"; exit 0; }
tok=$(curl -fsS --max-time 10 -H Metadata:true \
        "$imds/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F" \
      | jq -r '.access_token // empty') || tok=""
[ -n "$tok" ] || { log "ERROR: no managed-identity token (is the identity assigned?)"; exit 0; }
sub=$(printf '%s' "$md" | jq -r .subscriptionId)
rg=$(printf '%s' "$md" | jq -r .resourceGroupName)
vm=$(printf '%s' "$md" | jq -r .name)
uri="https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/$vm/deallocate?api-version=2024-07-01"
# A caller's first contact touches the heartbeat before it asks for the lock. If one
# arrived while the token was being fetched, the box is no longer idle: stand down.
if [ "$(heartbeat_time)" -gt "$hbt" ]; then
  log "a run arrived while preparing to deallocate -- staying up"
  exit 0
fi
# The token goes to curl on stdin (a config file), never on its command line.
if printf 'header = "Authorization: Bearer %s"\n' "$tok" \
     | curl -fsS --max-time 30 -X POST -H 'Content-Length: 0' -K - "$uri" >/dev/null; then
  log "deallocate requested via ARM"
else
  # A failed call just waits for the next tick.
  log "ERROR: the deallocate call failed"
fi
exit 0
