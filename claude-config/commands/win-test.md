---
description: Run this worktree's Windows-only test suite on the ephemeral Azure appliance and report the real result.
argument-hint: '[--suite unit|integration|smoke|all|e2e|modern] [--clean] [--env-file <path>] [worktree]  (default: integration, current worktree)'
allowed-tools: Bash(~/.claude/scripts/win-test.sh:*), Read, Grep, Glob
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
  `WIN_TEST_TIMEOUT` (default 60 min) it aborts with diagnostics instead of hanging,
- fetches the TRX + console logs into `./tmp/win-test/`,
- leaves the box running; it self-deallocates after it's been idle a while.

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

Read the fetched TRX / logs in `./tmp/win-test/` and report **passed / failed / skipped**
with the failing test names and messages. If the script failed to reach the box (e.g. no
`~/.config/devbox/win-test/runner.env` — the appliance isn't stood up), say so plainly.

**Never** mark Windows tests passed, or skipped-as-unrunnable, without an actual run here.
If you couldn't run them, say exactly that and why — don't paper over it.
