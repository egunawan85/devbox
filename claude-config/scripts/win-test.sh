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
#   win-test.sh [<worktree>] [--suite unit|integration|smoke|all|e2e|modern|full] [--clean]
#               [--project <name>[,<name>...]] [--env-file <path>]
#     <worktree>   path to the checkout to test (default: the current git worktree root)
#     --project    run exactly these test projects — the .csproj base name, e.g.
#                  PGCrypto.Backend.Identity.Tests — of either shape, instead of a suite.
#                  For iterating on one area: a single modern project takes a few minutes
#                  where --suite full takes about twelve. Cannot be combined with --suite.
#                  A name that matches no test project fails the run and lists the names.
#     --suite      which suite to run (default: integration). 'full' runs the classic set
#                  ('all') and then the modern set ('modern') back-to-back on ONE boot,
#                  syncing once up front and fetching once at the end — a slice pays the
#                  cold start once instead of twice. Its exit code is the worst of the
#                  two; a suite failure does not stop the other from running, but a
#                  timeout does (a wedged box has nothing useful left to tell us).
#     --clean      wipe this branch's synced dir on the box first (cold build)
#     --env-file   forward the KEY=VALUE pairs in <path> to the suite as environment
#                  variables. For credentials a suite reads from its environment and
#                  that must not be committed or synced — the smoke suite's API keys
#                  live in gitignored symlinks that rsync would ship as dangling links.
#                  Values ride the ssh channel's stdin: never in an argv, never on the
#                  box's disk, never logged — only this path is ever echoed. Keys must
#                  match ^[A-Za-z_][A-Za-z0-9_]*$; values are verbatim UTF-8 after the
#                  first '='. A file that is missing, unreadable, empty, non-UTF-8 or
#                  NUL-bearing fails the run before the box is even started, and the
#                  box refuses a payload that arrives incomplete — silence here would
#                  mean a suite that passes having verified nothing. Omitted, nothing
#                  is forwarded. Forwarding also tells the runner credentials are
#                  present, so projects the repo lists in WIN_TEST_SKIP_WITHOUT_ENV_FILE
#                  (scripts/win-test.env) join the broad suites; without it they are left
#                  out of 'all' and 'modern', and the summary names them in notrun=.
#
# Env tunables:
#   WIN_TEST_TIMEOUT        run timeout, seconds (default 1800), applied PER SUITE — so
#                           --suite full allows this long for the classic set and again
#                           for the modern set. On exceed the watchdog collects
#                           diagnostics, fetches any partial results, and exits 124 — it
#                           never hangs indefinitely. The backstop behind the per-project
#                           limit below.
#   WIN_TEST_PROJECT_TIMEOUT  per-project limit, seconds, enforced on the box (default: the
#                           repo's WIN_TEST_PROJECT_TIMEOUT in scripts/win-test.env, else
#                           600). A project past it has its test processes stopped and is
#                           reported stalled (rc=124, named in the summary's stalled=), and
#                           the run moves on to the next project.
#   WIN_TEST_POLL           seconds between status polls / heartbeat lines (default 30)
#   WIN_TEST_RUNNER_ENV     alternate runner.env path
#   WIN_TEST_REMOTE_RUNNER  alternate box-side runner script (testing hook)
#
# Reads box identity from ~/.config/devbox/win-test/runner.env, which `devbox -p win-test
# up` writes. If that file is absent, the appliance hasn't been stood up yet.
#
# Output: a human summary + the TRX/console log fetched into <worktree>/tmp/win-test/. Exit code
# mirrors the suite (0 = all passed). Fails loud; never reports green without a real run.
set -euo pipefail

