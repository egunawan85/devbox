#!/usr/bin/env bash
# Regression suite for the lin-test appliance's scripts, run entirely on this machine:
#   claude-config/scripts/lin-test-run.sh   the box-side runner (lock, sync hand-off,
#                                           deletions, stand-in git repo, limits, verdict,
#                                           pruning)
#   claude-config/scripts/lin-test.sh       only its --resolve-only path (what would run)
#   deploy/azure/idle-monitor.sh            the stay-up / deallocate decision, dry-run
#
# The runner is plain bash over a directory, so a scratch directory stands in for the
# box: each case plays the orchestrator's part by hand (write the run's parameters,
# wait for `locked`, put files in place, signal `synced`) and reads the verdict.
# No network, no ssh, no Azure. Scratch lives under ./tmp/ and is removed on success.
#
# Run: tests/lin-test.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT/claude-config/scripts/lin-test-run.sh"
ORCH="$ROOT/claude-config/scripts/lin-test.sh"
MONITOR="$ROOT/deploy/azure/idle-monitor.sh"
mkdir -p "$ROOT/tmp"
SCRATCH=$(mktemp -d "$ROOT/tmp/lin-test-tests.XXXXXX")
CI="$SCRATCH/ci"; mkdir -p "$CI/.lin-test/runs"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# new_run ID REPO BRANCH COMMAND [extra params...] — prepare a run directory.
new_run() {
  local id=$1 repo=$2 branch=$3 cmd=$4; shift 4
  local d="$CI/.lin-test/runs/$id"; mkdir -p "$d"
  { printf 'REPO=%s\nBRANCH=%s\nCLEAN=0\nRUN_TIMEOUT=60\nLOCK_TIMEOUT=60\nSYNC_TIMEOUT=30\nRETAIN_DAYS=14\nMIN_FREE_GB=0\n' "$repo" "$branch"
    for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$d/params.all"
  # Later KEY= lines override earlier ones: the runner reads the first match, so reverse.
  tac "$d/params.all" | awk -F= '!seen[$1]++' > "$d/params"; rm -f "$d/params.all"
  printf '%s\n' "$cmd" > "$d/command"
  printf '%s\n' "$branch" > "$d/branches"
}
wait_state() { # ID WANT [seconds]
  local i=0 max=$(( ${3:-20} * 10 ))
  while [ "$i" -lt "$max" ]; do
    [ "$(cat "$CI/.lin-test/runs/$1/state" 2>/dev/null)" = "$2" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
# sync_files ID REPO BRANCH file... — play the orchestrator's sync: create the files,
# write the manifest, signal.
sync_files() {
  local id=$1 dest="$CI/$2/$3"; shift 3
  local f; : > "$CI/.lin-test/runs/$id/manifest"
  for f in "$@"; do
    mkdir -p "$dest/$(dirname "$f")"; echo "content of $f" > "$dest/$f"
    printf '%s\0' "$f" >> "$CI/.lin-test/runs/$id/manifest"
  done
  touch "$CI/.lin-test/runs/$id/synced"
}
# run_to_end ID REPO BRANCH file... — start the runner, sync once locked, wait for the verdict.
run_to_end() {
  local id=$1
  bash "$RUNNER" "$CI" "$id" >/dev/null 2>&1 &
  wait_state "$id" locked 20 || { bad "run $id reached 'locked'"; return 1; }
  sync_files "$@"
  wait_state "$id" done 60 || { bad "run $id reached 'done'"; return 1; }
  wait
}
rc_of()      { jq -r .rc      "$CI/.lin-test/runs/$1/done.json" 2>/dev/null; }
err_of()     { jq -r .error   "$CI/.lin-test/runs/$1/done.json" 2>/dev/null; }
summary_of() { jq -r .summary "$CI/.lin-test/runs/$1/done.json" 2>/dev/null; }

echo "box-side runner"

new_run r-pass proj main 'echo hello from the check'
run_to_end r-pass proj main a.txt
check "a passing command gives rc 0"                 '[ "$(rc_of r-pass)" = 0 ]' "rc=$(rc_of r-pass)"
check "its output is in the run log"                 'grep -q "hello from the check" "$CI/.lin-test/runs/r-pass/run.log"'
check "no recognizable counts reads as counts=none"  '[[ "$(summary_of r-pass)" == *"rc=0"*"counts=none" ]]' "$(summary_of r-pass)"
check "the command runs in the branch folder"        '[ -f "$CI/proj/main/a.txt" ]'

new_run r-fail proj main 'echo about to fail; exit 3'
run_to_end r-fail proj main a.txt
check "a failing command's exit code is the verdict" '[ "$(rc_of r-fail)" = 3 ] && [ -z "$(err_of r-fail)" ]' "rc=$(rc_of r-fail) err=$(err_of r-fail)"

new_run r-counts proj main 'printf "      Tests  1200 passed | 3 skipped (1203)\n \033[2m     Tests \033[22m 2 failed | 110 passed | 1 todo (113)\n"; exit 1'
run_to_end r-counts proj main a.txt
check "vitest summary lines are summed across runs"  '[[ "$(summary_of r-counts)" == *"counts=vitest runs=2 passed=1310 failed=2 skipped=4" ]]' "$(summary_of r-counts)"

new_run r-timeout proj main 'sleep 300' RUN_TIMEOUT=2
run_to_end r-timeout proj main a.txt
check "a command past its limit is stopped with rc 124" '[ "$(rc_of r-timeout)" = 124 ] && [[ "$(err_of r-timeout)" == *"timed out"* ]]' "rc=$(rc_of r-timeout) err=$(err_of r-timeout)"
check "nothing of it is left running"                '! pgrep -f "sleep 300" >/dev/null'

new_run r-abort proj main 'sleep 300'
bash "$RUNNER" "$CI" r-abort >/dev/null 2>&1 &
wait_state r-abort locked; sync_files r-abort proj main a.txt; wait_state r-abort running
touch "$CI/.lin-test/runs/r-abort/abort"; wait_state r-abort done 30; wait
check "an abandoned run stops with rc 130"           '[ "$(rc_of r-abort)" = 130 ]' "rc=$(rc_of r-abort)"

new_run r-nosync proj main 'echo never' SYNC_TIMEOUT=2
bash "$RUNNER" "$CI" r-nosync >/dev/null 2>&1 & wait_state r-nosync done 30; wait
check "a sync that never arrives is rc 75, not a pass" '[ "$(rc_of r-nosync)" = 75 ] && ! grep -q "^never" "$CI/.lin-test/runs/r-nosync/run.log"' "rc=$(rc_of r-nosync)"

# The command leaves a process behind; the box's lock must not stay held by it.
new_run r-leak proj main 'setsid sleep 20 >/dev/null 2>&1 & echo left one behind'
run_to_end r-leak proj main a.txt
check "a process the command leaves behind does not hold the lock" 'flock -n "$CI/.lin-test/run.lock" true'
pkill -f "sleep 20" 2>/dev/null

# The same, but left in the command's own process group: it is stopped before the lock is
# given up, so the next run cannot meet it on a port.
new_run r-stray proj main 'sleep 471 & echo left one in the group'
run_to_end r-stray proj main a.txt
check "a process left in the command's group is stopped" '[ "$(rc_of r-stray)" = 0 ] && ! pgrep -f "sleep 471" >/dev/null'

# The runner killed outright: no trap runs. Its heartbeat must stop and its command too.
new_run r-kill9 proj main 'sleep 472'
bash "$RUNNER" "$CI" r-kill9 >/dev/null 2>&1 &
kpid=$!
wait_state r-kill9 locked; sync_files r-kill9 proj main a.txt; wait_state r-kill9 running
sleep 1; kill -9 "$kpid"; wait "$kpid" 2>/dev/null
# (Within seconds, not at once: a `sleep` the runner was waiting on holds the descriptor
# until it returns.)
check "a killed runner frees the lock within seconds"  'flock -w 5 "$CI/.lin-test/run.lock" true'
for _ in $(seq 1 200); do pgrep -f "sleep 472" >/dev/null || break; sleep 0.1; done
check "its command is stopped, not left running without the lock" '! pgrep -f "sleep 472" >/dev/null'
sleep 6; touch -d '1 hour ago' "$CI/.lin-test/last-activity"; sleep 7
check "its heartbeat stops, so the box can go idle"    '[ $(( $(date +%s) - $(stat -c %Y "$CI/.lin-test/last-activity") )) -gt 3000 ]'

echo "sync hand-off"

# A sync given up on partway: the files it did send are remembered, so the next run
# removes one that has since left the worktree.
new_run r-part1 proj part 'true'
bash "$RUNNER" "$CI" r-part1 >/dev/null 2>&1 &
wait_state r-part1 locked
mkdir -p "$CI/proj/part"; echo x > "$CI/proj/part/half.txt"; printf 'half.txt\0' > "$CI/.lin-test/runs/r-part1/manifest"
touch "$CI/.lin-test/runs/r-part1/abort"; wait_state r-part1 done 30; wait
new_run r-part2 proj part 'true'
run_to_end r-part2 proj part keep.txt
check "files from an abandoned sync are reconciled by the next run" '[ ! -e "$CI/proj/part/half.txt" ] && [ -f "$CI/proj/part/keep.txt" ]'

new_run r-del1 proj feat 'true'
run_to_end r-del1 proj feat keep.txt sub/gone.txt
mkdir -p "$CI/proj/feat/node_modules"; echo warm > "$CI/proj/feat/node_modules/pkg"
new_run r-del2 proj feat 'true'
run_to_end r-del2 proj feat keep.txt
check "a file dropped from the worktree is removed on the box" '[ ! -e "$CI/proj/feat/sub/gone.txt" ] && [ ! -d "$CI/proj/feat/sub" ]'
check "files still in the worktree stay"                      '[ -f "$CI/proj/feat/keep.txt" ]'
check "files the sync never sent (installs) are left alone"   '[ -f "$CI/proj/feat/node_modules/pkg" ]'

new_run r-git proj gitb 'git ls-files | sort | tr "\n" " "; echo; echo "commits=$(git rev-list --count HEAD)"'
bash "$RUNNER" "$CI" r-git >/dev/null 2>&1 &
wait_state r-git locked
mkdir -p "$CI/proj/gitb"; printf 'ignored/\n' > "$CI/proj/gitb/.gitignore"; mkdir -p "$CI/proj/gitb/ignored"; echo x > "$CI/proj/gitb/ignored/f"
sync_files r-git proj gitb one.txt dir/two.txt; printf '.gitignore\0' >> "$CI/.lin-test/runs/r-git/manifest"
wait_state r-git done 60; wait
check "the stand-in repository answers git ls-files"  'grep -q "^.gitignore dir/two.txt one.txt $" "$CI/.lin-test/runs/r-git/run.log"' "$(grep -v "^lin-test-run" "$CI/.lin-test/runs/r-git/run.log" | head -3)"
new_run r-git2 proj gitb 'echo "commits=$(git rev-list --count HEAD)"'
run_to_end r-git2 proj gitb one.txt dir/two.txt
check "it stays one snapshot commit across runs"      'grep -q "^commits=1$" "$CI/.lin-test/runs/r-git2/run.log"'
check "it has no remote"                              '[ -z "$(git -C "$CI/proj/gitb" remote)" ]'

new_run r-clean proj feat 'ls' CLEAN=1
run_to_end r-clean proj feat keep.txt
check "--clean wipes the branch folder before the sync" '[ ! -e "$CI/proj/feat/node_modules" ] && [ -f "$CI/proj/feat/keep.txt" ]'

echo "concurrency"

# Two runs at once: each brackets a sleep with markers in a shared file. Serialized runs
# never interleave their markers.
trace="$SCRATCH/trace"; : > "$trace"
for n in 1 2; do
  new_run "r-q$n" proj "q$n" "echo start-$n >> '$trace'; sleep 2; echo end-$n >> '$trace'"
  bash "$RUNNER" "$CI" "r-q$n" >/dev/null 2>&1 &
done
# Play both orchestrators: sync whichever run holds the lock, as it comes.
for _ in 1 2; do
  for i in $(seq 1 300); do
    for n in 1 2; do
      if [ "$(cat "$CI/.lin-test/runs/r-q$n/state" 2>/dev/null)" = locked ] && [ ! -e "$CI/.lin-test/runs/r-q$n/synced" ]; then
        sync_files "r-q$n" proj "q$n" a.txt; break 2
      fi
    done
    sleep 0.1
  done
done
wait_state r-q1 done 60; wait_state r-q2 done 60; wait
check "two runs asked for at once both finish, rc 0"  '[ "$(rc_of r-q1)" = 0 ] && [ "$(rc_of r-q2)" = 0 ]' "rc=$(rc_of r-q1),$(rc_of r-q2)"
order=$(tr '\n' ' ' < "$trace")
check "and never overlap"  '[ "$order" = "start-1 end-1 start-2 end-2 " ] || [ "$order" = "start-2 end-2 start-1 end-1 " ]' "$order"
check "the queued one said it was waiting"            'grep -q "another run holds the box" "$CI/.lin-test/runs/r-q1/run.log" "$CI/.lin-test/runs/r-q2/run.log"'

new_run r-held proj main 'echo never' LOCK_TIMEOUT=2
( flock 8; sleep 6 ) 8>>"$CI/.lin-test/run.lock" &
sleep 0.5
bash "$RUNNER" "$CI" r-held >/dev/null 2>&1; wait
check "a lock that never frees is rc 75 with a reason" '[ "$(rc_of r-held)" = 75 ] && [[ "$(err_of r-held)" == *"run lock"* ]]' "rc=$(rc_of r-held) err=$(err_of r-held)"

echo "pruning"

mkdir -p "$CI/proj/gone-branch" "$CI/proj/stale" "$CI/other/main" "$CI/.lin-test/used/proj" "$CI/.lin-test/used/other"
touch "$CI/.lin-test/used/proj/gone-branch" "$CI/.lin-test/used/other/main"
touch -d '30 days ago' "$CI/.lin-test/used/proj/stale"
new_run r-gc proj main 'true'
printf 'main\nstale\nfeat\ngitb\nq1\nq2\npart\n' > "$CI/.lin-test/runs/r-gc/branches"
run_to_end r-gc proj main a.txt
check "a folder whose branch is gone is pruned"        '[ ! -e "$CI/proj/gone-branch" ]'
check "a folder unused past the retention is pruned"   '[ ! -e "$CI/proj/stale" ]'
check "this run's own folder is kept"                  '[ -d "$CI/proj/main" ]'
check "another repo's folders are judged by age only"  '[ -d "$CI/other/main" ]'

# Short of disk with nothing left to evict but this run's own folder: the run must still
# end with its verdict rather than circle looking for space.
new_run r-full proj main 'echo ran' MIN_FREE_GB=99999999
run_to_end r-full proj main a.txt
check "a disk that cannot be freed does not hang the run" '[ "$(rc_of r-full)" = 0 ] && [ -d "$CI/proj/main" ]' "rc=$(rc_of r-full)"

echo "parameters"

new_run r-badrepo '../escape' main 'true'
bash "$RUNNER" "$CI" r-badrepo >/dev/null 2>&1; wait
check "a repo name that is not a plain name is refused" '[ "$(rc_of r-badrepo)" = 2 ] && [ ! -e "$SCRATCH/escape" ]' "rc=$(rc_of r-badrepo)"
check "a run id that is not a plain name is refused"   '! bash "$RUNNER" "$CI" "../x" 2>/dev/null'

echo "idle monitor (dry run)"

mon() { IDLE_MONITOR_ENV=/nonexistent IDLE_MONITOR_LOG="$SCRATCH/mon.log" IDLE_MONITOR_DRY_RUN=1 \
        IDLE_MINUTES=10 STATE_DIR="$CI/.lin-test" "$@" bash "$MONITOR"; tail -n 2 "$SCRATCH/mon.log" | tr '\n' ' '; }
now=$(date +%s)
touch "$CI/.lin-test/last-activity"
out=$(mon env IDLE_MONITOR_BOOT=$((now - 7200)))
check "a recent heartbeat keeps the box up"            '[[ "$out" == *"staying up"* ]] && [[ "$out" != *"deallocating"* ]]' "$out"
touch -d '30 minutes ago' "$CI/.lin-test/last-activity"
out=$(mon env IDLE_MONITOR_BOOT=$((now - 7200)))
check "an old heartbeat means deallocate"              '[[ "$out" == *"deallocating"* ]]' "$out"
out=$(mon env IDLE_MONITOR_BOOT=$((now - 120)))
check "a box that just booted gets a full window"      '[[ "$out" == *"staying up"* ]]' "$out"
( flock 8; sleep 3 ) 8>>"$CI/.lin-test/run.lock" &
sleep 0.5
out=$(mon env IDLE_MONITOR_BOOT=$((now - 7200)))
check "a held run lock keeps the box up however idle"  '[[ "$out" == *"run active"* ]]' "$out"
wait

echo "what would run (--resolve-only)"

fx="$SCRATCH/fx"; mkdir -p "$fx"; git -C "$fx" init -q -b some/branch .
resolve() { ( cd "$fx" && bash "$ORCH" --resolve-only "$@" 2>&1 ); }
check "a project that says nothing is refused"         '! resolve >/dev/null' "$(resolve | head -1)"
printf '{"packageManager":"pnpm@11.25.0","scripts":{"check":"tsc"}}\n' > "$fx/package.json"
check "a pnpm project with a check script gets the default" '[[ "$(resolve)" == *"command:  corepack pnpm install --frozen-lockfile && corepack pnpm check"* ]]' "$(resolve | grep command)"
check "the branch becomes a plain folder name"         '[[ "$(resolve)" =~ branch:\ \ \ some-branch-[0-9a-f]{8} ]]' "$(resolve | grep branch)"
git -C "$fx" symbolic-ref HEAD refs/heads/some-branch
check "a branch whose name already is one keeps it"    '[[ "$(resolve)" == *"branch:   some-branch"$'"'"'\n'"'"'* ]]' "$(resolve | grep branch)"
check "so two branches never share a folder"           '[ "$(git -C "$fx" symbolic-ref HEAD refs/heads/some/branch; resolve | grep branch)" != "$(git -C "$fx" symbolic-ref HEAD refs/heads/some-branch; resolve | grep branch)" ]'
mkdir -p "$fx/scripts"; printf '# the full check\nLIN_TEST_CMD=make check && make lint\nLIN_TEST_TIMEOUT=900\n' > "$fx/scripts/lin-test.env"
check "scripts/lin-test.env wins over the default"     '[[ "$(resolve)" == *"command:  make check && make lint"* ]] && [[ "$(resolve)" == *"timeout:  900s"* ]]' "$(resolve | grep -E "command|timeout")"
check "a command after -- wins over both"              '[[ "$(resolve -- npm test -- --run)" == *"command:  npm test -- --run"* ]]' "$(resolve -- npm test -- --run | grep command)"
check "--cmd is the same thing as one string"          '[[ "$(resolve --cmd "a && b")" == *"command:  a && b"* ]]'

echo
if [ "$fail" -eq 0 ]; then
  rm -rf "$SCRATCH"
  echo "lin-test: $pass passed, 0 failed"
else
  echo "lin-test: $pass passed, $fail FAILED (scratch kept at $SCRATCH)"
  exit 1
fi
