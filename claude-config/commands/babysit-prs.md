---
description: One idempotent red-team sweep over open PRs — review, post verdict comment, label. Never merges.
argument-hint: '[PR number]  (optional — review just that PR, ignoring quiet-period & cap)'
allowed-tools: Bash(~/.claude/scripts/babysit-plan.sh:*), Bash(~/.claude/scripts/babysit-review.sh:*), Bash(~/.claude/scripts/babysit-post.sh:*), Bash(gh:*), Bash(git:*), Bash(jq:*), Read
---

# /babysit-prs — single red-team sweep (dispatcher)

> **POSIX shell only.** The three `scripts/babysit-*.sh` helpers are bash and
> need `jq`, `awk`, and `claude -p` on the PATH, so this command runs on
> macOS/Linux only — not on the Windows devbox (no bash/jq there). It reviews
> PRs over the GitHub API, so run it from a POSIX host; it never needs to run on
> the box itself.

You run **one pass** of the PR red-team loop. It is safe to run repeatedly: all
state lives in GitHub (PR head SHA, your prior verdict comments, labels), so every
pass re-derives the world from scratch — there is no local state.

The deterministic plumbing lives in three scripts so your attention stays on
dispatching reviews, not on emulating shell:

- `~/.claude/scripts/babysit-plan.sh` — labels, enumerate, skip logic, classify,
  sort, cap. Tunables (`MAX_PRS_PER_PASS`, `QUIET_PERIOD_MINUTES`, `TARGET_BRANCH`,
  marker format) are constants **inside that script** — edit them there.
- `~/.claude/scripts/babysit-review.sh` — run ONE red-team review of a PR via a
  fresh, read-only `claude -p` session, and return the reviewed SHA + the review
  file. Tunables (`ALLOWED_TOOLS`, `MODEL`) are constants inside that script.
- `~/.claude/scripts/babysit-post.sh` — stale-guard, render the verdict comment,
  post it, swap the `redteam:*` label, print one report row.

Each review runs in its **own** `claude -p` session (not an in-process subagent),
so it gets a full, independent context window focused purely on the review. The
prompt that session receives is `~/.claude/scripts/redteam-brief.md` — kept
deliberately succinct, with all orchestration (which PRs, SHAs, posting, labels)
held here and in the scripts, never in the prompt.

## Step 1 — Plan

Run `~/.claude/scripts/babysit-plan.sh $ARGUMENTS` (pass the PR number through if
given). It prints `{ "selected": [...], "deferred": [...] }`. If `selected` is
empty, report "nothing eligible this pass" (mention any `deferred`) and stop.

Each selected item has: `number`, `title`, `class` (`FIRST_REVIEW`|`RE_REVIEW`),
`head_sha`, `merge_state`, `prior_sha`, `prior_verdict`, `pass`.

## Step 2 — Review each selected PR (parallel `claude -p` sessions)

Run `babysit-review.sh` once per selected PR, **all in a single message** so the
review sessions run concurrently:

`~/.claude/scripts/babysit-review.sh <number> <class> <prior_verdict> <prior_sha>`

Pass `prior_verdict` and `prior_sha` from the item (they are `""` for a
`FIRST_REVIEW` — harmless to pass empty). Each invocation prints one JSON line:

`{ "reviewed_sha": "<sha>", "review_file": "<path>" }`

Collect each PR's `reviewed_sha` and `review_file`. Do **not** read or re-derive
the rubric or the verdict here — the brief owns the prompt and the review session
owns the judgment.

## Step 3 — Post each verdict

For each reviewed PR, run:

`~/.claude/scripts/babysit-post.sh <number> <reviewed_sha> <review_file>`

The script parses the review's trailing `VERDICT:` line, re-fetches the head SHA,
and **discards the verdict if the author pushed mid-review** (it prints a
`STALE (discarded)` row; that PR is re-picked next pass because the SHA will still
mismatch). On a match it posts the comment, swaps the label, and prints a `posted`
row. Collect each script's one-line row.

## Step 4 — Report

Print a compact table from the rows the post script emitted, plus a line per
`deferred` PR (`deferred to next pass`). Columns: PR # · class · verdict ·
conflicts · outcome.

**Never** run `gh pr merge`, `git merge`, or push. The merge decision stays with
the human.