RUNNER_ENV="${WIN_TEST_RUNNER_ENV:-$HOME/.config/devbox/win-test/runner.env}"
# Installed on the box by install.ps1. Literal $HOME on purpose: the box-side PowerShell
# expands it; a '~' would reach pwsh -File unexpanded and fail as "not a script file".
REMOTE_RUNNER="${WIN_TEST_REMOTE_RUNNER:-\$HOME/.claude/scripts/win-test-run.ps1}"
TIMEOUT_S="${WIN_TEST_TIMEOUT:-1800}"
POLL_S="${WIN_TEST_POLL:-30}"
PROJECT_TIMEOUT_S="${WIN_TEST_PROJECT_TIMEOUT:-}"

die() { echo "win-test: $*" >&2; exit 1; }

# --- deps -----------------------------------------------------------------------
for bin in az ssh rsync git timeout; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done
# rsync gives warm incremental syncs (only changed files cross the wire) — the box gets a
# matching rsync from its toolchain install (spec §R). scp would re-copy everything.

# --- args -----------------------------------------------------------------------
WORKTREE=""; SUITE="integration"; SUITE_SET=0; CLEAN=0; ENV_FILE=""; PROJECTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --suite) SUITE="${2:?--suite needs a value}"; SUITE_SET=1; shift 2 ;;
    --project) PROJECTS="${PROJECTS:+$PROJECTS,}${2:?--project needs a value}"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --env-file) ENV_FILE="${2:?--env-file needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  WORKTREE="$1"; shift ;;
  esac
done
case "$SUITE" in unit|integration|smoke|all|e2e|modern|full) ;; *) die "bad --suite: $SUITE" ;; esac

# --project is its own box-side suite, 'projects': exactly the named projects, nothing else.
# The names reach a PowerShell command string inside single quotes, so allow only what a
# .csproj base name needs rather than trying to quote anything else.
if [ -n "$PROJECTS" ]; then
  [ "$SUITE_SET" = 0 ] || die "--project and --suite cannot be combined: --project runs exactly the named projects"
  [[ $PROJECTS =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]] \
    || die "--project: a name may contain only letters, digits, '.', '_' and '-' (several are comma-separated): $PROJECTS"
  SUITE="projects"
fi
if [ -n "$PROJECT_TIMEOUT_S" ]; then
  [[ $PROJECT_TIMEOUT_S =~ ^[1-9][0-9]*$ ]] \
    || die "WIN_TEST_PROJECT_TIMEOUT must be a positive whole number of seconds: $PROJECT_TIMEOUT_S"
fi

# 'full' is not a box-side suite — it's "the classic set and the modern set, on ONE boot".
# The box deallocates between runs, so running them as two invocations makes a slice pay
# the (multi-minute) cold start twice. Expanding here rather than in the box-side runner
# keeps this orchestrator-side: it works against any box whose runner already knows 'all'
# and 'modern', with no matching box-file change to keep in step.
if [ "$SUITE" = full ]; then SUITE_LIST="all modern"; else SUITE_LIST="$SUITE"; fi

# What every generic-runner invocation carries beyond repo, suite and run id. Each value
# is validated above or is a fixed word, so it is safe inside the box-side command string.
# Nothing is added for e2e, whose repo-local runner takes none of these.
RUNNER_EXTRA=""
if [ "$SUITE" != e2e ]; then
  if [ -n "$PROJECTS" ]; then RUNNER_EXTRA+=" -ProjectNames '$PROJECTS'"; fi
  if [ -n "$PROJECT_TIMEOUT_S" ]; then RUNNER_EXTRA+=" -ProjectTimeoutSec $PROJECT_TIMEOUT_S"; fi
  if [ -n "$ENV_FILE" ]; then RUNNER_EXTRA+=" -EnvFileForwarded"; fi
fi

