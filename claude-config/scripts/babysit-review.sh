#!/usr/bin/env bash
# babysit-review.sh — run ONE focused red-team review of a PR via `claude -p`.
#
# This is the deliberate split that lets the review session focus purely on
# reviewing: it owns the `claude -p` invocation, prompt assembly, and the
# reviewed-SHA capture, so none of that orchestration leaks into the prompt
# (redteam-brief.md) or the /babysit-prs command prose.
#
# The prompt template is redteam-brief.md (symlinked alongside this script in
# ~/.claude/scripts). Placeholders {{PR}} / {{PRIOR_VERDICT}} / {{PRIOR_SHA}}
# are filled here; the {{#RE_REVIEW}}…{{/RE_REVIEW}} block is kept only on a
# re-review (so the session grades each prior concern for closure) and stripped
# otherwise.
#
# The review runs read-only — `claude -p` is given gh/git/Read/Grep/Glob and
# nothing that can write, so it cannot post, merge, or modify files. The
# orchestrator (babysit-post.sh) does all the publishing.
#
# Usage:
#   babysit-review.sh <PR> <class> [prior_verdict] [prior_sha]
#     <class> = FIRST_REVIEW | RE_REVIEW   (prior_* required only for RE_REVIEW)
#
# Output (stdout): one JSON object
#   { "reviewed_sha": "<full head sha reviewed>", "review_file": "<path>" }
# where <review_file> holds the review prose (ending in a `VERDICT:` line).
set -euo pipefail

# Read-only toolset: enough to read the PR, diff, and repo context — nothing
# that can mutate GitHub or the working tree.
ALLOWED_TOOLS='Bash(gh:*),Bash(git:*),Read,Grep,Glob'
# MODEL=opus   # uncomment to pin a specific model for reviews

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BRIEF="$SCRIPT_DIR/redteam-brief.md"

command -v claude >/dev/null 2>&1 || { echo "babysit-review: 'claude' not found on PATH" >&2; exit 127; }
command -v gh    >/dev/null 2>&1 || { echo "babysit-review: 'gh' not found on PATH" >&2; exit 127; }
command -v jq    >/dev/null 2>&1 || { echo "babysit-review: 'jq' not found on PATH" >&2; exit 127; }
[[ -r "$BRIEF" ]] || { echo "babysit-review: cannot read $BRIEF" >&2; exit 2; }

PR="${1:?usage: babysit-review.sh <PR> <class> [prior_verdict] [prior_sha]}"
CLASS="${2:?usage: babysit-review.sh <PR> <class> [prior_verdict] [prior_sha]}"
PRIOR_VERDICT="${3:-}"
PRIOR_SHA="${4:-}"

# The SHA the review will see. Captured now, just before the session starts;
# babysit-post.sh re-fetches and stale-guards against it, so a push that lands
# mid-review is caught there and the PR is re-picked next pass.
reviewed_sha=$(gh pr view "$PR" --json headRefOid --jq '.headRefOid')

# --- assemble the prompt from the brief ----------------------------------------
# awk strips the {{#RE_REVIEW}}/{{/RE_REVIEW}} delimiter lines always, and drops
# the block's body unless this is a RE_REVIEW.
keep_rr=0; [[ "$CLASS" == "RE_REVIEW" ]] && keep_rr=1
prompt=$(awk -v keep="$keep_rr" '
  /\{\{#RE_REVIEW\}\}/  { inrr=1; next }
  /\{\{\/RE_REVIEW\}\}/ { inrr=0; next }
  inrr && keep != "1"   { next }
  { print }
' "$BRIEF")

# Fill placeholders (plain substitution — values are a PR number, a verdict
# keyword, and a hex SHA, so no regex/escaping concerns).
prompt=${prompt//\{\{PR\}\}/$PR}
prompt=${prompt//\{\{PRIOR_VERDICT\}\}/$PRIOR_VERDICT}
prompt=${prompt//\{\{PRIOR_SHA\}\}/$PRIOR_SHA}

# --- run the review ------------------------------------------------------------
review_file=$(mktemp)
claude -p "$prompt" \
  --allowedTools "$ALLOWED_TOOLS" \
  ${MODEL:+--model "$MODEL"} \
  >"$review_file"

jq -cn --arg s "$reviewed_sha" --arg f "$review_file" \
  '{reviewed_sha: $s, review_file: $f}'
