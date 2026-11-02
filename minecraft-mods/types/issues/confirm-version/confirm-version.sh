#!/usr/bin/env bash
# Applies versions/<mc> labels when a collaborator comments "Confirmed in <version>[, <version>]".
#
# Collaborators only: the association comes from the event payload, so a stranger's comment costs no
# API call and produces nothing at all - no reply, no label, no failure.
#
# A version with no <version>/development branch is skipped rather than labelled: the label names a
# version line, and a line that does not exist has nothing to be fixed on. The skip is recorded in
# the step summary (CI said something actionable, so no comment is added to the issue).
set -euo pipefail

: "${REPO:?}" "${ISSUE_NUMBER:?}" "${COMMENT_BODY-}"
CONFIRM_PREFIX="${CONFIRM_PREFIX:-Confirmed in }"
ALLOWED_ASSOCIATIONS="${ALLOWED_ASSOCIATIONS:-OWNER, MEMBER, COLLABORATOR}"
VERSION_RE='^[0-9]+(\.[0-9]+){1,2}$'
CLEAR_LABEL="${CLEAR_LABEL-unaddressed}"

applied=''
skipped=''

emit() {
  {
    echo "versions=${applied}"
    echo "skipped=${skipped}"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
}

# Comma-delimited, spaces stripped: a pattern written with spaces can never match the stripped list,
# which is exactly the bug this shape avoids.
if [[ ",${ALLOWED_ASSOCIATIONS// /}," != *",${AUTHOR_ASSOCIATION-},"* ]]; then
  echo "${AUTHOR_ASSOCIATION:-NONE} may not confirm a version; ignoring the comment"
  emit
  exit 0
fi

first_line=$(sed -n '1p' <<<"$COMMENT_BODY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
line_lower=$(tr '[:upper:]' '[:lower:]' <<<"$first_line")
prefix_lower=$(tr '[:upper:]' '[:lower:]' <<<"$CONFIRM_PREFIX")
if [[ "$line_lower" != "$prefix_lower"* ]]; then
  echo "comment does not start with '$CONFIRM_PREFIX'; ignoring it"
  emit
  exit 0
fi
list="${first_line:${#CONFIRM_PREFIX}}"

issue=$(gh api "repos/$REPO/issues/$ISSUE_NUMBER") || {
  echo "::error::cannot read $REPO#$ISSUE_NUMBER"
  exit 1
}
if jq -e 'has("pull_request")' <<<"$issue" > /dev/null; then
  echo "$REPO#$ISSUE_NUMBER is a pull request; confirmations apply to issues"
  emit
  exit 0
fi
if [[ "$(jq -r '.state // ""' <<<"$issue")" != 'open' ]]; then
  echo "$REPO#$ISSUE_NUMBER is not open; nothing to label"
  emit
  exit 0
fi

requested=()
while IFS= read -r token; do
  [[ -n "$token" ]] && requested+=("$token")
done < <(tr ',' '\n' <<<"$list" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if (( ${#requested[@]} == 0 )); then
  echo "comment names no version; nothing to do"
  emit
  exit 0
fi

if [[ -n "${VERSIONS-}" ]]; then
  known=$(tr ',' '\n' <<<"$VERSIONS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | awk 'NF && !seen[$0]++' | sort)
else
  known=$(gh api "repos/$REPO/branches?per_page=100" --paginate --jq '.[].name' \
    | sed -n 's#^\(.\+\)/development$#\1#p' | grep -E "$VERSION_RE" | sort -u || true)
fi
if [[ -z "$known" ]]; then
  echo "::error::$REPO has no <version>/development branch and no versions input was given"
  exit 1
fi

for version in "${requested[@]}"; do
  [[ "$version" =~ $VERSION_RE ]] || {
    skipped="$skipped $version"
    continue
  }
  if ! grep -qxF -- "$version" <<<"$known"; then
    skipped="$skipped $version"
    continue
  fi
  gh label create "versions/$version" --repo "$REPO" --color 1D76DB \
    --description "Affects Minecraft $version" --force > /dev/null
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "versions/$version" > /dev/null
  applied="$applied $version"
done

applied="${applied# }"
skipped="${skipped# }"

if [[ -n "$applied" && -n "$CLEAR_LABEL" ]]; then
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "$CLEAR_LABEL" > /dev/null 2>&1 || true
fi

echo "#$ISSUE_NUMBER confirmed on ${applied:-nothing}${skipped:+ (skipped: $skipped)}"
{
  echo "### Confirmed versions"
  echo
  if [[ -n "$applied" ]]; then
    echo "Applied: ${applied}"
  else
    echo "Applied: none"
  fi
  if [[ -n "$skipped" ]]; then
    echo
    echo "Skipped (no \`<version>/development\` branch): ${skipped}"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
emit
