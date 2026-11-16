#!/usr/bin/env bash
# lin-test-launch.sh — start a lin-test.sh run DETACHED and return immediately with the
# log path and PID.
#
# A full check takes several minutes — longer when it queues behind another run or the
# branch is cold — and a foreground command in the agent harness is killed after roughly
# ten. This is the wrapper for that, once, instead of a hand-rolled one per session:
#   * setsid + nohup, stdin closed — the run gets its own session and process group, so
#     it survives the harness reaping the foreground job and its parent shell exiting;
#   * a real log file, stamped, in the worktree's own ./tmp/lin-test/;
#   * a WRAPPER_EXIT <rc> line appended when the run ends — so a watcher can tell "still
#     running" from "finished, exit 0" from "finished, exit 1" without guessing.
#
# Unlike win-test-launch.sh it holds no lock and refuses nothing: runs that overlap are
# expected here, and they queue on the box (docs/lin-test.spec.md, Concurrency).
#
# Usage:
#   lin-test-launch.sh [<any lin-test.sh argument>...]
#
#   lin-test-launch.sh                           # this worktree, the project's own check
#   lin-test-launch.sh -- corepack pnpm test     # this worktree, a command of yours
#   lin-test-launch.sh /path/to/worktree --clean
#
# Every argument is passed through to lin-test.sh untouched; this script reads only the
# leading worktree path, to decide where the log goes.
#
# Output (stdout, immediately):
#   lin-test-launch: started PID=<pid> LOG=<path>
#
# Env:
#   LIN_TEST_SCRIPT   path to lin-test.sh (default: alongside this script)
set -euo pipefail

die() { echo "lin-test-launch: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
LIN_TEST="${LIN_TEST_SCRIPT:-$HERE/lin-test.sh}"
[ -r "$LIN_TEST" ] || die "can't find lin-test.sh at $LIN_TEST"

# Mirror lin-test.sh's own reading: the first argument that is not a flag (and comes
# before any --) is the worktree; --cmd takes a value.
worktree=""; prev=""
for a in "$@"; do
  if [ "$prev" = --cmd ]; then prev=""; continue; fi
  case "$a" in
    --) break ;;
    --cmd) prev="$a" ;;
    -*) ;;
    *) worktree="$a"; break ;;
  esac
done
if [ -z "$worktree" ]; then
  worktree=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not in a git worktree; pass the checkout path as the first argument"
fi
[ -d "$worktree" ] || die "no such worktree: $worktree"

# Log into the checkout under test, so a run's evidence lives with the work that prompted
# it and parallel worktrees never share a log.
# Beside the fetched results, in the one folder the sync leaves out.
LOG_DIR="$worktree/tmp/lin-test"
mkdir -p "$LOG_DIR" || die "couldn't create $LOG_DIR"
LOG="$LOG_DIR/launch-$(date +%Y%m%d-%H%M%S)-$$.log"

# $0=log, $1=lin-test.sh, $2.. = the caller's arguments. WRAPPER_EXIT is appended inside
# the detached session, so it is recorded even though nothing out here waits on the run.
setsid nohup bash -c '
  bash "$1" "${@:2}" >>"$0" 2>&1
  echo "WRAPPER_EXIT $?" >>"$0"
' "$LOG" "$LIN_TEST" "$@" >/dev/null 2>&1 </dev/null &
pid=$!
disown "$pid" 2>/dev/null || true

# Give it a moment to fail fast (bad flag, no runner.env) so an obviously-dead run is
# reported now rather than discovered later in an empty log.
sleep 2
if ! kill -0 "$pid" 2>/dev/null; then
  if [ ! -s "$LOG" ]; then die "the run exited immediately and wrote nothing to $LOG — check the arguments"; fi
  echo "lin-test-launch: the run has already ended:" >&2
  tail -n 5 "$LOG" >&2
fi

echo "lin-test-launch: started PID=$pid LOG=$LOG"
echo "  tail -f $LOG"
echo "  # done when the log's last line is WRAPPER_EXIT <rc>"