# --- credential forwarding (--env-file) -----------------------------------------
# Some suites configure themselves from the PROCESS ENVIRONMENT only — PGCrypto.Tests.Smoke
# reads its API url/key/secret via Environment.GetEnvironmentVariable and ships no dotenv
# loader — so with nothing forwarded its Tier 0 gate fails and nothing is actually verified.
# Those secrets can't ride along in the worktree either: they live in gitignored symlinks
# into /dev/shm, and `rsync -az` (no --copy-links) syncs the LINK, which dangles on Windows.
#
# So they travel out-of-band, over the ssh channel's stdin, base64-encoded. The box-side
# wrapper (built at the invocation below) decodes them into real env vars and then runs the
# normal runner, which inherits them as any child process does. Constraints this satisfies:
#   * never in an argv — the box's process list is readable, so `$env:K='v'` in an ssh
#     command string is out;
#   * never on the box's disk — no scp, no temp file, in memory for the run only;
#   * never in output — echoes name the file PATH, never a key or a value, and the parser
#     below disables xtrace so even `bash -x win-test.sh` can't trace one;
#   * no escaping logic to get subtly wrong — key names are validated against a strict
#     charset rather than escaped, and base64 flattens every quoting/newline/encoding
#     hazard in the values.
# Distinct from the box-side runner's <repo>/scripts/win-test.env loader, which is for
# non-secret config a repo COMMITS. That one only sets a key it doesn't already see, so
# values forwarded here (set before the runner starts) deliberately win over it.
ENV_B64=""; ENV_COUNT=0
build_env_payload() {
  local -                       # scope shell options to this function…
  set +x                        # …so xtrace can never expose a value
  # Byte semantics for the key match. Under a UTF-8 locale glibc's [A-Za-z] ranges also match
  # accented letters, which .NET's identical-looking regex on the box does NOT — the devbox
  # would accept and count a key the box then silently skips, running the suite one
  # credential short. `local` restores the caller's locale on return.
  local LC_ALL=C LANG=C
  local f="$1" line key val payload="" n=0 count=0
  # Fail loud on every unusable-file case: a silent no-op here would recreate exactly the
  # false-green (suite runs unconfigured, gate fails, or worse, passes vacuously) this exists
  # to fix. Symlinks are followed — the real files usually ARE symlinks into /dev/shm.
  [ -e "$f" ] || die "--env-file: no such file: $f"
  [ -f "$f" ] || die "--env-file: not a regular file: $f"
  [ -r "$f" ] || die "--env-file: not readable: $f"
  # The box decodes the payload with UTF8.GetString, which does not throw on malformed input
  # — it silently substitutes U+FFFD. A non-UTF-8 byte would therefore arrive ALTERED while
  # claiming to be verbatim, and surface as an inexplicable auth failure. Reject the file
  # instead. (Reads the file but discards its content, so nothing is exposed.)
  iconv -f UTF-8 -t UTF-8 <"$f" >/dev/null 2>&1 \
    || die "--env-file: $f is not valid UTF-8 — values must be UTF-8 to survive the transfer intact"
  # `read` discards NUL bytes without a word, which would likewise alter a value while
  # reporting success. Compare the file against a NUL-stripped copy rather than trusting the
  # parse. (cmp -s: the content is compared, never printed.)
  tr -d '\0' <"$f" | cmp -s - "$f" \
    || die "--env-file: $f contains a NUL byte, which cannot survive the transfer intact"
  # `|| [ -n "$line" ]` so a last line with no trailing newline is still parsed, not dropped.
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"                        # tolerate a CRLF-terminated file
    line="${line#$'\xef\xbb\xbf'}"              # …and a UTF-8 BOM from a Windows editor
    line="${line#"${line%%[![:space:]]*}"}"     # tolerate leading indentation
    case "$line" in ''|'#'*) continue ;; esac   # blank lines and comments
    case "$line" in *=*) ;; *) die "--env-file: $f line $n: no '=' found" ;; esac
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"        # trailing space before the '='
    val="${line#*=}"                            # split on the FIRST '=' only; '=' inside a
                                                # value is part of the value
    # Reject rather than escape. Note the message names the LINE, never the key: on a
    # malformed file the text left of an '=' can itself be secret material.
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
      || die "--env-file: $f line $n: invalid key name (must match ^[A-Za-z_][A-Za-z0-9_]*\$)"
    # Value taken verbatim: whatever follows the first '=' IS the value, spaces and quote
    # marks included (UTF-8, per the check above). Credentials are copied from vaults and
    # portals; silently trimming or unquoting them would turn a correct secret into a
    # baffling auth failure.
    payload+="$key=$val"$'\n'
    count=$((count + 1))
  done < "$f"
  [ "$count" -gt 0 ] || die "--env-file: $f defines no KEY=VALUE pairs"
  ENV_COUNT=$count
  # Make the payload self-describing so the box can tell a COMPLETE one from a truncated or
  # partially-applied one. Without this, a payload cut mid-stream on a 4-char base64 boundary
  # decodes cleanly to a prefix, the bootstrap sets a corrupted or missing credential, and
  # the suite runs green having verified nothing — the failure mode this flag exists to kill.
  # It is a count, never a key: nothing here identifies a variable.
  payload="#count=$count"$'\n'"$payload"
  # printf is a bash BUILTIN, so the payload never becomes a process argv anywhere.
  ENV_B64=$(printf '%s' "$payload" | base64 -w0) || die "--env-file: failed to encode $f"
}
# Writes the payload to the ssh channel's stdin. It disables xtrace for the same reason the
# parser does, and it is not enough to rely on the parser's: `local -` restores options when
# THAT function returns, so tracing is live again by the time this one runs. Without this,
# `bash -x` (or SHELLOPTS=xtrace, with no flag at all) prints the expanded base64 payload,
# which is one `base64 -d` away from every plaintext credential.
emit_env_payload() { local -; set +x; printf '%s' "$ENV_B64"; }
if [ -n "$ENV_FILE" ]; then
  # Checked here, not in the global dep loop, so a run without the flag is unaffected — and
  # up front, so a missing tool can't surface later as a misleading integrity error.
  for bin in base64 iconv tr cmp; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH (needed by --env-file)"
  done
  build_env_payload "$ENV_FILE"    # before the box is woken: a bad file must not start a VM
