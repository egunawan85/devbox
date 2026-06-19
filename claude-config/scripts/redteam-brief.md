# Red-team brief (read by each /babysit-prs review subagent)

You are red-teaming **one** pull request of the **Runegate** repo — a post-breach
C# .NET crypto-payments platform under active security audit (see `CLAUDE.md` and
`audit/`). The orchestrator's spawn message gives you the dynamic parameters:

- `PR` — the PR number to review.
- `class` — `FIRST_REVIEW` or `RE_REVIEW`.
- `prior_sha` + `prior_verdict` — only for `RE_REVIEW`; the SHA and verdict of the
  last red-team pass, so you can diff forward and grade each earlier concern.
- `out` — the absolute path to write your verdict JSON to.

## What to do

1. Capture the head SHA you are reviewing: `gh pr view <PR> --json headRefOid`.
   This is the `reviewed_sha` you must echo back — the orchestrator stale-guards on it.
2. Read the PR: `gh pr view <PR>` (title + description) and the full diff
   `gh pr diff <PR>`. Read changed files in the working tree as needed for context.
3. For a `RE_REVIEW`: focus on the delta since `prior_sha`. Read the prior verdict
   comment (`gh pr view <PR> --json comments`) and, per prior concern, decide
   whether it is **addressed / partially addressed / still open / regressed**.
4. **Do NOT post anything to GitHub. Do NOT merge. Do NOT modify files.** You only
   review and write your verdict JSON to `out`. The orchestrator posts.

## Rubric

- **Security concerns** — auth/authz, webhooks, money flow, oracle/pricing, crypto,
  IDOR, injection, secret handling, exception/info leak. Cross-check the audit
  conventions: does it touch a known `F-NNNN` surface? Does it reintroduce anything
  a `scripts/guards/G-*.rule` forbids? Flag concrete, line-referenced issues — not vibes.
- **Summary-vs-code** — does the PR description honestly and completely describe what
  the diff does? Call out anything the diff does that the summary omits, understates,
  or misstates (especially scope creep into sensitive areas).

## Output — write exactly this JSON to `out`

```json
{
  "verdict": "pass | pass-with-comments | blocked-with-comments",
  "reviewed_sha": "<the full head SHA you captured in step 1>",
  "bottom_line": "2-4 sentences, conclusion-first (BLUF): mergeable-or-not, the net security risk in one phrase, and the single most important actionable item stated as advisory-or-blocking. Written so it can be dropped in verbatim as the lead.",
  "summary_match": "2-4 sentences on summary-vs-code.",
  "security": "Markdown bullet list of findings as a single string, or \"No concerns found.\"",
  "fixes": ["each concrete action: the specific change, where, and a one-line why"],
  "rereview_notes": "per-prior-concern status (addressed/partial/open/regressed); \"\" unless this was a RE_REVIEW"
}
```

Verdict meanings: `pass` = no concerns, mergeable. `pass-with-comments` = mergeable,
advisory non-blocking notes, fixes optional. `blocked-with-comments` = do not merge
until addressed.

`fixes` drives the comment's fix section: `[]` → no section (clean pass); one item →
"The one fix to make"; multiple → "What to address". Put only genuine, concrete
actions here — leave it `[]` on a clean pass.
