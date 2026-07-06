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
# Reads box identity from ~/.config/devbox/win-test/runner.env, which `devbox -p win-test
# up` writes. If that file is absent, the appliance hasn't been stood up yet.
#
# Output: a human summary + the TRX/console log fetched into ./tmp/win-test/. Exit code
# mirrors the suite (0 = all passed). Fails loud; never reports green without a real run.
set -euo pipefail

RUNNER_ENV="${WIN_TEST_RUNNER_ENV:-$HOME/.config/devbox/win-test/runner.env}"
REMOTE_RUNNER='~/.claude/scripts/win-test-run.ps1'   # installed on the box by install.ps1

die() { echo "win-test: $*" >&2; exit 1; }

# --- deps -----------------------------------------------------------------------
for bin in az ssh rsync git; do
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
    -h|--help) sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
if [ "$CLEAN" = 1 ]; then
  echo "win-test: --clean → wiping $DEST on the box"
  "${SSH[@]}" "pwsh -NoProfile -Command \"Remove-Item -Recurse -Force '$DEST' -ErrorAction SilentlyContinue\""
fi
echo "win-test: syncing $WORKTREE → $DEST"
# Exclude build output and VCS noise so the delta is small; the box rebuilds bin/obj.
rsync -az --delete \
  --exclude '.git/' --exclude 'bin/' --exclude 'obj/' --exclude 'tmp/' --exclude 'node_modules/' \
  -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new" \
  "$WORKTREE/" "$SSH_USER@$SSH_HOST:$DEST/"

# --- 4. run the suite on the box (box-side lock serializes concurrent runs) ------
echo "win-test: running '$SUITE' suite on $VM_NAME…"
set +e
"${SSH[@]}" "pwsh -NoProfile -File $REMOTE_RUNNER -RepoDir '$DEST' -Suite '$SUITE'"
run_rc=$?
set -e

# --- 5. fetch results -----------------------------------------------------------
mkdir -p ./tmp/win-test
echo "win-test: fetching results → ./tmp/win-test/"
rsync -az -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new" \
  "$SSH_USER@$SSH_HOST:$DEST/tmp/win-test/" "./tmp/win-test/" 2>/dev/null || true

echo
if [ "$run_rc" = 0 ]; then
  echo "win-test: ✅ suite '$SUITE' passed on $VM_NAME (branch $BRANCH). Results in ./tmp/win-test/."
else
  echo "win-test: ❌ suite '$SUITE' FAILED on $VM_NAME (branch $BRANCH), exit $run_rc. See ./tmp/win-test/."
fi
echo "win-test: box left running; it self-deallocates after ${IDLE_MINUTES:-20} min idle."
exit "$run_rc"
