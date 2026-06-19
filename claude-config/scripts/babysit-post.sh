#!/usr/bin/env bash
# babysit-post.sh — the deterministic back half of /babysit-prs (Step 6).
#
# Takes one subagent's structured verdict and publishes it, re-deriving the
# world from GitHub so it is correct no matter how stale the caller's view is:
#   - re-fetch the head SHA and STALE-GUARD against the reviewed SHA
#   - re-fetch mergeStateStatus for the conflict line
#   - recompute the pass number from the newest prior marker
#   - render the verdict comment + post it + swap the redteam:* label
#
# Usage:
#   babysit-post.sh <PR> <verdict.json>
#
# <verdict.json> is exactly what the red-team subagent returns (see
# redteam-brief.md):
#   {
#     "verdict": "pass|pass-with-comments|blocked-with-comments",
#     "reviewed_sha": "<full sha the agent reviewed>",
#     "bottom_line": "...",
#     "summary_match": "...",
#     "security": "markdown bullets, or 'No concerns found.'",
#     "fixes": ["...", ...],            # [] => omit the fix section (clean pass)
#     "rereview_notes": "..."           # "" / absent unless this was a re-review
#   }
#
# Prints ONE report row to stdout for Step 7:
#   PR <N> | <class> | <verdict> | <none|CONFLICT> | <posted|STALE (discarded)>
set -euo pipefail

MARKER_PREFIX='<!-- runegate-redteam'

command -v gh >/dev/null 2>&1 || { echo "babysit-post: 'gh' not found on PATH" >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "babysit-post: 'jq' not found on PATH" >&2; exit 127; }

PR="${1:?usage: babysit-post.sh <PR> <verdict.json>}"
VERDICT_FILE="${2:?usage: babysit-post.sh <PR> <verdict.json>}"
[[ -r "$VERDICT_FILE" ]] || { echo "babysit-post: cannot read $VERDICT_FILE" >&2; exit 2; }

v() { jq -r "$1 // \"\"" "$VERDICT_FILE"; }

verdict=$(v '.verdict')
reviewed_sha=$(v '.reviewed_sha')
case "$verdict" in
  pass|pass-with-comments|blocked-with-comments) ;;
  *) echo "babysit-post: bad verdict '$verdict' in $VERDICT_FILE" >&2; exit 2;;
esac

# --- newest prior marker (for class + pass number) -----------------------------
marker=$(gh pr view "$PR" --json comments --jq '
    [ .comments[] | select(.body | contains("'"$MARKER_PREFIX"'")) ] | last // {} | .body // ""
  ' | sed -n 's/.*<!-- runegate-redteam sha=\([^ ]*\) verdict=\([^ ]*\) pass=\([0-9]*\) -->.*/{"sha":"\1","verdict":"\2","pass":\3}/p' \
  | grep . || echo '{}')
prior_sha=$(jq -r '.sha // ""'  <<<"$marker")
prior_pass=$(jq -r '.pass // 0' <<<"$marker")
if [[ -z "$prior_sha" ]]; then class=FIRST_REVIEW; else class=RE_REVIEW; fi
pass=$(( prior_pass + 1 ))

# --- STALE GUARD: re-fetch head SHA; discard if author pushed mid-review --------
current_sha=$(gh pr view "$PR" --json headRefOid --jq '.headRefOid')
if [[ "$current_sha" != "$reviewed_sha" ]]; then
  printf 'PR %s | %s | %s | - | STALE (discarded — head moved %s→%s, re-picked next pass)\n' \
    "$PR" "$class" "$verdict" "${reviewed_sha:0:7}" "${current_sha:0:7}"
  exit 0
fi

# --- conflict line (mechanical git state only, NOT a security signal) -----------
merge_state=$(gh pr view "$PR" --json mergeStateStatus --jq '.mergeStateStatus')
if [[ "$merge_state" == "DIRTY" ]]; then
  conflicts="⚠️ CONFLICT — mergeStateStatus=$merge_state"
  conflict_col="CONFLICT"
else
  conflicts="none"
  conflict_col="none"
fi

# --- verdict display name ------------------------------------------------------
case "$verdict" in
  pass)                   verdict_title="PASS";;
  pass-with-comments)     verdict_title="PASS WITH COMMENTS";;
  blocked-with-comments)  verdict_title="BLOCKED WITH COMMENTS";;
esac

# --- fix section: 0 => omit, 1 => "the one fix", >1 => "what to address" --------
fix_count=$(jq '.fixes | if . == null then 0 else length end' "$VERDICT_FILE")
fix_section=""
if [[ "$fix_count" == "1" ]]; then
  fix_section=$'### The one fix to make\n'"$(jq -r '.fixes[0]' "$VERDICT_FILE")"$'\n'
elif [[ "$fix_count" -gt 1 ]]; then
  fix_section=$'### What to address\n'"$(jq -r '.fixes[] | "- " + .' "$VERDICT_FILE")"$'\n'
fi

# --- re-review section (only when a prior marker existed) ----------------------
rereview_notes=$(v '.rereview_notes')
rereview_section=""
if [[ "$class" == "RE_REVIEW" && -n "$rereview_notes" ]]; then
  rereview_section=$'\n**Re-review (pass #'"$pass"$')**\n'"$rereview_notes"$'\n'
fi

bottom_line=$(v '.bottom_line')
summary_match=$(v '.summary_match')
security=$(v '.security')
[[ -z "$security" ]] && security="No concerns found."

# --- render + post -------------------------------------------------------------
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
cat >"$body_file" <<EOF
## 🛡️ Red-team verdict: ${verdict_title}

**Reviewed:** \`${reviewed_sha:0:7}\` · **Merge conflicts:** ${conflicts}

> **Bottom line:** ${bottom_line}

<sub>"Merge conflicts" is a Git mechanical state only — it is **not** a security signal. The security judgment is the verdict above + the findings below.</sub>

${fix_section}
### Full findings (for the record)

**Summary vs. code**
${summary_match}

**Security review**
${security}
${rereview_section}
---
<sub>Automated red-team pass #${pass}. **Not a merge approval** — the merge decision is manual. Reply or push fixes and the next sweep will re-review.</sub>
<!-- runegate-redteam sha=${reviewed_sha} verdict=${verdict} pass=${pass} -->
EOF

gh pr comment "$PR" --body-file "$body_file"

# --- swap label: add this verdict, remove the other two ------------------------
all=(redteam:pass redteam:pass-with-comments redteam:blocked-with-comments)
add="redteam:$verdict"
rm_args=()
for l in "${all[@]}"; do [[ "$l" != "$add" ]] && rm_args+=(--remove-label "$l"); done
gh pr edit "$PR" --add-label "$add" "${rm_args[@]}" 2>/dev/null \
  || gh pr edit "$PR" --add-label "$add"

printf 'PR %s | %s | %s | %s | posted (pass #%s)\n' \
  "$PR" "$class" "$verdict" "$conflict_col" "$pass"