fi

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

# With --env-file the run command becomes a box-side bootstrap that HOLDS the forwarded
# credentials in its own process, so anything interpolated into it must not be able to break
# out of its PowerShell string and read them back out. SUITE is allowlisted and RUN_ID is
# generated; the branch name and CI_DIR are free-form, so reject what PowerShell would treat
# specially rather than trying to quote it. They reach a single-quoted PS string as $DEST,
# and on the e2e path they also compose $REMOTE_RUNNER, which lands in a double-quoted one —
# hence checking `, " and $ here too, not just the single quote. (Backslash is NOT special in
# either, so a `CI_DIR=C:\ci` spelling stays usable.)
#
# The same interpolations exist on the plain path and predate this flag; the guard is
# deliberately scoped to --env-file so a run without it stays byte-for-byte what it was — and
# it has no secrets to lose either way. WIN_TEST_REMOTE_RUNNER gets its own check at the
# invocation site, once the e2e reroute below has had its say.
if [ -n "$ENV_FILE" ]; then
  case "$SAFE_BRANCH$CI_DIR" in
    *"'"*|*'"'*|*'$'*|*'`'*)
      die "--env-file refused: branch '$BRANCH' or CI_DIR '$CI_DIR' contains a quote, \$ or backtick — rename the branch before forwarding credentials" ;;
  esac
fi

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

