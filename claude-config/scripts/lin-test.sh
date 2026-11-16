#!/usr/bin/env bash
# lin-test.sh — run a worktree's full check on the ephemeral Linux test appliance, from
# the Linux devbox.
#
# Several sessions share the devbox, and a project's full check (build, lint, the whole
# test suite, a database in Docker) fails on timeouts when two run there at once. This
# script sends the check somewhere else: it wakes the `lin-test` appliance, syncs the
# current worktree to it, runs one command there under the box's run lock, streams the
# output back, and exits with the command's exit code. See docs/lin-test.overview.md
# (why) and docs/lin-test.spec.md (the contract).
#
# What it does NOT do: stop the box. The box owns its own lifecycle — its idle monitor
# deallocates it once no run is active and it has been idle IDLE_MINUTES. This script
# only ever starts it, so one session can never stop the box under another; runs that
# overlap queue on the box.
#
# Usage:
#   lin-test.sh [<worktree>] [--clean] [--cmd '<shell command>'] [-- <command ...>]
#     <worktree>   the checkout to test (default: the current git worktree's root)
#     --cmd        the command to run in the synced worktree, as one shell string
#     -- ...       the same, as the rest of the command line (joined with spaces)
#     --clean      wipe this branch's folder on the box first (cold install and build)
#     --resolve-only   print what would run and where, and exit — contacts nothing
#
# With no command, the project says what its check is:
#   1. LIN_TEST_CMD=<command> in the worktree's committed scripts/lin-test.env; else
#   2. a package.json that pins pnpm and has a "check" script:
#        corepack pnpm install --frozen-lockfile && corepack pnpm check
#   3. otherwise the run is refused and asks for a command. It never guesses.
#
# What is synced: the files git knows about in the worktree — tracked, plus untracked
# ones that are not ignored — including uncommitted edits. Ignored files (node_modules,
# build output, tmp, .env) never leave the devbox. The branch's folder on the box is
# kept between runs, so installs and builds are warm.
#
# Env tunables (a repo may also set the first one in scripts/lin-test.env):
#   LIN_TEST_TIMEOUT       limit for the command, seconds (default 2400). Enforced on the
#                          box; a command past it is stopped and the run exits 124.
#   LIN_TEST_LOCK_TIMEOUT  longest wait for the box's run lock, seconds (default 3600)
#   LIN_TEST_POLL          seconds between status polls (default 10)
#   LIN_TEST_RUNNER_ENV    alternate runner.env path
#
# Reads box identity from ~/.config/devbox/lin-test/runner.env, which `devbox -p lin-test
# up` writes. If that file is absent, the appliance hasn't been stood up yet.
#
# Output: the command's output, live; then the run's log and verdict in
# <worktree>/tmp/lin-test/<run id>/ (and tmp/lin-test/latest). The exit code is the
# command's. 124 = timed out, 75 = never got to run (lock or sync), 130 = abandoned.
# Fails loud; never reports a result without a verdict fetched from the box.
set -euo pipefail

RUNNER_ENV="${LIN_TEST_RUNNER_ENV:-$HOME/.config/devbox/lin-test/runner.env}"
POLL_S="${LIN_TEST_POLL:-10}"
LOCK_TIMEOUT_S="${LIN_TEST_LOCK_TIMEOUT:-3600}"
SYNC_TIMEOUT_S=900
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
BOX_RUNNER="$HERE/lin-test-run.sh"

die() { echo "lin-test: $*" >&2; exit 1; }

# --- args -----------------------------------------------------------------------
WORKTREE=""; CLEAN=0; CMD=""; RESOLVE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --cmd) CMD="${2:?--cmd needs a value}"; shift 2 ;;
    --resolve-only) RESOLVE_ONLY=1; shift ;;
    --) shift; [ -z "$CMD" ] || die "give the command once: either --cmd or after --"; CMD="$*"; break ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  [ -z "$WORKTREE" ] || die "unexpected argument '$1' (put the command after -- or in --cmd)"; WORKTREE="$1"; shift ;;
  esac
done

for bin in git jq; do command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"; done

if [ -z "$WORKTREE" ]; then
  WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git worktree; pass <worktree>"
fi
[ -d "$WORKTREE" ] || die "no such worktree: $WORKTREE"
WORKTREE=$(cd "$WORKTREE" && git rev-parse --show-toplevel 2>/dev/null) || die "not a git worktree: $WORKTREE"

