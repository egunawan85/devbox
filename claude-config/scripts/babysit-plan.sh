#!/usr/bin/env bash
# babysit-plan.sh — the deterministic front half of /babysit-prs.
#
# Does Steps 1-4 of the old prose procedure with zero model attention:
#   1. ensure the three redteam:* labels exist (idempotent)
#   2. enumerate open PRs whose base is TARGET_BRANCH
#   3. apply the skip logic (draft / wip / quiet-period / up-to-date)
#   4. classify each survivor (FIRST_REVIEW | RE_REVIEW), sort, and cap
#
# All state is re-derived from GitHub on every run (PR head SHA, prior marker
# comments, labels), so this is safe to run repeatedly — there is no local state.
#
# Usage:
#   babysit-plan.sh            # full sweep
#   babysit-plan.sh <PR>       # forced single-PR: ignore quiet-period + cap,
#                              # ignore draft/wip/up-to-date skips (still classify)
#
# Output (stdout): a JSON object
#   { "selected": [ <item>, ... ], "deferred": [ <item>, ... ] }
# where <item> = {
#   number, title, class, head_sha, updated_at, merge_state,
#   prior_sha, prior_verdict, pass
# }
# `deferred` = eligible PRs pushed past the per-pass cap (announce, don't drop).
#
# Tunables live here as constants — edit these, not the command prose.
set -euo pipefail

MAX_PRS_PER_PASS=3
QUIET_PERIOD_MINUTES=5
TARGET_BRANCH=main
MARKER_PREFIX='<!-- runegate-redteam'

command -v gh >/dev/null 2>&1 || { echo "babysit-plan: 'gh' not found on PATH" >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "babysit-plan: 'jq' not found on PATH" >&2; exit 127; }

FORCED_PR="${1:-}"

# --- Step 1: ensure labels exist (idempotent; ignore "already exists") ---------
gh label create "redteam:pass"                  --color 0E8A16 --description "Red-team sweep: no concerns" 2>/dev/null || true
gh label create "redteam:pass-with-comments"    --color FBCA04 --description "Red-team sweep: advisory comments posted, fixes optional — mergeable" 2>/dev/null || true
gh label create "redteam:blocked-with-comments" --color B60205 --description "Red-team sweep: do not merge until addressed" 2>/dev/null || true

# Given a PR number on $1, emit the newest redteam marker as JSON
# {sha, verdict, pass} or {} when there is no prior marker.
prior_marker() {
  gh pr view "$1" --json comments --jq '
    [ .comments[]
      | select(.body | contains("'"$MARKER_PREFIX"'"))
    ] | last // {} | .body // ""
  ' | sed -n 's/.*<!-- runegate-redteam sha=\([^ ]*\) verdict=\([^ ]*\) pass=\([0-9]*\) -->.*/{"sha":"\1","verdict":"\2","pass":\3}/p' \
    | grep . || echo '{}'
}

# Classify one PR (passed as a compact JSON object on stdin with at least
# .number and .headRefOid) and print the enriched work-item JSON.
classify_item() {
  local pr_json="$1"
  local number head_sha
  number=$(jq -r '.number' <<<"$pr_json")
  head_sha=$(jq -r '.headRefOid' <<<"$pr_json")
  local marker; marker=$(prior_marker "$number")
  local prior_sha prior_verdict prior_pass class pass
  prior_sha=$(jq -r '.sha // ""' <<<"$marker")
  prior_verdict=$(jq -r '.verdict // ""' <<<"$marker")
  prior_pass=$(jq -r '.pass // 0' <<<"$marker")

  if [[ -z "$prior_sha" ]]; then
    class=FIRST_REVIEW
  elif [[ "$prior_sha" == "$head_sha" ]]; then
    class=UP_TO_DATE
  else
    class=RE_REVIEW
  fi
  pass=$(( prior_pass + 1 ))

  jq -c \
    --arg class "$class" \
    --arg prior_sha "$prior_sha" \
    --arg prior_verdict "$prior_verdict" \
    --argjson pass "$pass" \
    '{
       number, title, class: $class, head_sha: .headRefOid,
       updated_at: .updatedAt, merge_state: .mergeStateStatus,
       prior_sha: $prior_sha, prior_verdict: $prior_verdict, pass: $pass
     }' <<<"$pr_json"
}

# --- Steps 2-3: enumerate + pre-classification skip logic ----------------------
if [[ -n "$FORCED_PR" ]]; then
  # Forced single-PR: skip eligibility filters entirely (still classify).
  raw=$(gh pr view "$FORCED_PR" \
        --json number,title,headRefName,headRefOid,isDraft,mergeable,mergeStateStatus,updatedAt,labels,body)
  candidates=$(jq -c '[.]' <<<"$raw")
else
  raw=$(gh pr list --state open --base "$TARGET_BRANCH" --limit 50 \
        --json number,title,headRefName,headRefOid,isDraft,mergeable,mergeStateStatus,updatedAt,labels,body)
  # Drop drafts, WIP-labelled / WIP-titled, and too-fresh PRs. Time math in jq
  # via `now` so we never shell out to date(1) (GNU/BSD portable).
  candidates=$(jq -c \
    --argjson quiet "$QUIET_PERIOD_MINUTES" '
      [ .[]
        | select(.isDraft | not)
        | select([.labels[].name] | index("wip") | not)
        | select(.title | test("^\\[?WIP") | not)
        | select((now - (.updatedAt | fromdateiso8601)) >= ($quiet * 60))
      ]' <<<"$raw")
fi

# --- Step 3 (cont.) + classify: enrich each candidate, drop UP_TO_DATE ---------
classified='[]'
while read -r pr_json; do
  [[ -z "$pr_json" ]] && continue
  item=$(classify_item "$pr_json")
  [[ "$(jq -r '.class' <<<"$item")" == "UP_TO_DATE" ]] && continue
  classified=$(jq -c --argjson it "$item" '. + [$it]' <<<"$classified")
done < <(jq -c '.[]' <<<"$candidates")

# --- Step 4: sort (RE_REVIEW first, then FIRST_REVIEW oldest-first) + cap -------
if [[ -n "$FORCED_PR" ]]; then
  # Forced mode: no cap, no deferral.
  jq -c '{selected: ., deferred: []}' <<<"$classified"
else
  jq -c --argjson cap "$MAX_PRS_PER_PASS" '
    ( sort_by(
        (if .class == "RE_REVIEW" then 0 else 1 end),
        .updated_at
      )
    ) as $ordered
    | { selected: $ordered[:$cap], deferred: $ordered[$cap:] }
  ' <<<"$classified"
fi
