#!/usr/bin/env bash
# win-test.sh — run a worktree's Windows-only test suite on the ephemeral Azure
# appliance, from the Linux devbox.
#
# The runegate / kash-cards integration suites target .NET Framework 4.8 + SQL Server
# LocalDB, which only run on Windows. This script is the Linux-side orchestrator: it
# wakes the `win-test` appliance, syncs the current worktree to it, runs the suite over
# SSH, and brings the results back — so you develop on Linux and still get a real Windows
# test result. See docs/win-test.overview.md (why) and docs/win-test.spec.md (contract).
#
# What it does NOT do: deallocate the box. The box owns its own lifecycle — a box-side
# idle-monitor deallocates it once no run is active and it's been idle IDLE_MINUTES. That
# avoids a race where one session stops the box out from under another (parallel sessions
# just queue on a box-side lock). See the spec's Concurrency section.
#
# Usage:
#   win-test.sh [<worktree>] [--suite unit|integration|smoke|all] [--clean]
#     <worktree>   path to the checkout to test (default: the current git worktree root)
#     --suite      which suite to run (default: integration)
#     --clean      wipe this branch's synced dir on the box first (cold build)
#
# Env tunables:
#   WIN_TEST_TIMEOUT        overall run timeout, seconds (default 3600). On exceed the
#                           watchdog collects diagnostics, fetches any partial results,
#                           and exits 124 — it never hangs indefinitely.
#   WIN_TEST_POLL           seconds between status polls / heartbeat lines (default 30)
#   WIN_TEST_RUNNER_ENV     alternate runner.env path
#   WIN_TEST_REMOTE_RUNNER  alternate box-side runner script (testing hook)
#
# Reads box identity from ~/.config/devbox/win-test/runner.env, which `devbox -p win-test
# up` writes. If that file is absent, the appliance hasn't been stood up yet.
#
# Output: a human summary + the TRX/console log fetched into ./tmp/win-test/. Exit code
# mirrors the suite (0 = all passed). Fails loud; never reports green without a real run.
set -euo pipefail

RUNNER_ENV="${WIN_TEST_RUNNER_ENV:-$HOME/.config/devbox/win-test/runner.env}"
# Installed on the box by install.ps1. Literal $HOME on purpose: the box-side PowerShell
# expands it; a '~' would reach pwsh -File unexpanded and fail as "not a script file".
REMOTE_RUNNER="${WIN_TEST_REMOTE_RUNNER:-\$HOME/.claude/scripts/win-test-run.ps1}"
TIMEOUT_S="${WIN_TEST_TIMEOUT:-3600}"
POLL_S="${WIN_TEST_POLL:-30}"

die() { echo "win-test: $*" >&2; exit 1; }

# --- deps -----------------------------------------------------------------------
for bin in az ssh rsync git timeout; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done
# rsync gives warm incremental syncs (only changed files cross the wire) — the box gets a
# matching rsync from its toolchain install (spec §R). scp would re-copy everything.

# --- args -----------------------------------------------------------------------
WORKTREE=""; SUITE="integration"; CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --suite) SUITE="${2:?--suite needs a value}"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) sed -n '1,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  WORKTREE="$1"; shift ;;
  esac
done
case "$SUITE" in unit|integration|smoke|all) ;; *) die "bad --suite: $SUITE" ;; esac

# Default to the current worktree's root (so `cd <worktree>; /win-test` just works).
if [ -z "$WORKTREE" ]; then
  WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git worktree; pass <worktree>"
fi
[ -d "$WORKTREE" ] || die "no such worktree: $WORKTREE"
BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null) || die "can't read branch of $WORKTREE"
# Branch name → a filesystem-safe remote dir segment (feature/x → feature-x).
SAFE_BRANCH=$(printf '%s' "$BRANCH" | tr '/\\ ' '---')

# --- box identity ---------------------------------------------------------------
[ -r "$RUNNER_ENV" ] || die "no appliance config at $RUNNER_ENV — run 'devbox -p win-test up' first"
# shellcheck disable=SC1090
. "$RUNNER_ENV"
: "${RESOURCE_GROUP:?runner.env missing RESOURCE_GROUP}"
: "${VM_NAME:?runner.env missing VM_NAME}"
: "${SSH_HOST:?runner.env missing SSH_HOST}"
: "${SSH_PORT:=2222}"; : "${SSH_USER:=eddyg}"; : "${CI_DIR:=C:/ci}"
[ -n "${SUBSCRIPTION_ID:-}" ] && az account set --subscription "$SUBSCRIPTION_ID"

