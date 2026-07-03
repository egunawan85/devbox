---
description: Run this worktree's Windows-only test suite on the ephemeral Azure appliance and report the real result.
argument-hint: '[--suite unit|integration|smoke|all] [--clean] [worktree]  (default: integration, current worktree)'
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
- fetches the TRX + console logs into `./tmp/win-test/`,
- leaves the box running; it self-deallocates after it's been idle a while.

The script's exit code mirrors the suite (0 = all passed).

## Step 2 — Report the real outcome

Read the fetched TRX / logs in `./tmp/win-test/` and report **passed / failed / skipped**
with the failing test names and messages. If the script failed to reach the box (e.g. no
`~/.config/devbox/win-test/runner.env` — the appliance isn't stood up), say so plainly.

**Never** mark Windows tests passed, or skipped-as-unrunnable, without an actual run here.
If you couldn't run them, say exactly that and why — don't paper over it.
