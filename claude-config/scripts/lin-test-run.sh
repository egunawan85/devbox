#!/usr/bin/env bash
# lin-test-run.sh — the BOX-SIDE half of /lin-test. Runs one command against a synced
# worktree on the Linux test appliance, under the box-wide run lock.
#
# It is not installed on the appliance: the orchestrator (lin-test.sh, on the devbox)
# copies this file over at the start of every run, so the box always runs the version
# the devbox has and there is no second copy to drift. See docs/lin-test.spec.md.
#
#   lin-test-run.sh <ci_dir> <run_id>
#
# The orchestrator prepares <ci_dir>/.lin-test/runs/<run_id>/ before starting this:
#   params     KEY=VALUE lines: REPO, BRANCH, CLEAN, RUN_TIMEOUT, LOCK_TIMEOUT,
#              SYNC_TIMEOUT, RETAIN_DAYS, MIN_FREE_GB
#   command    the shell text to run in the synced worktree
#   branches   the repo's live branches (sanitized names, one per line), for pruning
# and adds, once this script reports `locked`:
#   manifest   NUL-separated list of the files it synced
#   synced     an empty file: "the worktree is in place, go"
#   abort      (any time) an empty file: "give up" — the command is stopped
#
# What this script writes there:
#   state      queued -> locked -> running -> done
#   run.log    this script's own lines and the command's whole output
#   done.json  the verdict, written last and only once: run id, exit code, seconds,
#              an error if the run never reached a verdict, and the summary line
#
# One process holds the lock from before the sync until after the command, so two runs
# can never interleave: not their files in one branch folder, and not their Docker
# containers on the box's fixed local ports. Runs that arrive meanwhile wait their turn.
# This script starts nothing in Azure and stops nothing: the box turns itself off
# (deploy/azure/idle-monitor.sh), reading the lock and the heartbeat kept here.
set -uo pipefail

CI_DIR="${1:?usage: lin-test-run.sh <ci_dir> <run_id>}"
RUN_ID="${2:?usage: lin-test-run.sh <ci_dir> <run_id>}"
case "$RUN_ID" in *[!A-Za-z0-9._-]*|.*) echo "lin-test-run: bad run id" >&2; exit 2 ;; esac

STATE="$CI_DIR/.lin-test"
RUNDIR="$STATE/runs/$RUN_ID"
LOG="$RUNDIR/run.log"
HEARTBEAT="$STATE/last-activity"
[ -d "$RUNDIR" ] || { echo "lin-test-run: no run directory $RUNDIR" >&2; exit 2; }
mkdir -p "$STATE/manifests" "$STATE/used"

START=$(date +%s)
say() { printf 'lin-test-run: %s\n' "$*" >>"$LOG"; }
set_state() { printf '%s\n' "$1" >"$RUNDIR/state.tmp" && mv -f "$RUNDIR/state.tmp" "$RUNDIR/state"; }

# The verdict. Written once, last, and atomically: the orchestrator treats its presence
# as "finished", so nothing after it may matter and a half-written file must never show.
FINISHED=0
finish() { # $1 = exit code, $2 = error text (empty when the command itself gave the verdict), $3 = summary
  [ "$FINISHED" = 0 ] || return 0
  FINISHED=1
  local secs=$(( $(date +%s) - START ))
  jq -n --arg id "$RUN_ID" --argjson rc "$1" --argjson s "$secs" --arg err "${2:-}" --arg sum "${3:-}" \
    '{runId:$id, rc:$rc, seconds:$s, error:$err, summary:$sum}' >"$RUNDIR/done.json.tmp" 2>/dev/null \
    || printf '{"runId":"%s","rc":%s,"seconds":%s,"error":"could not encode the verdict","summary":""}\n' \
         "$RUN_ID" "$1" "$secs" >"$RUNDIR/done.json.tmp"
  mv -f "$RUNDIR/done.json.tmp" "$RUNDIR/done.json"
  set_state done
}

