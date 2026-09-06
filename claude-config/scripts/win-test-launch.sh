#!/usr/bin/env bash
# win-test-launch.sh — start a win-test.sh run DETACHED and return immediately with the
# log path and PID.
#
# Why this exists: an appliance run takes 5–25 minutes, and a foreground command in the
# agent harness is killed after roughly ten. Every session was therefore hand-rolling its
# own `tmp/wt-<suite>.sh` wrapper — the same setsid/nohup/redirect incantation, re-derived
# and re-bugged each time, and folklore rather than code. This is that wrapper, once.
#
# It does three things a bare `&` does not:
#   * setsid + nohup, stdin closed — the run gets its own session and process group, so it
#     survives the harness reaping the foreground job and its parent shell exiting;
#   * a real log file, named for the suite and stamped, in the worktree's own ./tmp/;
#   * a WRAPPER_EXIT <rc> line appended when the run ends — so a watcher can tell
#     "still running" from "finished, exit 0" from "finished, exit 1" without guessing.
#
# Usage:
#   win-test-launch.sh [<any win-test.sh argument>...]
#
#   win-test-launch.sh --suite full          # classic + modern on one boot
#   win-test-launch.sh --suite modern        # just the net10 projects
#   win-test-launch.sh /path/to/worktree --suite all --clean
#
# Every argument is passed through to win-test.sh untouched; this script parses only
# enough (--suite, and the leading worktree path) to name the log file.
#
# Output (stdout, immediately):
#   win-test-launch: started PID=<pid> LOG=<path>
#   tail -f <path>
#
# Env:
#   WIN_TEST_SCRIPT   path to win-test.sh (default: alongside this script)
set -euo pipefail

die() { echo "win-test-launch: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WIN_TEST="${WIN_TEST_SCRIPT:-$HERE/win-test.sh}"
[ -x "$WIN_TEST" ] || [ -r "$WIN_TEST" ] || die "can't find win-test.sh at $WIN_TEST"

# --- the appliance is single-tenant ---------------------------------------------
# One box, one LocalDB, one 'TestRunegate' catalog. The box-side runner does hold a lock,
# so a second run queues rather than corrupts — but it queues for up to 30 minutes and
# then may still time out, which reads as a mysterious failure rather than "you started
# two". Refuse here, where the cause is obvious and the fix is to wait.
#
# A real lock, NOT a pgrep of the process table. Scanning command lines looks equivalent
# and is not: under an agent harness every shell command is wrapped in a `bash -c` whose
# command line echoes the command text, so any process that merely MENTIONS this script's
# path matches — including the very command asking "is a run in progress?". That guard
# false-positives constantly and refuses runs that should proceed. flock is held by the
# detached run itself, for exactly as long as it lives, and describes nothing else.
#
# The lock is per-user and fixed-path on purpose: runs are launched from many different
# worktrees, so a lock inside any one of them would not see the others.
command -v flock >/dev/null 2>&1 || die "'flock' not found on PATH (needed to serialize runs)"
LOCK="$HOME/.claude/win-test.lock"
mkdir -p "$(dirname "$LOCK")" || die "couldn't create $(dirname "$LOCK")"
# Pre-check, so a refusal is immediate and legible rather than something the operator has
# to infer from a log. The authoritative acquisition is in the detached run below; this
# only decides whether it is worth launching.
# `9<>` (read-write), NOT `9>`: the truncating form would wipe the running run's own
# holder record before we ever read it, so the refusal below could never say who holds it.
exec 9<>"$LOCK" || die "couldn't open the lock file $LOCK"
if ! flock -n 9; then
  holder=$(cat "$LOCK" 2>/dev/null || true)
  echo "win-test-launch: a run is already in progress on the appliance." >&2
  [ -n "$holder" ] && echo "  holder: $holder" >&2
  die "refusing to start a second run (the box is single-tenant). Wait for it to finish."
fi
flock -u 9
exec 9>&-

# --- work out where to put the log ----------------------------------------------
# Mirror win-test.sh's own argument reading: the first non-flag argument is the worktree,
# and --suite takes a value. Anything else is ignored here and simply forwarded.
suite="integration"; worktree=""
prev=""
for a in "$@"; do
  case "$prev" in --suite) suite="$a"; prev=""; continue ;; esac
  case "$a" in
    --suite) prev="--suite" ;;
    --env-file) prev="--env-file" ;;
    -*) prev="" ;;
    *) if [ "$prev" = "--env-file" ]; then prev=""; elif [ -z "$worktree" ]; then worktree="$a"; fi ;;
  esac
done

# Log into the checkout under test, so a run's evidence lives with the work that prompted
# it and parallel worktrees never share a log.
if [ -z "$worktree" ]; then
  worktree=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not in a git worktree; pass the checkout path as the first argument"
fi
[ -d "$worktree" ] || die "no such worktree: $worktree"

LOG_DIR="$worktree/tmp"
mkdir -p "$LOG_DIR" || die "couldn't create $LOG_DIR"
LOG="$LOG_DIR/win-test-$suite-$(date +%Y%m%d-%H%M%S).log"

# --- launch ---------------------------------------------------------------------
# setsid detaches into a new session (no controlling terminal, immune to the harness's
# process-group kill); nohup covers SIGHUP; </dev/null so the run can never block reading
# stdin. The inner shell appends WRAPPER_EXIT after win-test.sh returns — inside the
# detached session, so it is recorded even though nothing is waiting on the run out here.
#
# The run takes the lock ITSELF and holds it on fd 9 for its whole life: a lock the
# launcher held would die with the launcher, seconds in, leaving the next launch free to
# start a second concurrent run. Losing the race here (someone launched between our
# pre-check and now) is reported into the log and exits 75, so the log still ends in a
# WRAPPER_EXIT line and a watcher is never left waiting on a run that never started.
# $0=log, $1=win-test.sh, $2=lock file, $3.. = the user's arguments.
setsid nohup bash -c '
  exec 9<>"$2" || { echo "win-test-launch: could not open the lock file $2" >>"$0"; echo "WRAPPER_EXIT 75" >>"$0"; exit 75; }
  if ! flock -n 9; then
    echo "win-test-launch: another run took the lock first; not starting." >>"$0"
    echo "WRAPPER_EXIT 75" >>"$0"; exit 75
  fi
  # Record who holds it, for the next launcher to report. Safe to truncate through a
  # second descriptor: flock is on the inode and survives it.
  : > "$2"; echo "pid $$ log $0 started $(date -Is)" > "$2"
  "$1" "${@:3}" >>"$0" 2>&1
  echo "WRAPPER_EXIT $?" >>"$0"
' "$LOG" "$WIN_TEST" "$LOCK" "$@" >/dev/null 2>&1 </dev/null &
pid=$!
disown "$pid" 2>/dev/null || true

# Give it a moment to fail fast (bad flag, no runner.env) so an obviously-dead run is
# reported now rather than discovered later in an empty log.
sleep 2
if ! kill -0 "$pid" 2>/dev/null && [ ! -s "$LOG" ]; then
  die "the run exited immediately and wrote nothing to $LOG — check the arguments"
fi

echo "win-test-launch: started PID=$pid LOG=$LOG"
echo "win-test-launch: suite='$suite' worktree=$worktree"
echo "  tail -f $LOG"
echo "  # done when the log's last line is WRAPPER_EXIT <rc>"