SSH=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST")

# --- 1. wake the box (idempotent; no-op if already running) ---------------------
state=$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" \
          --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv 2>/dev/null || true)
if [ "$state" != "PowerState/running" ]; then
  echo "win-test: starting $VM_NAME (was: ${state:-unknown})…"
  az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null
fi

# --- 2. wait for SSH ------------------------------------------------------------
echo "win-test: waiting for ssh $SSH_USER@$SSH_HOST:$SSH_PORT…"
for _ in $(seq 1 60); do
  if "${SSH[@]}" 'exit' >/dev/null 2>&1; then ready=1; break; fi
  sleep 5
done
[ "${ready:-0}" = 1 ] || die "ssh never came up (box started but unreachable)"

# --- 3. sync the worktree (warm, incremental) -----------------------------------
DEST="$CI_DIR/$SAFE_BRANCH"
# The box's rsync (cwRsync) is cygwin: it reads "C:/ci/…" as a RELATIVE path (prefixing
# $HOME), so rsync gets the /cygdrive/c/… spelling while PowerShell keeps the C:/… one.
win2cyg() {
  case "$1" in
    [A-Za-z]:*) printf '/cygdrive/%s%s' "$(printf '%.1s' "$1" | tr '[:upper:]' '[:lower:]')" "${1#?:}" ;;
    *) printf '%s' "$1" ;;
  esac
}
DEST_CYG=$(win2cyg "$DEST")
if [ "$CLEAN" = 1 ]; then
  echo "win-test: --clean → wiping $DEST on the box"
  "${SSH[@]}" "pwsh -NoProfile -Command \"Remove-Item -Recurse -Force '$DEST' -ErrorAction SilentlyContinue\""
fi
echo "win-test: syncing $WORKTREE → $DEST"
# rsync only creates the LAST path component, so make sure the branch dir (and C:\ci
# above it) exists before the first sync into it.
"${SSH[@]}" "pwsh -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '$DEST' | Out-Null\""
# Exclude build output and VCS noise so the delta is small; the box rebuilds bin/obj.
rsync -az --delete \
  --exclude '.git/' --exclude 'bin/' --exclude 'obj/' --exclude 'tmp/' --exclude 'node_modules/' \
  -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new" \
  "$WORKTREE/" "$SSH_USER@$SSH_HOST:$DEST_CYG/"

# --- 4. run the suite on the box (box-side lock serializes concurrent runs) ------
# The remote runner runs as a BACKGROUND ssh (stdio inherited, so its console output
# still streams live) with a watchdog around it. Completion is signalled by the sentinel
# the runner writes (tmp/win-test/done.json, spec §X6) — NOT by the ssh exiting: a
# box-side child that inherits the session's stdio (sqlservr.exe did exactly this) keeps
# the ssh alive long after the suite finished. The ssh exiting is the common case; the
# sentinel is what we trust.
RUN_ID="$(date +%s).$$"
REMOTE_RESULTS="$DEST/tmp/win-test"
mkdir -p ./tmp/win-test
STAMP=./tmp/win-test/.run-started   # mtime fence: TRX from THIS run are newer than it
touch "$STAMP"

# One remote call per poll (the box's default SSH shell is PowerShell, so these run as-is;
# single-quoted PS strings only — the remote shell would expand a double-quoted "$var").
# Prints "DONE <sentinel json>" once the run finished, else a progress snapshot.
STATUS_PS="\$d='$REMOTE_RESULTS'; \
if (Test-Path (\$d+'/done.json')) { 'DONE ' + (Get-Content (\$d+'/done.json') -Raw) } \
else { \$log = Get-ChildItem \$d -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1; \
\$trx = (Get-ChildItem \$d -Filter *.trx -ErrorAction SilentlyContinue | Measure-Object).Count; \
\$tail = ''; if (\$log) { \$tail = (Get-Content \$log.FullName -Tail 1 -ErrorAction SilentlyContinue) -join '' }; \
\$ls = '-'; if (\$log) { \$ls = \$log.Name + ':' + [string]\$log.Length + 'B' }; \
'RUNNING trx=' + \$trx + ' log=' + \$ls + ' | ' + \$tail }"