# ---- heartbeat ---------------------------------------------------------------
# Touched for as long as this script lives — while queued, while waiting for the sync and
# while the command runs — so the idle monitor never measures a busy box as idle. Started
# BEFORE the lock is opened, so the loop does not inherit the lock's descriptor and
# cannot hold the lock past this script's death.
# It also ends by itself within seconds of this script dying — however it dies, a kill -9
# included, where no trap runs — so a dead run's heartbeat goes stale and the idle
# monitor is never held off by a loop that outlived its run.
RUNNER_PID=$$
touch "$HEARTBEAT"
( n=0
  while kill -0 "$RUNNER_PID" 2>/dev/null; do
    [ $(( n % 6 )) = 0 ] && touch "$HEARTBEAT" 2>/dev/null
    n=$((n + 1)); sleep 5
  done ) &
HB_PID=$!
CMD_PID=""
# Stop the command's whole process group: TERM, then KILL. The process itself is
# signalled as well as its group, and TERM is re-sent each second, because a command
# stopped in its first instant has not formed its group yet — signalling only the group
# would then reach nothing and leave this script waiting on a command nobody stopped.
stop_command() {
  [ -n "$CMD_PID" ] || return 0
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -TERM -- "-$CMD_PID" 2>/dev/null; kill -TERM "$CMD_PID" 2>/dev/null
    sleep 1
    kill -0 -- "-$CMD_PID" 2>/dev/null || kill -0 "$CMD_PID" 2>/dev/null || return 0
  done
  kill -KILL -- "-$CMD_PID" 2>/dev/null; kill -KILL "$CMD_PID" 2>/dev/null
  return 0
}
GUARD_PID=""
cleanup() { kill "$HB_PID" $GUARD_PID 2>/dev/null || true; touch "$HEARTBEAT" 2>/dev/null || true; }
# rm that also gets past files a container wrote as root (a bind-mounted folder is the
# usual source). The login user has passwordless sudo; every path given here is built
# from names already held to a strict character set.
remove_tree() { rm -rf -- "$1" 2>/dev/null; [ ! -e "$1" ] || sudo -n rm -rf -- "$1" 2>/dev/null; [ ! -e "$1" ]; }
trap cleanup EXIT
trap 'say "stopped by a signal"; stop_command; finish 143 "the runner was stopped by a signal" ""; exit 143' TERM INT HUP

# ---- parameters ----------------------------------------------------------------
# Read, never sourced: each value is held to a strict character set, so nothing the
# orchestrator sends can become shell here. (The command is the one deliberate exception
# — it is shell text by definition, and runs as the unprivileged login user.)
param() {
  local v
  v=$(sed -n "s/^$1=//p" "$RUNDIR/params" 2>/dev/null | head -n 1)
  case "$v" in *[!A-Za-z0-9._-]*) v="" ;; esac
  printf '%s' "${v:-${2:-}}"
}
REPO=$(param REPO); BRANCH=$(param BRANCH); CLEAN=$(param CLEAN 0)
RUN_TIMEOUT=$(param RUN_TIMEOUT 2400); LOCK_TIMEOUT=$(param LOCK_TIMEOUT 3600); SYNC_TIMEOUT=$(param SYNC_TIMEOUT 900)
RETAIN_DAYS=$(param RETAIN_DAYS 14); MIN_FREE_GB=$(param MIN_FREE_GB 20)
num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
: >>"$LOG"
set_state queued
case "$REPO"   in ''|.*|-*) finish 2 "bad or missing REPO in the run parameters" "";   exit 2 ;; esac
case "$BRANCH" in ''|.*|-*) finish 2 "bad or missing BRANCH in the run parameters" ""; exit 2 ;; esac
for n in "$RUN_TIMEOUT" "$LOCK_TIMEOUT" "$SYNC_TIMEOUT" "$RETAIN_DAYS" "$MIN_FREE_GB"; do
  num "$n" || { finish 2 "a numeric run parameter is not a number" ""; exit 2; }
