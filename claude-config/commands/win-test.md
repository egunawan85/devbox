---
description: Run this worktree's Windows-only test suite on the ephemeral Azure appliance and report the real result.
argument-hint: '[--suite unit|integration|smoke|all|e2e|modern|full | --project <name>[,<name>]] [--clean] [--env-file <path>] [worktree]  (default: integration, current worktree)'
allowed-tools: Bash(~/.claude/scripts/win-test.sh:*), Bash(~/.claude/scripts/win-test-launch.sh:*), Read, Grep, Glob
---

# /win-test — run Windows-only tests on the appliance

You're on the Linux devbox. Some suites (this project's own CLAUDE.md says which — the
runegate / kash-cards integration + regression tests target .NET Framework 4.8 + SQL
Server LocalDB) **cannot run here**. This command runs them for real on the ephemeral
Windows box and brings the results back. It does not "simulate" — a green here means the
suite actually passed on Windows.

## Step 1 — Run it

Run `~/.claude/scripts/win-test.sh $ARGUMENTS`. With no worktree argument it targets the
current git worktree; default suite is `integration`. The script:

- wakes the `win-test` box (idempotent — no-op if already warm),
- rsyncs this worktree to `C:\ci\<branch>` (kept per-branch for warm incremental builds),
- runs the suite under a box-wide lock (concurrent sessions queue — they share one LocalDB),
- prints a heartbeat while the suite runs and watchdogs the whole thing — past
  `WIN_TEST_TIMEOUT` (default 30 min, applied per suite) it aborts with diagnostics instead of hanging,
- gives each test project its own time limit on the box (`WIN_TEST_PROJECT_TIMEOUT`, default
  10 min): a project past it has its test processes stopped and is reported `stalled`, and
  the run moves on to the next project,
- fetches the TRX + console logs into `./tmp/win-test/`,
- leaves the box running; it self-deallocates after it's been idle a while.

`--project <name>[,<name>]` runs exactly those test projects (the `.csproj` base name, e.g.
`PGCrypto.Backend.Identity.Tests`), of either shape, instead of a suite. Use it while
iterating on one area — one modern project takes a few minutes where `--suite full` takes
about twelve — and keep `--suite full` for the run before a PR. It cannot be combined with
`--suite`; a name that matches no project fails the run and lists the names that exist.

**A run takes minutes — about 12 for `--suite full` on a warm box, more from a cold start —
which outlives a foreground command here.** For anything
longer than a single fast suite, run `~/.claude/scripts/win-test-launch.sh $ARGUMENTS`
instead: same arguments, but it detaches the run, prints the log path and PID
immediately, and appends `WRAPPER_EXIT <rc>` to the log when it finishes. Poll that log
rather than holding a foreground command open. It refuses to start if another run holds
the lock — the box is single-tenant — and names the run that does.

`--suite full` runs the classic set (`all`) and then the modern set (`modern`)
back-to-back on **one boot**, syncing once and fetching once. Prefer it over two separate
invocations: the box deallocates between runs, so running them separately pays the
multi-minute cold start twice. Its exit code is the worst of the two.

`--suite modern` selects the SDK-style test projects — the ones named `<Project>.Tests.csproj`,
which match none of the classic `*.Tests.<suite>.csproj` globs. Unlike the classic suites (which
the runner prebuilds with nuget/msbuild), these are built by `dotnet test` itself, since not all
of them belong to a root `.sln`.

`--suite e2e` is special: instead of the generic nuget/msbuild/dotnet-test runner it routes
to the repo's own box-side runner (`scripts/win-test-e2e.ps1`), which deploys the full IIS
stack (API + INT + BFF), builds and stages the SPA, installs Chromium, and runs the
Playwright `QryptoOmni.Tests.E2E` suite against the local origin. It needs the appliance to
have IIS (auto-provisioned via `deploy-iis.ps1 setup`) and a SQL Server on `localhost:1433`
(LocalDB alone is not enough); the runner fails loudly if the SQL prereq is missing.

`--env-file <path>` forwards that file's `KEY=VALUE` pairs to the suite as **environment
variables on the box**. Use it for suites that configure themselves from the process
environment and would otherwise fail their own preflight gate — `smoke`
(`PGCrypto.Tests.Smoke`) reads its API url/key/secret via `Environment.GetEnvironmentVariable`
with no dotenv fallback, and `e2e` needs the same. Those secrets can't simply be synced:
they live in gitignored symlinks that rsync ships as links that dangle on Windows.

The values go over the ssh channel's stdin, base64-encoded, into a box-side wrapper that
sets them and then runs the normal runner. They never appear in a command line, never reach
the box's disk, and are never logged — so **don't** echo the file, `cat` it, or name its keys
in your report; say only which path was forwarded. A missing, unreadable, or empty file
fails the run loudly rather than starting a suite that would go green having verified
nothing. Repo-committed **non-secret** config belongs in `<repo>/scripts/win-test.env`
instead, which the box-side runner picks up on its own.

The script's exit code mirrors the suite (0 = all passed). Exit 124 means the run
**timed out — possible hang**, not a suite verdict: report it as such.

## Step 2 — Report the real outcome

The run ends with a machine-readable verdict — **read this, don't scrape the log**:

```
WIN-TEST-SUMMARY suite=all projects=3/3 passed=6782 failed=0 skipped=1 excluded=<classes> stalled=none notrun=<projects> rc=0
```

with a `WIN-TEST-PROJECT` line per project. `--suite full` emits one summary per suite.
Report those counts plus, for any failure, the failing test names and messages from the
fetched TRX / logs in `./tmp/win-test/`. If the script failed to reach the box (e.g. no
`~/.config/devbox/win-test/runner.env` — the appliance isn't stood up), say so plainly.

`excluded=` names test classes the runner **deliberately skipped because they cannot run
on the box** — they shell out to git against their own checkout, and the sync omits
`.git`. That is not a pass and not a Windows failure; mention it when it's non-empty
rather than letting it read as full coverage. Support/Fixtures helper libraries are
likewise not run — they contain no tests by design, and are excluded rather than counted
as failures.

`stalled=` names projects stopped at the per-project time limit. That is a stall, not a
test verdict: report it as a possible hang in that project, with the log tail. `notrun=`
names projects the repo marks as needing forwarded credentials (runegate's smoke suite) that
a broad suite left out because no `--env-file` came with the run; mention it rather than let
the count read as full coverage. A project whose tests all passed but whose test host then
crashed fails with a line saying so — report the crash, not a failing test.

**Never** mark Windows tests passed, or skipped-as-unrunnable, without an actual run here.
If you couldn't run them, say exactly that and why — don't paper over it.