# Post-mortem snapshot for the timeout path: what's still running, and the log tail.
DIAG_PS="'--- test-related processes ---'; \
Get-Process -Name sqlservr,testhost*,dotnet,MSBuild,pwsh,nuget,vstest* -ErrorAction SilentlyContinue | Format-Table Id,ProcessName,StartTime -AutoSize | Out-String; \
'--- newest log tail ---'; \$log = Get-ChildItem '$REMOTE_RESULTS' -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1; \
if (\$log) { \$log.FullName; Get-Content \$log.FullName -Tail 40 -ErrorAction SilentlyContinue } else { '(no log yet)' }"

# A stale sentinel from a previous run must not read as this run finishing. (Guarded by
# Test-Path: Remove-Item on a missing file flips \$? even with SilentlyContinue, which
# would exit the remote shell — and this script — non-zero.)
"${SSH[@]}" "if (Test-Path ('$REMOTE_RESULTS'+'/done.json')) { Remove-Item ('$REMOTE_RESULTS'+'/done.json') -Force }" </dev/null \
  || die "couldn't clear the stale completion sentinel on the box"

echo "win-test: running '$SUITE' suite on $VM_NAME (run $RUN_ID; timeout ${TIMEOUT_S}s)…"
"${SSH[@]}" "pwsh -NoProfile -File $REMOTE_RUNNER -RepoDir '$DEST' -Suite '$SUITE' -RunId '$RUN_ID'" </dev/null &
SSH_PID=$!

# timeout-wrapped: the watchdog's own probes must not be hangable (a wedged-but-open
# TCP session would otherwise block a poll forever, recreating the very hang we watch for).
poll_status() { timeout 30 "${SSH[@]}" "$STATUS_PS" 2>/dev/null </dev/null || true; }
# Extracts the exit code if $1 is OUR run's sentinel line; prints nothing otherwise.
sentinel_rc() {
  case "$1" in
    "DONE "*"\"runId\":\"$RUN_ID\""*)
      printf '%s' "$1" | sed -n 's/.*"rc": *\(-\{0,1\}[0-9][0-9]*\).*/\1/p' ;;
  esac
}

START=$(date +%s)
run_rc=""; sentinel=""; timed_out=0
while :; do
  # Sleep in short slices so a finished ssh is noticed within ~2 s, not a full poll.
  slept=0
  while [ "$slept" -lt "$POLL_S" ] && kill -0 "$SSH_PID" 2>/dev/null; do sleep 2; slept=$((slept + 2)); done
  elapsed=$(( $(date +%s) - START ))

  status=$(poll_status)
  rc=$(sentinel_rc "$status")
  if [ -n "$rc" ]; then sentinel="${status#DONE }"; run_rc="$rc"; break; fi

  if ! kill -0 "$SSH_PID" 2>/dev/null; then
    # ssh is gone with no sentinel yet. Poll once more (the sentinel lands just before
    # pwsh exits — a lost race here is possible); if still nothing, the run
    # INFRASTRUCTURE failed (connection died, runner missing) — loud, non-zero.
    sleep 3
    status=$(poll_status)
    rc=$(sentinel_rc "$status")
    if [ -n "$rc" ]; then sentinel="${status#DONE }"; run_rc="$rc"; break; fi
    set +e; wait "$SSH_PID"; ssh_rc=$?; set -e
    echo "win-test: ⚠️  ssh exited (rc=$ssh_rc) but run $RUN_ID left no completion sentinel — infrastructure failure, not a suite verdict." >&2
    run_rc=$(( ssh_rc == 0 ? 1 : ssh_rc ))
    break
  fi

  if [ "$elapsed" -ge "$TIMEOUT_S" ]; then timed_out=1; break; fi
  echo "win-test: ⏱ ${elapsed}s elapsed — ${status:-status poll failed (box busy?)}"
done

