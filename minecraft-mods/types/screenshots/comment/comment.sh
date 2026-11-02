#!/usr/bin/env bash
# Writes the mismatch table as one comment, updating it in place on later runs.
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${PR:?}" "${LIST_FILE:?}"

entries=0
if [[ -f "$LIST_FILE" ]]; then
  entries=$(wc -l < "$LIST_FILE" | tr -d ' ')
fi
if [[ "$entries" -eq 0 ]]; then
  echo "No screenshot mismatches to report."
  exit 0
fi

scope=""
if [[ -n "${LOADER:-}" ]]; then
  scope=" for \`$LOADER\`"
fi

body_file="$(mktemp)"
{
  echo "$MARKER"
  echo "### Screenshot mismatches$scope"
  echo
  echo "These captures differ from \`tests/baselines\`. Added and changed ones are regenerated in the"
  echo "post-merge chore commit; a \`deleted\` entry means the capture no longer exists."
  echo
  echo "| Capture | State |"
  echo "| --- | --- |"
  jq -r '"| `" + .capture + "` | " + .state + " |"' "$LIST_FILE"
} > "$body_file"

existing=$(gh api "repos/$REPO/issues/$PR/comments?per_page=100" \
  --jq ".[] | select(.body | contains(\"$MARKER\")) | .id" | head -1)

if [[ -n "$existing" ]]; then
  gh api -X PATCH "repos/$REPO/issues/comments/$existing" -F body=@"$body_file" > /dev/null
  echo "Updated comment $existing with $entries mismatch(es)"
else
  gh api -X POST "repos/$REPO/issues/$PR/comments" -F body=@"$body_file" > /dev/null
  echo "Created a comment with $entries mismatch(es)"
fi