# Names become path segments on the box, so they are reduced to a strict character set
# here and checked again there.
# A name that had to be changed gets a short hash of the original appended, so two
# different branches ("feat/x" and "feat-x") never share a folder.
safe_name() {
  local s; s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.-]*//')
  if [ "$s" != "$1" ]; then s="${s:-x}-$(printf '%s' "$1" | sha256sum | cut -c1-8)"; fi
  printf '%s' "$s"
}
# A checkout with no branch is named for its commit.
detached_name() { printf 'detached-%s' "$(git -C "$1" rev-parse --short HEAD 2>/dev/null)"; }
# symbolic-ref, not rev-parse: it also names the branch of a checkout with no commit yet.
BRANCH=$(git -C "$WORKTREE" symbolic-ref --short -q HEAD) || BRANCH=$(detached_name "$WORKTREE")
[ "$BRANCH" != detached- ] || die "can't read the branch or commit of $WORKTREE"
SAFE_BRANCH=$(safe_name "$BRANCH")
# The repository's name is its main checkout's folder, the same for every linked worktree.
# A short hash of where that checkout lives is appended, so two different repositories
# that happen to share a folder name do not share (and prune) each other's folders.
COMMON=$(cd "$WORKTREE" && cd "$(git rev-parse --git-common-dir)" && pwd)
REPO=$(printf '%s' "$(basename "$(dirname "$COMMON")")" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.-]*//')
REPO="${REPO:-repo}-$(printf '%s' "$COMMON" | sha256sum | cut -c1-8)"
[ -n "$SAFE_BRANCH" ] && [ -n "$REPO" ] || die "couldn't derive a usable repo/branch name from $WORKTREE"

# --- what to run ----------------------------------------------------------------
# A repo's scripts/lin-test.env is read as data (never sourced): only the keys below are
# taken, each as the text after the first '='. It is for what a repo COMMITS — a secret
# has no business in it, and nothing here forwards one.
repo_setting() {
  local f="$WORKTREE/scripts/lin-test.env" v
  [ -f "$f" ] || return 0
  v=$(sed -n "s/^[[:space:]]*$1=//p" "$f" | head -n 1)
  v="${v%$'\r'}"
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
  printf '%s' "$v"
}
CMD_SOURCE="given on the command line"
if [ -z "$CMD" ]; then
  CMD=$(repo_setting LIN_TEST_CMD); CMD_SOURCE="scripts/lin-test.env"
fi
if [ -z "$CMD" ] && [ -f "$WORKTREE/package.json" ] \
   && jq -e '(.packageManager // "" | startswith("pnpm@")) and (.scripts.check // "" | length > 0)' \
        "$WORKTREE/package.json" >/dev/null 2>&1; then
  CMD="corepack pnpm install --frozen-lockfile && corepack pnpm check"
  CMD_SOURCE="package.json (pnpm, has a check script)"
fi
[ -n "$CMD" ] || die "this project doesn't say what its check is. Give a command (-- <command>), or commit one as LIN_TEST_CMD=<command> in scripts/lin-test.env."

RUN_TIMEOUT_S="${LIN_TEST_TIMEOUT:-$(repo_setting LIN_TEST_TIMEOUT)}"
RUN_TIMEOUT_S="${RUN_TIMEOUT_S:-2400}"
for n in "$RUN_TIMEOUT_S" "$LOCK_TIMEOUT_S" "$POLL_S"; do
  [[ $n =~ ^[1-9][0-9]*$ ]] || die "timeouts and the poll interval must be positive whole numbers of seconds, got '$n'"
done

if [ "$RESOLVE_ONLY" = 1 ]; then
  printf 'worktree: %s\nrepo:     %s\nbranch:   %s\ncommand:  %s\nsource:   %s\ntimeout:  %ss\n' \
    "$WORKTREE" "$REPO" "$SAFE_BRANCH" "$CMD" "$CMD_SOURCE" "$RUN_TIMEOUT_S"
  exit 0
fi

# --- deps + box identity --------------------------------------------------------
for bin in az ssh rsync timeout; do command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"; done
[ -r "$BOX_RUNNER" ] || die "can't find the box-side runner at $BOX_RUNNER"
[ -r "$RUNNER_ENV" ] || die "no appliance config at $RUNNER_ENV — run 'devbox -p lin-test up' first"
# The file names the host this script connects to with the machine key, so it may only
# be one that `devbox up` wrote: somewhere under the operator's devbox state, never a
# file a caller made up to point the key at a destination of its choosing.
case "$(readlink -f "$RUNNER_ENV")" in
  "$HOME/.config/devbox/"*/runner.env) ;;
  *) die "LIN_TEST_RUNNER_ENV must be a runner.env under $HOME/.config/devbox/ (got $RUNNER_ENV)" ;;
