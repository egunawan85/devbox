---
description: Run this worktree's full check on the ephemeral Linux test appliance and report the real result, with counts.
argument-hint: '[worktree] [--clean] [-- <command ...>]  (default: current worktree, the project''s own check)'
allowed-tools: Bash(~/.claude/scripts/lin-test.sh:*), Bash(~/.claude/scripts/lin-test-launch.sh:*), Read, Grep, Glob
---

# /lin-test — run a project's full check off the devbox

The Linux devbox is shared by several sessions, and a full check (build, lint, the whole
test suite, a database in Docker) fails on timeouts when two run there at once. This
command runs the check for real on a separate Linux box that is off unless a run is
happening, and brings the result back. A green here means the command actually exited 0
there, against this worktree's files as they are now, uncommitted edits included.

## Step 1 — Run it

A full check outlives a foreground command here, so launch it detached:

`~/.claude/scripts/lin-test-launch.sh $ARGUMENTS`

It prints the log path and PID at once, and appends `WRAPPER_EXIT <rc>` to the log when
the run ends. Poll that log; don't hold a foreground command open. (For a command you
know takes under a few minutes, `~/.claude/scripts/lin-test.sh $ARGUMENTS` runs it in the
foreground with the same arguments.)

With no arguments it tests the current git worktree with the project's own check:
`LIN_TEST_CMD=` in the repo's committed `scripts/lin-test.env` if there is one, otherwise
`corepack pnpm install --frozen-lockfile && corepack pnpm check` for a pnpm project that
has a `check` script. If the project says neither, the run is refused: give a command
after `--` rather than guessing one silently. Anything after `--` is run instead, e.g.
`/lin-test -- corepack pnpm test`.

What the script does:

- starts the `lin-test` box if it is off (no-op if it is already up),
- takes the box's run lock — **runs queue**, one at a time, because a check binds fixed
  local ports on the box; a queued run says so and waits its turn,
- syncs the files git knows about in this worktree (tracked, and untracked-but-not-ignored)
  to the branch's own folder on the box, which is kept between runs so installs are warm,
- runs the command there and streams its output into the log,
- fetches the run's log and verdict into the worktree's `tmp/lin-test/<run id>/`
  (`tmp/lin-test/latest` points at the newest),
- leaves the box running; it turns itself off after it has been idle a while. Never stop
  or deallocate the box yourself: another session's run may be on it.

`--clean` wipes this branch's folder on the box first, for a cold install and build.

## Step 2 — Report the real outcome

The run ends with a machine-readable line — **read this, don't scrape the log**:

```
LIN-TEST-SUMMARY repo=anvil branch=my-branch rc=0 seconds=431 counts=vitest runs=2 passed=1312 failed=0 skipped=4
```

- `rc` is the command's exit code and **is the verdict**. `0` = passed.
- The counts are read from the test runner's own summary lines in the log and summed
  over every test run in it (`runs=`). Report them as passed / failed / skipped.
  `counts=none` means the output had no summary this script recognizes: say the command
  passed or failed and that there are no counts, rather than reporting zeros.
- For any failure, give the failing test names and messages from
  `tmp/lin-test/latest/run.log`.

Exit codes that are **not** a verdict on the code — report them as what they are:

- `124` — the command was still running at its time limit (`LIN_TEST_TIMEOUT`, default
  40 min) and was stopped: a possible hang.
- `75` — the run never got to execute (it waited out the lock, or the sync never
  arrived). The log line beginning `runner reported:` says which.
- `130` — the run was abandoned (the caller was interrupted).
- "no appliance config at …/runner.env" — the appliance isn't stood up
  (`devbox -p lin-test up`). Say so plainly.

Two things about what the box has, which can make a check behave differently there:

- **No secrets.** Ignored files (`.env`, vault files) are not synced and nothing is
  forwarded. If the check fails because it needs a secret, that is a finding to report
  to the user — do not copy the secret over or work around it.
- **No git history.** The folder on the box has a stand-in repository holding one
  snapshot commit, so `git ls-files` works, but a check that reads real history or a
  remote will fail there. Report that too.

- **Nothing built by hand.** The box has only what the command makes. Tests that run
  only when something was built beforehand on the machine — a local Docker image, a
  downloaded browser — are *skipped* there, not failed. So compare the **skipped** count
  with a devbox run, and when it is higher say which tests were skipped and why; the
  remedy is for the project's `LIN_TEST_CMD` to build what its check needs (for anvil:
  `infra/workspace-image.sh && infra/gateway-image.sh` before the check).

**Never** report a check as passed without a run whose `rc=0` you actually saw. If you
couldn't run it, say exactly that and why.