# --- 2b. wait for the box's RSYNC to be ready (not just sshd) -------------------
# sshd answers well before the box can actually serve an rsync. On a cold boot the
# first worktree sync then dies mid-stream:
#   rsync: [Receiver] safe_write failed to write 24 bytes to socket: Resource
#          temporarily unavailable (11)
#   rsync error: error in rsync protocol data stream (code 12)
# — and the run gives up having tested nothing. "ssh answered" and "the box can
# receive a file" are two different readiness signals; this probes the second one
# directly by pushing one throwaway byte and requiring it to land.
#
# The probe writes to its own dir under $CI_DIR, never into $DEST: it must not race
# the --delete sync below, and it must be able to run before $DEST exists.
#
# The box's rsync (cwRsync) is cygwin: it reads "C:/ci/…" as a RELATIVE path (prefixing
# $HOME), so rsync gets the /cygdrive/c/… spelling while PowerShell keeps the C:/… one.
win2cyg() {
  case "$1" in
    [A-Za-z]:*) printf '/cygdrive/%s%s' "$(printf '%.1s' "$1" | tr '[:upper:]' '[:lower:]')" "${1#?:}" ;;
    *) printf '%s' "$1" ;;
  esac
}
CI_CYG=$(win2cyg "$CI_DIR")
# rsync creates only the LAST component of a destination path, so on a box where $CI_DIR
# itself does not exist yet the probe below would fail every attempt and then blame the
# box's copy path for what is really a missing directory. Create it first (Force also
# makes parents, and is a no-op when it already exists) so a probe failure means what the
# error says it means.
"${SSH[@]}" "pwsh -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '$CI_DIR' | Out-Null\"" </dev/null \
  || die "couldn't create $CI_DIR on the box"
probe_rsync() {
  local d; d=$(mktemp -d) || return 1
  : > "$d/.probe"
  rsync -a -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    "$d/.probe" "$SSH_USER@$SSH_HOST:$CI_CYG/.win-test-probe/" >/dev/null 2>&1
  local rc=$?
  rm -rf "$d"
  return $rc
}
echo "win-test: waiting for the box's rsync to accept a transfer…"
for _ in $(seq 1 12); do
  if probe_rsync; then rsync_ready=1; break; fi
  sleep 5
done
[ "${rsync_ready:-0}" = 1 ] \
  || die "the box answers ssh but could not accept an rsync transfer after 60s — box started but its copy path never came up"

# --- 3. sync the worktree (warm, incremental) -----------------------------------
DEST="$CI_DIR/$SAFE_BRANCH"
# A suite may ship its own box-side runner in the repo (scripts/win-test-<suite>.ps1).
# The E2E suite does: it deploys the full IIS stack + SPA and runs Playwright against it —
# work the generic runner (which only does nuget/msbuild/dotnet-test) can't do. Route to
# the repo-local runner so all that logic lives in the repo, versioned with the tests.
# (The default WIN_TEST_REMOTE_RUNNER override still wins if set explicitly.)
if [ -z "${WIN_TEST_REMOTE_RUNNER:-}" ] && [ "$SUITE" = "e2e" ]; then
  REMOTE_RUNNER="$DEST/scripts/win-test-e2e.ps1"
fi
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
#
# Retried, but ONLY on rsync exit 12 (error in rsync protocol data stream) — the
# cold-boot transient the probe above narrows but cannot fully exclude: the box can
# accept a one-byte probe and still drop the first real multi-minute transfer while
# its services finish settling. Every other exit code is a real failure (bad path,
# permissions, disk full) and must stay loud and immediate: retrying those would
# turn a genuine error into three identical errors and a longer wait.
sync_attempt=0
while :; do
  sync_attempt=$((sync_attempt + 1))
  set +e
  rsync -az --delete \
    --exclude '.git/' --exclude 'bin/' --exclude 'obj/' --exclude 'tmp/' --exclude 'node_modules/' \
    -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new" \
    "$WORKTREE/" "$SSH_USER@$SSH_HOST:$DEST_CYG/"
  sync_rc=$?
  set -e
  [ "$sync_rc" = 0 ] && break
  if [ "$sync_rc" != 12 ] || [ "$sync_attempt" -ge 3 ]; then
    die "syncing the worktree to the box failed (rsync exit $sync_rc after $sync_attempt attempt(s))"
  fi
  echo "win-test: ⚠️  sync hit the cold-boot rsync transient (exit 12); retrying (attempt $((sync_attempt + 1))/3)…" >&2
  sleep $((sync_attempt * 5))
done