done
[ -s "$RUNDIR/command" ] || { finish 2 "no command was given to run" ""; exit 2; }
DEST="$CI_DIR/$REPO/$BRANCH"
# Per-branch records live at <kind>/<repo>/<branch>: a path, so no pair of names can be
# mistaken for another pair the way a joined "repo--branch" key could.
KEY="$REPO/$BRANCH"
mkdir -p "$STATE/manifests/$REPO" "$STATE/used/$REPO"
# A sync that started and was then given up on has still put files in the folder. Its
# file list is added to the branch's record, so the next run's comparison knows about
# them and removes any the worktree no longer has.
remember_partial_sync() {
  [ -s "$RUNDIR/manifest" ] || return 0
  cat "$RUNDIR/manifest" >>"$STATE/manifests/$KEY" 2>/dev/null || true
}

# ---- 1. the box-wide lock ------------------------------------------------------
# flock(2): the kernel releases it when this process dies, however it dies, so a killed
# run leaves nothing behind to clean up. Waiting runs are served as the lock frees.
exec 9>>"$STATE/run.lock"
if ! flock -n 9; then
  say "another run holds the box; waiting (up to ${LOCK_TIMEOUT}s)"
  if ! flock -w "$LOCK_TIMEOUT" 9; then
    say "gave up waiting for the lock after ${LOCK_TIMEOUT}s"
    finish 75 "timed out after ${LOCK_TIMEOUT}s waiting for the run lock (another run is stuck or very long)" ""
    exit 75
  fi
fi
[ -e "$RUNDIR/abort" ] && { finish 130 "the run was abandoned before it started" ""; exit 130; }

# ---- 2. make room for the sync, then wait for it -------------------------------
if [ "$CLEAN" = 1 ] && [ -d "$DEST" ]; then
  say "--clean: removing $DEST"
  remove_tree "$DEST" || { finish 2 "--clean could not remove $DEST" ""; exit 2; }
  rm -f -- "$STATE/manifests/$KEY"
fi
mkdir -p "$DEST" || { finish 2 "could not create $DEST" ""; exit 2; }
set_state locked
waited=0
until [ -e "$RUNDIR/synced" ]; do
  if [ -e "$RUNDIR/abort" ]; then remember_partial_sync; finish 130 "the run was abandoned during the sync" ""; exit 130; fi
  if [ "$waited" -ge "$SYNC_TIMEOUT" ]; then
    remember_partial_sync
    finish 75 "the worktree never arrived: no sync completed within ${SYNC_TIMEOUT}s" ""; exit 75
  fi
  sleep 1; waited=$((waited + 1))
done