esac
# shellcheck disable=SC1090
. "$RUNNER_ENV"
: "${RESOURCE_GROUP:?runner.env missing RESOURCE_GROUP}"
: "${VM_NAME:?runner.env missing VM_NAME}"
: "${SSH_HOST:?runner.env missing SSH_HOST}"
: "${CI_DIR:?runner.env missing CI_DIR}"
: "${SSH_PORT:=2222}"; : "${SSH_USER:=eddyg}"
# These become an ssh command line, so each is held to the shape it must have.
[[ $SSH_PORT =~ ^[0-9]{1,5}$ ]]        || die "SSH_PORT in runner.env is not a port number"
[[ $SSH_HOST =~ ^[A-Za-z0-9.:-]+$ ]] && [[ $SSH_HOST != -* ]] || die "SSH_HOST in runner.env is not a host name or address"
[[ $SSH_USER =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] || die "SSH_USER in runner.env is not a user name"
case "$CI_DIR" in /*) ;; *) die "CI_DIR in runner.env must be an absolute path, got '$CI_DIR'" ;; esac
case "$CI_DIR" in *[!a-zA-Z0-9/._-]*|*..*) die "CI_DIR in runner.env has characters outside [a-zA-Z0-9/._-]" ;; esac
AZ_SUB=(); [ -n "${SUBSCRIPTION_ID:-}" ] && AZ_SUB=(--subscription "$SUBSCRIPTION_ID")

# -a: this box never sees a forwarded agent. BatchMode: an unattended run must fail, not
# prompt. The keepalives turn a silently dead connection into an error within a minute.
SSH_OPTS=(-p "$SSH_PORT" -a -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
          -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
SSH=(ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST")
RSYNC_RSH="ssh ${SSH_OPTS[*]}"
REMOTE="$SSH_USER@$SSH_HOST"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
STATE_DIR="$CI_DIR/.lin-test"
RUNDIR="$STATE_DIR/runs/$RUN_ID"
DEST="$CI_DIR/$REPO/$SAFE_BRANCH"
RESULTS_DIR="$WORKTREE/tmp/lin-test/$RUN_ID"
mkdir -p "$RESULTS_DIR"
STAGE=$(mktemp -d "$WORKTREE/tmp/lin-test/.stage.XXXXXX")
TAIL_PID=""; RUNNER_STARTED=0; VERDICT=0
cleanup() {
  [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
  rm -rf "$STAGE"
  # Leaving without a verdict (interrupted, or failed partway) tells the box-side run to
  # stop rather than hold the box's lock for a caller that is gone.
  if [ "$RUNNER_STARTED" = 1 ] && [ "$VERDICT" = 0 ]; then
    timeout 20 "${SSH[@]}" "touch '$RUNDIR/abort'" </dev/null >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'echo "lin-test: interrupted" >&2; exit 130' INT TERM HUP

# --- 1. wake the box (idempotent; no-op if already running) ---------------------
power_state() {
  az vm get-instance-view "${AZ_SUB[@]}" -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv 2>/dev/null || true
}
T0=$(date +%s)
state=$(power_state)
# Caught mid-way through turning itself off: a start issued now can be lost, so let the
# deallocation finish first.
for _ in $(seq 1 36); do
  [ "$state" = "PowerState/deallocating" ] || [ "$state" = "PowerState/stopping" ] || break
  echo "lin-test: $VM_NAME is ${state#PowerState/}; waiting for it to finish before starting it…"
  sleep 5; state=$(power_state)
done
COLD=0
if [ "$state" != "PowerState/running" ]; then
  COLD=1
  echo "lin-test: starting $VM_NAME (was: ${state:-unknown})…"
  az vm start "${AZ_SUB[@]}" -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null || die "az vm start failed"
fi

# --- 2. wait for SSH; the first contact marks the box busy ----------------------
echo "lin-test: waiting for ssh $REMOTE:$SSH_PORT…"
ready=0
for i in $(seq 1 60); do
  if "${SSH[@]}" "mkdir -p '$STATE_DIR/runs' && touch '$STATE_DIR/last-activity'" </dev/null >/dev/null 2>&1; then ready=1; break; fi
  # A box that was "running" a moment ago may have been on its way off: its idle monitor
  # can deallocate it between the check above and this connection. Start it again
  # rather than wait out a box that is no longer there.
  if [ $(( i % 6 )) = 0 ]; then
    state=$(power_state)
    if [ "$state" = "PowerState/deallocated" ] || [ "$state" = "PowerState/stopped" ]; then
      echo "lin-test: $VM_NAME turned itself off meanwhile; starting it again…"
      az vm start "${AZ_SUB[@]}" -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null || die "az vm start failed"
      COLD=1
    fi
  fi
  sleep 5
done
[ "$ready" = 1 ] || die "ssh never came up (box started but unreachable)"
[ "$COLD" = 1 ] && echo "lin-test: box up $(( $(date +%s) - T0 ))s after the start request"

# --- 3. hand over the run: its parameters, the command, and this version's runner --
{
  printf 'REPO=%s\nBRANCH=%s\nCLEAN=%s\n' "$REPO" "$SAFE_BRANCH" "$CLEAN"
  printf 'RUN_TIMEOUT=%s\nLOCK_TIMEOUT=%s\nSYNC_TIMEOUT=%s\n' "$RUN_TIMEOUT_S" "$LOCK_TIMEOUT_S" "$SYNC_TIMEOUT_S"
  printf 'RETAIN_DAYS=%s\nMIN_FREE_GB=%s\n' "${CI_RETAIN_DAYS:-14}" "${CI_MIN_FREE_GB:-20}"
} > "$STAGE/params"
printf '%s\n' "$CMD" > "$STAGE/command"
# Every branch the repo still has, in the same sanitized form as the folders on the box,
# so the box can drop the folders of branches that are gone.
git -C "$WORKTREE" for-each-ref --format='%(refname:short)' refs/heads \
  | while IFS= read -r b; do safe_name "$b"; echo; done > "$STAGE/branches"
# …and every worktree checked out at a bare commit, under the name its runs use.
git -C "$WORKTREE" worktree list --porcelain \
  | awk '/^worktree /{w=substr($0,10)} /^detached$/{print w}' \
  | while IFS= read -r w; do safe_name "$(detached_name "$w")"; echo; done >> "$STAGE/branches"
echo "$SAFE_BRANCH" >> "$STAGE/branches"
rsync -a -e "$RSYNC_RSH" "$STAGE/" "$REMOTE:$RUNDIR/" || die "couldn't hand the run over to the box"
rsync -a -e "$RSYNC_RSH" "$BOX_RUNNER" "$REMOTE:$STATE_DIR/lin-test-run.sh" || die "couldn't copy the runner to the box"

# Detached on the box (its own session, stdio to a file): the run belongs to the box from
# here, and outlives this connection if it drops.
# Marked as started BEFORE the call: if the connection drops just after the box has
# started the runner, leaving must still tell it to stop. (Telling a run that never
# started to stop is harmless.)
RUNNER_STARTED=1
"${SSH[@]}" "setsid nohup bash '$STATE_DIR/lin-test-run.sh' '$CI_DIR' '$RUN_ID' >'$RUNDIR/runner.out' 2>&1 </dev/null &" </dev/null \
  || die "couldn't start the runner on the box"
echo "lin-test: run $RUN_ID — $REPO/$SAFE_BRANCH on $VM_NAME"
echo "lin-test: command ($CMD_SOURCE): $CMD"

# One remote call per poll. The reply is three parts: the word "alive" (so an answer from
# a box with nothing to report yet is told apart from no answer at all), the state word,
# then the verdict once there is one.
poll() { timeout 30 "${SSH[@]}" "echo alive; cat '$RUNDIR/state' 2>/dev/null; echo; cat '$RUNDIR/done.json' 2>/dev/null" </dev/null 2>/dev/null || true; }
state_of() { printf '%s\n' "$1" | sed -n '2p'; }
# Always succeeds: a reply cut short mid-transfer is not JSON yet, and that must read as
# "no verdict so far", not end this script (and with it abandon a healthy run).
verdict_of() { printf '%s\n' "$1" | sed -n '3,$p' | jq -c --arg id "$RUN_ID" 'select(.runId == $id)' 2>/dev/null | head -n 1 || true; }
# Lost contact is measured on the clock, not in polls: a poll against a box that is gone
# takes as long as its connection timeout. Two minutes of silence ends the run.
LAST_HEARD=$(date +%s)
heard() { # $1 = a poll's reply
  if [ "$(printf '%s\n' "$1" | head -n 1)" = alive ]; then LAST_HEARD=$(date +%s); return 0; fi
  local quiet=$(( $(date +%s) - LAST_HEARD ))
  [ "$quiet" -lt 120 ] || die "lost contact with the box for ${quiet}s (power state: $(power_state)) — no verdict"
}

# --- 4. wait for the box's run lock (other runs go first) -----------------------
verdict=""; announced=0; QSTART=$(date +%s); next_note=60
while :; do
  out=$(poll); heard "$out"; st=$(state_of "$out")
  verdict=$(verdict_of "$out")
  [ -n "$verdict" ] && break
  [ "$st" = locked ] && break
  waited=$(( $(date +%s) - QSTART ))
  if [ "$st" = queued ] && [ "$announced" = 0 ] && [ "$waited" -ge 4 ]; then
    echo "lin-test: another run has the box; queued (waits up to ${LOCK_TIMEOUT_S}s)…"; announced=1
  fi
  # The box gives up on the lock by itself and says so; this is only the backstop behind it.
  if [ "$waited" -ge $(( LOCK_TIMEOUT_S + 120 )) ]; then
    echo "lin-test: the box never granted the run lock or reported why (waited ${waited}s)" >&2
    exit 75
  fi
  if [ "$announced" = 1 ] && [ "$waited" -ge "$next_note" ]; then
    echo "lin-test: ⏱ still queued after ${waited}s"; next_note=$(( next_note + 60 ))
  fi
  sleep 2
done

# --- 5. sync the worktree (under the lock, so no other run sees it half-written) --
if [ -z "$verdict" ]; then
  echo "lin-test: syncing $WORKTREE → $DEST"
  # git decides what a project's files are; rsync's own reading of .gitignore gets
  # negations ("!.env.example") wrong, and a check may need exactly those files.
  # --deleted are dropped: tracked files removed from the working tree but not yet staged.
  # This script's own results folder is left out too, for a project that does not ignore
  # tmp/: earlier runs' logs are not part of the project.
  ( cd "$WORKTREE" \
      && LC_ALL=C comm -z -23 \
           <(git ls-files -z --cached --others --exclude-standard | LC_ALL=C sort -zu) \
           <(git ls-files -z --deleted | LC_ALL=C sort -zu) \
         | { grep -z -v '^tmp/lin-test/' || true; } ) > "$STAGE/manifest" \
    || die "couldn't list the worktree's files"
  [ -s "$STAGE/manifest" ] || die "the worktree has no files git knows about — nothing to sync"
  # -a keeps a symlink a symlink: a link that points at a secret outside the worktree
  # travels as a dangling link, never as the secret's content.
  # The file list goes first: if this sync is cut short, the box still knows which files
  # it may have received, and a later run removes any the worktree no longer has.
  rsync -a -e "$RSYNC_RSH" "$STAGE/manifest" "$REMOTE:$RUNDIR/manifest" || die "couldn't send the file list to the box"
  # --checksum: content decides what is sent. rsync's usual size-and-time shortcut would
  # skip an edit that kept a file's size within the same second, and the box would test
  # the old content. Time-limited to end before the box stops waiting for the sync, so
  # this never writes into the folder after the box has given the lock to another run.
  timeout $(( SYNC_TIMEOUT_S - 120 )) \
    rsync -a --checksum --from0 --files-from="$STAGE/manifest" -e "$RSYNC_RSH" "$WORKTREE/" "$REMOTE:$DEST/" \
    || die "syncing the worktree to the box failed or took longer than $(( SYNC_TIMEOUT_S - 120 ))s"
  # Only a run still holding the lock may be told to go on.
  st=$(state_of "$(poll)")
  [ "$st" = locked ] || die "the box stopped waiting for this run during the sync (state: ${st:-unknown})"
  "${SSH[@]}" "touch '$RUNDIR/synced'" </dev/null || die "couldn't tell the box the sync is done"

  # --- 6. stream the output and wait for the verdict ----------------------------
  # The stream is a convenience and may drop; the verdict file is what ends the run.
  # It is the output of whatever the project runs, shown on this terminal: colour codes
  # are removed and every other control character dropped, so nothing in it can drive
  # the terminal.
  "${SSH[@]}" "tail -n +1 -F '$RUNDIR/run.log' 2>/dev/null" </dev/null \
    > >(sed -u 's/\x1b\[[0-9;?]*[A-Za-z]//g' | stdbuf -oL tr -d '\000-\010\013-\037\177') &
  TAIL_PID=$!
  START=$(date +%s); LAST_HEARD=$START
  while :; do
    sleep "$POLL_S"
    out=$(poll); verdict=$(verdict_of "$out")
    [ -n "$verdict" ] && break
    heard "$out"
    # The box enforces the command's limit itself; this is only the backstop behind it.
    if [ $(( $(date +%s) - START )) -ge $(( RUN_TIMEOUT_S + 180 )) ]; then
      echo "lin-test: ⛔ no verdict ${RUN_TIMEOUT_S}s+180s after the sync — the box-side runner is not answering. Diagnostics:" >&2
      echo "lin-test: box power state: $(power_state)" >&2
      timeout 30 "${SSH[@]}" "cat '$RUNDIR/runner.out' 2>/dev/null | tail -n 20; tail -n 20 '$RUNDIR/run.log' 2>/dev/null" </dev/null >&2 || true
      exit 124
    fi
  done
  sleep 1   # let the stream deliver the last lines
  kill "$TAIL_PID" 2>/dev/null || true; wait "$TAIL_PID" 2>/dev/null || true; TAIL_PID=""
fi
VERDICT=1

# --- 7. fetch the evidence (loud — a result needs its log) ----------------------
echo "lin-test: fetching the run's log and verdict → $RESULTS_DIR/"
fetch_ok=1
# -rt, not -a: three named regular files and nothing else. What comes back from the box is
# data to read, so no links, devices, owners or modes are taken from it.
rsync -rt -e "$RSYNC_RSH" --include='run.log' --include='done.json' --include='runner.out' --exclude='*' \
  "$REMOTE:$RUNDIR/" "$RESULTS_DIR/" || fetch_ok=0
ln -sfn "$RUN_ID" "$WORKTREE/tmp/lin-test/latest"

rc=$(printf '%s' "$verdict" | jq -r '.rc')
# One line each, control characters dropped: these are echoed to a terminal.
err=$(printf '%s' "$verdict" | jq -r '.error // ""' | tr -d '\000-\037\177')
summary=$(printf '%s' "$verdict" | jq -r '.summary // ""' | tr -d '\000-\037\177')
secs=$(printf '%s' "$verdict" | jq -r '.seconds')
# An exit code is 0 to 255. Anything else is not a verdict — and a number like 256 would
# leave this script as 0.
[[ $rc =~ ^[0-9]{1,3}$ ]] && [ "$rc" -le 255 ] || die "the box's verdict has no usable exit code"
[[ $secs =~ ^[0-9]+$ ]] || secs="?"
if [ "$fetch_ok" != 1 ] || [ ! -s "$RESULTS_DIR/done.json" ]; then
  echo "lin-test: ⚠️  fetching the results FAILED — they remain on the box at $RUNDIR" >&2
  if [ "$rc" = 0 ]; then
    echo "lin-test: ❌ the run reported success but its log could not be fetched — refusing to report green without evidence." >&2
    rc=1
  fi
fi

echo
[ -n "$summary" ] && echo "lin-test: $summary"
[ -n "$err" ] && echo "lin-test: runner reported: $err" >&2
if [ "$rc" = 0 ]; then
  echo "lin-test: ✅ passed on $VM_NAME ($REPO/$SAFE_BRANCH) in ${secs}s. Log: $RESULTS_DIR/run.log"
elif [ "$rc" = 124 ]; then
  echo "lin-test: ⛔ TIMED OUT on $VM_NAME ($REPO/$SAFE_BRANCH) — possible hang; not a verdict on the code. Log: $RESULTS_DIR/run.log" >&2
elif [ -n "$err" ]; then
  echo "lin-test: ❌ the run did not reach a verdict on $VM_NAME ($REPO/$SAFE_BRANCH), exit $rc. Log: $RESULTS_DIR/run.log" >&2
else
  echo "lin-test: ❌ FAILED on $VM_NAME ($REPO/$SAFE_BRANCH), exit $rc, after ${secs}s. Log: $RESULTS_DIR/run.log"
fi
echo "lin-test: box left running; it deallocates itself after ${IDLE_MINUTES:-10} min idle."
exit "$rc"
