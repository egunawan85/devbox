#!/usr/bin/env bash
# babysit-post.sh — the deterministic back half of /babysit-prs.
#
# Takes one red-team review (free-form prose ending in a `VERDICT:` line, as
# produced by babysit-review.sh / claude -p) and publishes it, re-deriving the
# world from GitHub so it is correct no matter how stale the caller's view is:
#   - parse the trailing VERDICT line (drives the label + report row)
#   - re-fetch the head SHA and STALE-GUARD against the reviewed SHA
#   - re-fetch mergeStateStatus for the conflict line
#   - recompute the pass number from the newest prior marker
#   - render a small verdict header + the review prose verbatim, post it,
#     and swap the redteam:* label
#
# Usage:
#   babysit-post.sh <PR> <reviewed_sha> <review-file>
#
# <review-file> is the prose the review session wrote. Its LAST line matching
#   VERDICT: <pass|pass-with-comments|blocked-with-comments>
# sets the verdict; that line is stripped from the posted body. Everything else
# is posted as-is.
#
# Prints ONE report row to stdout for the final report:
#   PR <N> | <class> | <verdict> | <none|CONFLICT> | <posted|STALE (discarded)>
set -euo pipefail

MARKER_PREFIX='<!-- runegate-redteam'

command -v gh >/dev/null 2>&1 || { echo "babysit-post: 'gh' not found on PATH" >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "babysit-post: 'jq' not found on PATH" >&2; exit 127; }

PR="${1:?usage: babysit-post.sh <PR> <reviewed_sha> <review-file>}"
reviewed_sha="${2:?usage: babysit-post.sh <PR> <reviewed_sha> <review-file>}"
REVIEW_FILE="${3:?usage: babysit-post.sh <PR> <reviewed_sha> <review-file>}"
[[ -r "$REVIEW_FILE" ]] || { echo "babysit-post: cannot read $REVIEW_FILE" >&2; exit 2; }

# --- parse the verdict from the trailing VERDICT line --------------------------
# Take the LAST VERDICT: line; leftmost-longest match picks the full keyword
# even though "pass" is a prefix of "pass-with-comments".
verdict=$(grep -iE '^[[:space:]]*VERDICT:' "$REVIEW_FILE" | tail -n1 \
  | tr -d '`' | tr 'A-Z' 'a-z' \
  | grep -oE 'pass-with-comments|blocked-with-comments|pass' | head -n1 || true)
case "$verdict" in
  pass|pass-with-comments|blocked-with-comments) ;;
  *) echo "babysit-post: no valid VERDICT line in $REVIEW_FILE" >&2; exit 2;;
esac

# Body = the review prose with the VERDICT line(s) removed and trailing blank
# lines trimmed. One awk pass (portable on BSD/macOS + GNU; always exits 0).
body=$(awk '
  tolower($0) ~ /^[[:space:]]*verdict:/ { next }
  { l[++n] = $0 }
  END { e = n; while (e > 0 && l[e] ~ /^[ \t]*$/) e--; for (i = 1; i <= e; i++) print l[i] }
' "$REVIEW_FILE")

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

# --- render + post -------------------------------------------------------------
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
cat >"$body_file" <<EOF
## 🛡️ Red-team verdict: ${verdict_title}

**Reviewed:** \`${reviewed_sha:0:7}\` · **Merge conflicts:** ${conflicts}

<sub>"Merge conflicts" is a Git mechanical state only — it is **not** a security signal. The security judgment is the verdict above + the findings below.</sub>

${body}

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
