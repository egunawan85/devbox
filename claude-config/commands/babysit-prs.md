---
description: One idempotent red-team sweep over open PRs — review, post verdict comment, label. Never merges.
argument-hint: '[PR number]  (optional — review just that PR, ignoring quiet-period & cap)'
allowed-tools: Bash(gh:*), Bash(git:*), Agent, Read, Grep
---

# /babysit-prs — single red-team sweep

You are running **one pass** of the PR red-team loop for this repo. This whole
command is designed to be safe to run repeatedly: **all state lives in GitHub**
(PR head SHA, your prior verdict comments, labels), so every pass re-derives the
world from scratch. There is no local state file to drift.

## Tunables (edit these constants here, not the logic below)

- `MAX_PRS_PER_PASS = 3` — also the max parallel reviews per pass.
- `QUIET_PERIOD_MINUTES = 5` — skip a PR pushed more recently than this; let it settle.
- `TARGET_BRANCH = main` — only review PRs whose base is this branch.
- Verdict labels: `redteam:pass`, `redteam:pass-with-comments`, `redteam:blocked-with-comments`.
- Marker format (hidden HTML comment, one per verdict comment):
  `<!-- runegate-redteam sha=<HEADSHA> verdict=<pass|pass-with-comments|blocked-with-comments> pass=<N> -->`

## Argument

- `$ARGUMENTS` — if a PR number is given, review **only** that PR and **ignore**
  the quiet-period and the per-pass cap (a forced single-PR review). Otherwise do
  a full sweep.

---

## Step 1 — Ensure labels exist (idempotent)

Run once, ignore "already exists" errors:

```
gh label create "redteam:pass"                 --color 0E8A16 --description "Red-team sweep: no concerns" 2>/dev/null || true
gh label create "redteam:pass-with-comments"   --color FBCA04 --description "Red-team sweep: advisory comments posted, fixes optional — mergeable" 2>/dev/null || true
gh label create "redteam:blocked-with-comments" --color B60205 --description "Red-team sweep: do not merge until addressed" 2>/dev/null || true
```

## Step 2 — Enumerate candidate PRs

```
gh pr list --state open --base main --limit 50 \
  --json number,title,headRefName,headRefOid,isDraft,mergeable,mergeStateStatus,updatedAt,labels,body
```

If `$ARGUMENTS` is a PR number, restrict to that one and skip the eligibility
filters in Step 3 (but still do everything in Steps 4–6).

## Step 3 — Decide which PRs are eligible (the skip logic)

For each PR, **skip** it this pass if any of these hold:

1. `isDraft == true`.
2. It carries a `wip` label, or its title starts with `WIP`/`[WIP]`.
3. Its last push was within `QUIET_PERIOD_MINUTES` — compare `updatedAt` (and,
   if you want precision, the head commit's `committedDate` via
   `gh pr view <N> --json commits`) against now. If too fresh, skip; it'll be
   picked up next pass.

For PRs that survive those, classify by comparing the **current** `headRefOid`
to the SHA in your most recent marker comment:

- Find your prior verdict: `gh pr view <N> --json comments` → newest comment
  whose body contains `<!-- runegate-redteam ...`. Parse its `sha` and `pass`.
- **No marker** → `FIRST_REVIEW`.
- **Marker sha == headRefOid** → `UP_TO_DATE` → skip (nothing changed).
- **Marker sha != headRefOid** → `RE_REVIEW` (fixes arrived since you last looked).

## Step 4 — Order and cap

Build the work list, then **sort**: all `RE_REVIEW` PRs first (contributors are
waiting on your follow-up), then `FIRST_REVIEW` oldest-`updatedAt`-first. Take
the first `MAX_PRS_PER_PASS`. Announce what you're reviewing and what you're
deferring to the next pass (so a capped sweep never silently drops PRs).

## Step 5 — Review each selected PR (parallel subagents)

For each selected PR, spawn a subagent (one per PR, in a single message so they
run concurrently). Give each agent this self-contained brief:

> Red-team PR #`<N>` of the Runegate repo (a post-breach C# .NET crypto-payments
> platform under active security audit — see `CLAUDE.md` and `audit/`).
>
> 1. Capture the head SHA you are reviewing: `gh pr view <N> --json headRefOid`.
> 2. Read the PR: `gh pr view <N>` (title + description) and the full diff:
>    `gh pr diff <N>`. For context, read changed files in the working tree as needed.
> 3. Apply this rubric and return a structured verdict — **do NOT post anything
>    to GitHub, do NOT merge, do NOT modify files.** Just return your findings.
>
> **Rubric:**
>
> - **Security concerns** — auth/authz, webhooks, money flow, oracle/pricing,
>   crypto, IDOR, injection, secret handling, exception/info leak. Cross-check
>   against the audit conventions (does it touch a known F-NNNN surface? does it
>   reintroduce anything a `scripts/guards/G-*.rule` forbids?). Flag concrete,
>   line-referenced issues — not vibes.
> - **Summary-vs-code** — does the PR description honestly and completely describe
>   what the diff actually does? Call out anything the diff does that the summary
>   omits, understates, or misstates (especially scope creep into sensitive areas).
> - **For a re-review** (you'll be told the prior verdict and SHA): focus on the
>   delta since that SHA (`gh pr diff <N>` vs the prior head) and state, per prior
>   concern, whether it is **addressed / partially addressed / still open / regressed**.
>
> **Return exactly:**
>
> - `verdict`: one of `pass` / `pass-with-comments` / `blocked-with-comments`
>   (`pass` = no concerns, mergeable; `pass-with-comments` = mergeable, advisory
>   non-blocking notes, fixes optional; `blocked-with-comments` = do not merge
>   until addressed).
> - `reviewed_sha`: the head SHA you reviewed.
> - `bottom_line`: 2–4 sentences, conclusion-first (BLUF) — mergeable-or-not, the
>   net security risk in one phrase, and the single most important actionable item
>   stated as advisory-or-blocking. Write it so the orchestrator can drop it in
>   verbatim as the lead, without re-deriving it from the detail bullets below.
> - `summary_match`: 2–4 sentences on summary-vs-code.
> - `security`: bullet findings (or "no concerns found").
> - `rereview_notes`: per-prior-concern status (only if this was a re-review).

When spawning a `RE_REVIEW` agent, include the prior verdict text and prior SHA
in its brief so it can diff forward and grade each earlier concern.

## Step 6 — Post the verdict (with a stale-review guard)

For each completed review, **before posting**, re-fetch the head SHA:
`gh pr view <N> --json headRefOid`.

- If it **differs** from the `reviewed_sha` the agent returned, the author pushed
  mid-review → **discard this verdict, do not post it.** Note that PR will be
  re-picked next pass (the SHA mismatch guarantees it). Log this; don't post stale.
- If it **matches**, post the comment and apply the label:

Comment body (fill in; keep the marker line last and exact):

```
## 🛡️ Red-team verdict: <PASS | PASS WITH COMMENTS | BLOCKED WITH COMMENTS>

**Reviewed:** `<short-sha>` · **Merge conflicts:** <none | ⚠️ CONFLICT — mergeStateStatus=<...>>

> **Bottom line:** <bottom_line — 2–4 sentences, conclusion-first: mergeable-or-not, the net security risk in one phrase, and the single most important actionable item stated as advisory-or-blocking. This leads, before any section below.>

<sub>"Merge conflicts" is a Git mechanical state only — it is **not** a security signal. The security judgment is the verdict above + the findings below.</sub>

### The one fix to make
<Only when there is a concrete action: the specific change, where, and a one-line "why." Use "### What to address" if there is more than one. Omit this whole section entirely on a clean pass.>

### Full findings (for the record)

**Summary vs. code**
<summary_match>

**Security review**
<security findings, or "No concerns found.">

<**Re-review (pass #<n>)**  — only when RE_REVIEW
<per-prior-concern: addressed / partial / open / regressed>>

---
<sub>Automated red-team pass #<N>. **Not a merge approval** — the merge decision is manual. Reply or push fixes and the next sweep will re-review.</sub>
<!-- runegate-redteam sha=<headRefOid> verdict=<pass|pass-with-comments|blocked-with-comments> pass=<N> -->
```

Post with: `gh pr comment <N> --body-file <tmpfile>` (use a temp file to preserve
formatting). Then set the label, removing the other two redteam labels:

```
gh pr edit <N> --add-label "redteam:<verdict>" \
  --remove-label "redteam:<other1>" --remove-label "redteam:<other2>" 2>/dev/null || \
gh pr edit <N> --add-label "redteam:<verdict>"
```

Increment `pass` = prior pass + 1 (or 1 for a first review).

## Step 7 — Report

Print a compact table of what you did this pass: PR # · classification ·
verdict · conflicts(none/CONFLICT) · posted/skipped(stale)/deferred. **Never** run
`gh pr merge`, `git merge`, or push. Merge stays with the human.