# --- 4. run the suite on the box (box-side lock serializes concurrent runs) ------
# The remote runner runs as a BACKGROUND ssh (stdio inherited, so its console output
# still streams live) with a watchdog around it. Completion is signalled by the sentinel
# the runner writes (tmp/win-test/done.json, spec §X6) — NOT by the ssh exiting: a
# box-side child that inherits the session's stdio (sqlservr.exe did exactly this) keeps
# the ssh alive long after the suite finished. The ssh exiting is the common case; the
# sentinel is what we trust.
RUN_ID="$(date +%s).$$"
REMOTE_RESULTS="$DEST/tmp/win-test"
# Results land in the worktree under test, not the caller's current directory. A run
# launched from one worktree for another would otherwise write its evidence into the
# wrong checkout, where it can be mistaken for that checkout's own or overwrite it.
RESULTS_DIR="$WORKTREE/tmp/win-test"
mkdir -p "$RESULTS_DIR"
STAMP="$RESULTS_DIR/.run-started"   # mtime fence: TRX from THIS run are newer than it
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

# Runs ONE suite on the already-woken, already-synced box and waits for its sentinel.
# Factored out so --suite full can call it twice against the same live box: everything
# expensive (wake, ssh wait, rsync readiness, the worktree sync) happens once before the
# first call, and the fetch + verdict once after the last. Reads $1 as the suite to run;
# sets run_rc, and accumulates any_timed_out / lingered / SUMMARY_LINES for the caller.
# (`git diff -w` shows the body itself is unchanged apart from the noted additions.)
run_one_suite() {
  local SUITE_RUN="$1"
  # Distinct per suite: two runs in one invocation must not be able to match each
  # other's sentinel. $$ alone repeats within a single process.
  local RUN_ID="$(date +%s).$$.$SUITE_RUN"
  local sentinel="" timed_out=0 status rc slept elapsed START SSH_PID ssh_rc err sum

  # A stale sentinel from a previous run must not read as this run finishing. (Guarded by
  # Test-Path: Remove-Item on a missing file flips \$? even with SilentlyContinue, which
  # would exit the remote shell — and this script — non-zero.)
  "${SSH[@]}" "if (Test-Path ('$REMOTE_RESULTS'+'/done.json')) { Remove-Item ('$REMOTE_RESULTS'+'/done.json') -Force }" </dev/null \
    || die "couldn't clear the stale completion sentinel on the box"

  echo "win-test: running '$SUITE_RUN' suite on $VM_NAME (run $RUN_ID; timeout ${TIMEOUT_S}s)…"
  if [ -n "$ENV_FILE" ]; then
    # Forwarding credentials: wrap the SAME runner invocation in a box-side bootstrap that
    # first drains stdin for the payload. The bootstrap carries the paths/suite/run id but
    # NO values, so encoding it into the command line is safe.
    #
    # -EncodedCommand (base64 UTF-16LE) rather than a quoted command string: this text has to
    # survive the box's default SSH shell, which is PowerShell, and the usual "single-quoted
    # PS strings only" rule can't express a nested regex + nested quotes without escaping that
    # is easy to get subtly wrong. Base64 is [A-Za-z0-9+/=] — nothing for either shell to
    # interpret, so the bootstrap reaches pwsh exactly as written.
    echo "win-test: forwarding $ENV_COUNT variable(s) from $ENV_FILE (names and values never logged)"
    # $REMOTE_RUNNER is interpolated into a DOUBLE-quoted PS string below, deliberately, so the
    # box expands the literal $HOME its default spelling carries. That makes ", ` and $ live
    # inside it: a runner path carrying any of them could close the string and run PowerShell
    # in this very process, moments after the credentials were set into its environment. Strip
    # the one $HOME that is meant, then refuse any other expansion. Checked here rather than
    # with the branch/CI_DIR guard above because the e2e reroute rewrites it in between.
    case "${REMOTE_RUNNER#\$HOME}" in
      *'"'*|*'`'*|*'$'*)
        die "--env-file refused: the box-side runner path contains a quote, backtick, or a \$ expansion beyond a leading \$HOME" ;;
    esac
    # The heredoc body and its PSEOF terminator stay at column 0: <<'PSEOF' is quoted (so the
    # PowerShell text is taken verbatim) and an indented terminator would not close it.
    ENV_BOOTSTRAP_PS=$(cat <<'PSEOF'
$ErrorActionPreference = 'Stop'
$b = [Console]::In.ReadToEnd()
if (-not $b) { [Console]::Error.WriteLine('win-test-run: credential payload never arrived on stdin'); exit 78 }
$expected = -1
$applied = 0
foreach ($l in [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($b -replace '\s',''))).Split([char]10)) {
  if ($l -match '^#count=([0-9]+)$') { $expected = [int]$Matches[1]; continue }
  $i = $l.IndexOf('=')
  if ($i -lt 1) { continue }
  $k = $l.Substring(0, $i)
  if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
  Set-Item -Path ('Env:' + $k) -Value $l.Substring($i + 1)
  $applied++
}
if ($expected -lt 0 -or $applied -ne $expected) {
  [Console]::Error.WriteLine("win-test-run: credential payload incomplete - expected $expected variable(s), applied $applied")
  exit 78
}
Remove-Variable b, l, i, k, expected, applied -ErrorAction SilentlyContinue
PSEOF
)
    # The runner runs as a CHILD process and inherits the environment set above — the same
    # `pwsh -NoProfile -File …` invocation as the plain path, so exit codes, the done.json
    # sentinel and the console stream all behave identically. $REMOTE_RUNNER goes in a PS
    # double-quoted string because its default spelling contains a literal $HOME for the box
    # to expand; \$LASTEXITCODE is escaped so bash leaves it for pwsh.
    ENV_BOOTSTRAP_PS="$ENV_BOOTSTRAP_PS
