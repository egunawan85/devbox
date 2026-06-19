---
description: One idempotent red-team sweep over open PRs — review, post verdict comment, label. Never merges.
argument-hint: '[PR number]  (optional — review just that PR, ignoring quiet-period & cap)'
allowed-tools: Bash(~/.claude/scripts/babysit-plan.sh:*), Bash(~/.claude/scripts/babysit-post.sh:*), Bash(gh:*), Bash(git:*), Agent, Read
---

# /babysit-prs — single red-team sweep (dispatcher)

You run **one pass** of the PR red-team loop. It is safe to run repeatedly: all
state lives in GitHub (PR head SHA, your prior verdict comments, labels), so every
pass re-derives the world from scratch — there is no local state.

The deterministic plumbing lives in two scripts so your attention stays on
dispatching reviews, not on emulating shell:

- `~/.claude/scripts/babysit-plan.sh` — labels, enumerate, skip logic, classify,
  sort, cap. Tunables (`MAX_PRS_PER_PASS`, `QUIET_PERIOD_MINUTES`, `TARGET_BRANCH`,
  marker format) are constants **inside that script** — edit them there.
- `~/.claude/scripts/babysit-post.sh` — stale-guard, render the verdict comment,
  post it, swap the `redteam:*` label, print one report row.

The red-team rubric is `~/.claude/scripts/redteam-brief.md`; the review subagents
read it themselves, so it is not inlined here.

## Step 1 — Plan

Run `~/.claude/scripts/babysit-plan.sh $ARGUMENTS` (pass the PR number through if
given). It prints `{ "selected": [...], "deferred": [...] }`. If `selected` is
empty, report "nothing eligible this pass" (mention any `deferred`) and stop.

Each selected item has: `number`, `title`, `class` (`FIRST_REVIEW`|`RE_REVIEW`),
`head_sha`, `merge_state`, `prior_sha`, `prior_verdict`, `pass`.

## Step 2 — Review each selected PR (parallel subagents)

Spawn one subagent per selected PR, **all in a single message** so they run
concurrently. Give each this brief (fill in the per-PR values from the item):

> Red-team PR #`<number>` of the Runegate repo.
> Parameters: `class=<class>`. If `RE_REVIEW`, also `prior_sha=<prior_sha>`,
> `prior_verdict=<prior_verdict>`.
> Read `~/.claude/scripts/redteam-brief.md` and follow it exactly. Write your
> verdict JSON to `<out>`, where `<out>` is a fresh temp path you create
> (e.g. `mktemp`). Return that path as your final message.

Do **not** re-derive the rubric or the output schema here — the brief owns both.

## Step 3 — Post each verdict

For each subagent that returned a verdict-file path, run:

`~/.claude/scripts/babysit-post.sh <number> <verdict-file>`

The script re-fetches the head SHA and **discards the verdict if the author pushed
mid-review** (it prints a `STALE (discarded)` row; that PR is re-picked next pass
because the SHA will still mismatch). On a match it posts the comment, swaps the
label, and prints a `posted` row. Collect each script's one-line row.

## Step 4 — Report

Print a compact table from the rows the post script emitted, plus a line per
`deferred` PR (`deferred to next pass`). Columns: PR # · class · verdict ·
conflicts · outcome.

**Never** run `gh pr merge`, `git merge`, or push. The merge decision stays with
the human.