# ---- 3. bring the folder into line with what was synced ------------------------
# The sync only ever adds and updates (it sends the files git knows about and leaves
# node_modules and build output alone). A file deleted in the worktree is removed here:
# whatever the PREVIOUS sync of this branch sent that this one did not.
if [ -f "$RUNDIR/manifest" ]; then
  prev="$STATE/manifests/$KEY"
  if [ -f "$prev" ]; then
    removed=0
    while IFS= read -r -d '' p; do
      case "/$p/" in */../*|//*) continue ;; esac     # never outside the branch folder
      rm -f -- "$DEST/$p" 2>/dev/null && removed=$((removed + 1))
      ( cd "$DEST" && rmdir -p --ignore-fail-on-non-empty -- "$(dirname -- "$p")" 2>/dev/null ) || true
    done < <(LC_ALL=C comm -z -23 <(LC_ALL=C sort -z "$prev") <(LC_ALL=C sort -z "$RUNDIR/manifest"))
    [ "$removed" -gt 0 ] && say "removed $removed file(s) deleted from the worktree since the last sync"
  fi
  cp -f "$RUNDIR/manifest" "$prev"
fi

# A check may ask git what the project's files are (`git ls-files`), and the worktree's
# own .git cannot be synced — in a linked worktree it is a pointer into another checkout.
# So the folder gets a stand-in repository: one snapshot commit of exactly what is here,
# re-made each run. It has no history, no remote and no credentials; a check that needs
# real history will fail here, and that is a finding to report, not something to fake.
# (Lock descriptor closed and automatic gc off: git must not leave a background process
# holding the box's lock after this run.)
(
  cd "$DEST" || exit 1
  [ -d .git ] || git init -q . || exit 1
  g() { git -c user.name=lin-test -c user.email=lin-test@invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false -c gc.auto=0 -c maintenance.auto=false "$@"; }
  g add -A || exit 1
  if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    g commit -q --amend --allow-empty --no-verify -m "lin-test snapshot"
  else
    g commit -q --allow-empty --no-verify -m "lin-test snapshot"
  fi
) 9>&- >>"$LOG" 2>&1 || say "WARNING: could not make the stand-in git repository; a check that calls git will fail"
touch "$STATE/used/$KEY"

# ---- 4. run the command --------------------------------------------------------
# In its own session, so the whole tree it starts can be stopped as one group; with the
# lock's descriptor closed, so nothing it leaves running can hold the box's lock; and
# with stdin closed, so nothing in it can wait on input that will never come.
set_state running
say "running in $DEST (limit ${RUN_TIMEOUT}s): $(tr '\n' ' ' <"$RUNDIR/command")"
( cd "$DEST" && exec setsid bash "$RUNDIR/command" ) 9>&- </dev/null >>"$LOG" 2>&1 &
CMD_PID=$!
# If this script is killed outright (no trap runs), the command must not carry on
# without the lock that died with it: a watcher that outlives this script stops it.
( while kill -0 "$RUNNER_PID" 2>/dev/null; do sleep 2; done
  kill -TERM -- "-$CMD_PID" 2>/dev/null; kill -TERM "$CMD_PID" 2>/dev/null; sleep 10
  kill -KILL -- "-$CMD_PID" 2>/dev/null; kill -KILL "$CMD_PID" 2>/dev/null ) 9>&- >/dev/null 2>&1 &
GUARD_PID=$!
cmd_start=$(date +%s); rc=""; err=""
while kill -0 "$CMD_PID" 2>/dev/null; do
  if [ -e "$RUNDIR/abort" ]; then
    say "abandoned by the caller; stopping the command"
    stop_command; rc=130; err="the run was abandoned by the caller"; break
  fi
  if [ $(( $(date +%s) - cmd_start )) -ge "$RUN_TIMEOUT" ]; then
    say "the command passed its ${RUN_TIMEOUT}s limit; stopping it"
    stop_command; rc=124; err="timed out: the command was still running after ${RUN_TIMEOUT}s (possible hang)"; break
  fi
  sleep 2
done
if [ -z "$rc" ]; then wait "$CMD_PID"; rc=$?; else wait "$CMD_PID" 2>/dev/null; fi
# Whatever the command left running in its process group goes with it, before the lock
# is given up: the next run must not meet this one's stray processes on the same ports.
# (Containers belong to the Docker daemon, not to this group, and are left as the
# project left them — as they would be on the devbox.)
if kill -0 -- "-$CMD_PID" 2>/dev/null; then
  say "stopping processes the command left running"
  stop_command
fi
kill "$GUARD_PID" 2>/dev/null; GUARD_PID=""
CMD_PID=""
say "command exited $rc after $(( $(date +%s) - cmd_start ))s"

# ---- 5. the summary line -------------------------------------------------------
# The exit code is the verdict. The counts are an aid, read from the log where the
# output is one this script recognizes (vitest's "Tests  N passed | M failed" lines,
# summed over every run in the log); where it is not, counts=none says so rather than
# printing zeros that would read as "nothing failed".
counts=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" | awk '
  /^[[:space:]]*Tests[[:space:]]+[0-9]/ {
    runs++
    n = split($0, part, /[|(]/)
    for (i = 1; i <= n; i++) {
      if (match(part[i], /[0-9]+ passed/))  passed  += substr(part[i], RSTART, RLENGTH) + 0
      if (match(part[i], /[0-9]+ failed/))  failed  += substr(part[i], RSTART, RLENGTH) + 0
      if (match(part[i], /[0-9]+ skipped/)) skipped += substr(part[i], RSTART, RLENGTH) + 0
      if (match(part[i], /[0-9]+ todo/))    skipped += substr(part[i], RSTART, RLENGTH) + 0
    }
  }
  END {
    if (runs) printf "counts=vitest runs=%d passed=%d failed=%d skipped=%d", runs, passed, failed, skipped
    else      printf "counts=none"
  }')
summary="LIN-TEST-SUMMARY repo=$REPO branch=$BRANCH rc=$rc seconds=$(( $(date +%s) - START )) $counts"
say "$summary"

# ---- 6. housekeeping (never fails a run) ---------------------------------------
# Still under the lock, so nothing is removed from under a run. Drops branch folders
# unused for RETAIN_DAYS and those of this repo whose branch no longer exists; then, if
# the disk is short, the least recently used ones — never this run's own.
gc() {
  local d repo branch key stamp now cutoff free
  now=$(date +%s); cutoff=$(( now - RETAIN_DAYS * 86400 ))
  # A folder that will not go keeps its records, and reports failure so the free-space
  # loop below stops rather than choosing it again for ever.
  drop() {
    say "pruning $1 ($2)"
    remove_tree "$1" || { say "could not remove $1"; return 1; }
    rm -f -- "$STATE/manifests/$3" "$STATE/used/$3"; rmdir -- "$(dirname -- "$1")" 2>/dev/null
    return 0
  }
  for d in "$CI_DIR"/*/*/; do
    [ -d "$d" ] || continue
    d=${d%/}; branch=${d##*/}; repo=${d%/*}; repo=${repo##*/}; key="$repo/$branch"
    [ "$d" = "$DEST" ] && continue
    stamp=$(stat -c %Y "$STATE/used/$key" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo "$now")
    if [ "$stamp" -lt "$cutoff" ]; then drop "$d" "unused for more than $RETAIN_DAYS days" "$key" || true; continue; fi
    if [ "$repo" = "$REPO" ] && [ -s "$RUNDIR/branches" ] && ! grep -qxF -- "$branch" "$RUNDIR/branches"; then
      drop "$d" "its branch no longer exists" "$key" || true
    fi
  done
  local tries=0
  while [ "$tries" -lt 50 ]; do
    tries=$((tries + 1))
    free=$(df -BG --output=avail "$CI_DIR" 2>/dev/null | tail -n 1 | tr -dc '0-9')
    [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_GB" ] || break
    d=$(for x in "$CI_DIR"/*/*/; do
          [ -d "$x" ] || continue; x=${x%/}; [ "$x" = "$DEST" ] && continue
          b=${x##*/}; r=${x%/*}; r=${r##*/}
          printf '%s %s\n' "$(stat -c %Y "$STATE/used/$r/$b" 2>/dev/null || echo 0)" "$x"
        done | sort -n | head -n 1 | cut -d' ' -f2-)
    [ -n "$d" ] || break
    b=${d##*/}; r=${d%/*}; r=${r##*/}
    drop "$d" "free disk ${free}G is under ${MIN_FREE_GB}G" "$r/$b" || break
  done
  # Old run records (logs and verdicts) go with the same retention.
  find "$STATE/runs" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETAIN_DAYS" ! -name "$RUN_ID" -exec rm -rf {} + 2>/dev/null
  return 0
}
gc || true

finish "$rc" "$err" "$summary"
exit "$rc"