& pwsh -NoProfile -File \"$REMOTE_RUNNER\" -RepoDir '$DEST' -Suite '$SUITE_RUN' -RunId '$RUN_ID'$RUNNER_EXTRA
exit \$LASTEXITCODE"
    ENC_CMD=$(printf '%s' "$ENV_BOOTSTRAP_PS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0) \
      || die "couldn't encode the box-side credential bootstrap"
    # Process substitution, not a pipeline, so $! stays the SSH pid exactly as below. stdin is
    # the payload instead of /dev/null; it EOFs as soon as the payload is written, so the
    # background-ssh + inherited-stdio + sentinel contract above is unchanged.
    "${SSH[@]}" "pwsh -NoProfile -EncodedCommand $ENC_CMD" < <(emit_env_payload) &
  else
    "${SSH[@]}" "pwsh -NoProfile -File $REMOTE_RUNNER -RepoDir '$DEST' -Suite '$SUITE_RUN' -RunId '$RUN_ID'$RUNNER_EXTRA" </dev/null &
  fi
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
  run_rc=""
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
    echo "win-test: ⏱ ${elapsed}s elapsed [$SUITE_RUN] — ${status:-status poll failed (box busy?)}"
  done

  if [ "$timed_out" = 1 ]; then
    # Never hang silently: abort loudly, but grab evidence + partial results first.
    run_rc=124
    any_timed_out=1
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

  # Surface a runner-side error (lock timeout, build failure throw) recorded in the sentinel,
  # and the runner's machine-readable summary line. The summary is what a session should read
  # instead of scraping every project's Passed!/Failed! line out of the log.
  if [ -n "$sentinel" ]; then
    err=$(printf '%s' "$sentinel" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p')
    [ -n "$err" ] && echo "win-test: runner reported: $err" >&2
    sum=$(printf '%s' "$sentinel" | sed -n 's/.*"summary":"\([^"]*\)".*/\1/p')
    if [ -n "$sum" ]; then
      echo "win-test: $sum"
      SUMMARY_LINES="$SUMMARY_LINES$sum"$'\n'
    fi
  fi
  # Explicit: the verdict travels in $run_rc, never in this function's exit status. Under
  # `set -e` a non-zero return here would abort the whole script mid-loop — so a failing
  # first suite would take the second one down with it instead of reporting it.
  return 0
}

# --- 4b. drive the suite list (one entry, or 'all' then 'modern' for --suite full) ---
overall_rc=0; any_timed_out=0; lingered=0; SUMMARY_LINES=""
for suite_to_run in $SUITE_LIST; do
  run_one_suite "$suite_to_run"
  # Worst result wins: a green modern run must never mask a red classic one.
  if [ "$run_rc" != 0 ] && [ "$overall_rc" = 0 ]; then overall_rc="$run_rc"; fi
  # A suite FAILING is a verdict — keep going, the other suite's verdict is still worth
  # having from this boot. A suite TIMING OUT is not a verdict: the box may be wedged, so
  # stop rather than pile a second doomed run onto it.
  if [ "$any_timed_out" = 1 ]; then
    echo "win-test: skipping the remaining suite(s) after a timeout." >&2
    break
  fi
done
run_rc="$overall_rc"
timed_out="$any_timed_out"

# --- 5. fetch results (loud — a swallowed fetch error reads as a clean run) ------
echo "win-test: fetching results → $RESULTS_DIR/"
fetch_ok=1
rsync -az -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new" \
  "$SSH_USER@$SSH_HOST:$DEST_CYG/tmp/win-test/" "$RESULTS_DIR/" || {
  fetch_ok=0
  echo "win-test: ⚠️  fetching results FAILED — they remain on the box at $DEST/tmp/win-test" >&2
}