if [ "$timed_out" = 1 ]; then
  # Never hang silently: abort loudly, but grab evidence + partial results first.
  run_rc=124
  echo "win-test: ⛔ run exceeded WIN_TEST_TIMEOUT=${TIMEOUT_S}s — possible hang. Collecting diagnostics…" >&2
  state=$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" \
            --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv 2>/dev/null || echo unknown)
  echo "win-test: box power state: ${state:-unknown}" >&2
  timeout 60 "${SSH[@]}" "$DIAG_PS" </dev/null >&2 || echo "win-test: (remote diagnostics unavailable)" >&2
fi

# Tear down the ssh channel. On the happy path it exits by itself right after the
# sentinel; give it a short grace, then kill — a lingering ssh after a finished run is
# exactly the hang this watchdog exists for. (Killing the ssh never kills the box-side
# runner; the box's lock/heartbeat + idle-monitor own that lifecycle.)
if kill -0 "$SSH_PID" 2>/dev/null; then
  if [ "$timed_out" != 1 ]; then
    for _ in $(seq 1 10); do kill -0 "$SSH_PID" 2>/dev/null || break; sleep 2; done
  fi
  if kill -0 "$SSH_PID" 2>/dev/null; then
    if [ "$timed_out" = 1 ]; then
      echo "win-test: aborting the ssh channel."
    else
      echo "win-test: ssh channel lingering after run end — killing it (a box-side child was holding stdio)."
      lingered=1
    fi
    kill "$SSH_PID" 2>/dev/null || true; sleep 1; kill -9 "$SSH_PID" 2>/dev/null || true
  fi
fi
set +e; wait "$SSH_PID" 2>/dev/null; set -e

# Surface a runner-side error (lock timeout, build failure throw) recorded in the sentinel.
if [ -n "$sentinel" ]; then
  err=$(printf '%s' "$sentinel" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p')
  [ -n "$err" ] && echo "win-test: runner reported: $err" >&2
fi

# --- 5. fetch results (loud — a swallowed fetch error reads as a clean run) ------
echo "win-test: fetching results → ./tmp/win-test/"
fetch_ok=1
rsync -az -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new" \
  "$SSH_USER@$SSH_HOST:$DEST_CYG/tmp/win-test/" "./tmp/win-test/" || {
  fetch_ok=0
  echo "win-test: ⚠️  fetching results FAILED — they remain on the box at $DEST/tmp/win-test" >&2
}

# If the channel had to be killed, the runner's last console lines (the per-project
# summaries) never streamed — replay them from the fetched logs so the operator still
# sees them.
if [ "${lingered:-0}" = 1 ] && [ "$fetch_ok" = 1 ]; then
  echo "win-test: final runner output didn't stream; summaries from the fetched logs:"
  find ./tmp/win-test -name '*.Tests.*.log' -newer "$STAMP" \
    -exec sh -c 'tail -2 "$1" | sed "s|^|win-test:   |"' _ {} \; 2>/dev/null || true
fi

# Green needs evidence: a pass without a TRX from this run (fetch failed, or nothing new
# arrived) is not a pass (spec §X5).
if [ "$run_rc" = 0 ]; then
  fresh_trx=$(find ./tmp/win-test -name '*.trx' -newer "$STAMP" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$fetch_ok" != 1 ] || [ "$fresh_trx" = 0 ]; then
    echo "win-test: ❌ suite reported pass but no TRX from this run was fetched — refusing to report green without evidence." >&2
    run_rc=1
  fi
fi

echo
if [ "$timed_out" = 1 ]; then
  echo "win-test: ⛔ suite '$SUITE' TIMED OUT on $VM_NAME (branch $BRANCH) after ${TIMEOUT_S}s — possible hang; not a suite verdict. Partial results (if any) in ./tmp/win-test/." >&2
elif [ "$run_rc" = 0 ]; then
  echo "win-test: ✅ suite '$SUITE' passed on $VM_NAME (branch $BRANCH). Results in ./tmp/win-test/."
else
  echo "win-test: ❌ suite '$SUITE' FAILED on $VM_NAME (branch $BRANCH), exit $run_rc. See ./tmp/win-test/."
fi
echo "win-test: box left running; it self-deallocates after ${IDLE_MINUTES:-20} min idle."
exit "$run_rc"