# If the channel had to be killed, the runner's last console lines (the per-project
# summaries) never streamed — replay them from the fetched logs so the operator still
# sees them.
if [ "${lingered:-0}" = 1 ] && [ "$fetch_ok" = 1 ]; then
  echo "win-test: final runner output didn't stream; summaries from the fetched logs:"
  find "$RESULTS_DIR" -name '*.Tests.*.log' -newer "$STAMP" \
    -exec sh -c 'tail -2 "$1" | sed "s|^|win-test:   |"' _ {} \; 2>/dev/null || true
fi

# Green needs evidence: a pass without a TRX from this run (fetch failed, or nothing new
# arrived) is not a pass (spec §X5).
if [ "$run_rc" = 0 ]; then
  fresh_trx=$(find "$RESULTS_DIR" -name '*.trx' -newer "$STAMP" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$fetch_ok" != 1 ] || [ "$fresh_trx" = 0 ]; then
    echo "win-test: ❌ suite reported pass but no TRX from this run was fetched — refusing to report green without evidence." >&2
    run_rc=1
  fi
fi

# The runner's machine-readable summary, one line per suite that ran (--suite full leaves
# two). This plus the exit code is the verdict; the per-project Passed!/Failed! lines in the
# fetched logs are supporting detail, not something a session should have to scrape.
if [ -n "$SUMMARY_LINES" ]; then
  echo
  printf '%s' "$SUMMARY_LINES" | sed 's/^/win-test: /'
fi

echo
if [ "$timed_out" = 1 ]; then
  echo "win-test: ⛔ suite '$SUITE' TIMED OUT on $VM_NAME (branch $BRANCH) after ${TIMEOUT_S}s — possible hang; not a suite verdict. Partial results (if any) in $RESULTS_DIR/." >&2
elif [ "$run_rc" = 0 ]; then
  echo "win-test: ✅ suite '$SUITE' passed on $VM_NAME (branch $BRANCH). Results in $RESULTS_DIR/."
else
  echo "win-test: ❌ suite '$SUITE' FAILED on $VM_NAME (branch $BRANCH), exit $run_rc. See $RESULTS_DIR/."
fi
echo "win-test: box left running; it self-deallocates after ${IDLE_MINUTES:-20} min idle."
exit "$run_rc"
