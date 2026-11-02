#!/usr/bin/env bash
# Validates the issue form's affected-version field and applies the versions/<mc> labels.
#
# The supported set is read from the repository itself - every branch named <version>/development -
# so a shared action can never drift from the lines a consumer actually carries. `versions` overrides
# that when a caller wants the list pinned in a workflow instead.
#
# An issue naming a line that does not exist cannot be worked, so it is commented, closed and
# tagged addressed in the same step. That closure is deliberate, not a failure: the job exits 0.
set -euo pipefail

: "${REPO:?}" "${ISSUE_NUMBER:?}"
FIELD="${FIELD:-Affected Minecraft versions}"
VERSION_RE='^[0-9]+(\.[0-9]+){1,2}$'
MARKER="${MARKER:-<!-- minecheck-version-check -->}"
LABEL_ON_OPEN="${LABEL_ON_OPEN-unaddressed}"

closed=false
labelled=''

fail() {
  echo "::error::$*"
  exit 1
}

issue=$(gh api "repos/$REPO/issues/$ISSUE_NUMBER") || fail "cannot read $REPO#$ISSUE_NUMBER"

if jq -e 'has("pull_request")' <<<"$issue" > /dev/null; then
  echo "$REPO#$ISSUE_NUMBER is a pull request; the version check does not apply"
  exit 0
fi
if [[ "$(jq -r '.state // ""' <<<"$issue")" != 'open' ]]; then
  echo "$REPO#$ISSUE_NUMBER is $(jq -r '.state // "unknown"' <<<"$issue"); nothing to check"
  exit 0
fi

# The tag means "nothing has happened to this issue yet", so it goes on at open and comes off in the
# same step as any comment CI leaves - including the rejection below.
if [[ -n "$LABEL_ON_OPEN" && "${EVENT_ACTION-}" == 'opened' ]]; then
  gh label create "$LABEL_ON_OPEN" --repo "$REPO" --color fbca04 \
    --description 'CI has not commented on this issue yet' --force > /dev/null
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$LABEL_ON_OPEN" > /dev/null
fi

# Upserted by marker: an issue edited twice must not collect a comment per attempt.
post_comment() {
  local body="$1" existing
  body=$(printf '%s\n\n%s' "$MARKER" "$body")
  existing=$(gh api "repos/$REPO/issues/$ISSUE_NUMBER/comments?per_page=100" --paginate \
    --jq --arg m "$MARKER" '.[] | select((.body // "") | contains($m)) | .id' | head -1 || true)
  if [[ -n "$existing" ]]; then
    gh api -X PATCH "repos/$REPO/issues/comments/$existing" -f body="$body" > /dev/null
  else
    gh api -X POST "repos/$REPO/issues/$ISSUE_NUMBER/comments" -f body="$body" > /dev/null
  fi
}

# Read the field once, so every message below names the same heading the form uses.
body_text=$(jq -r '.body // ""' <<<"$issue")
value=$(awk -v want="### $FIELD" '
  BEGIN { target = tolower(want) }
  {
    line = $0
    sub(/^[ \t]+/, "", line)
    sub(/[ \t]+$/, "", line)
    lower = tolower(line)
    if (!inside && lower == target) { inside = 1; next }
    if (inside && substr(line, 1, 4) == "### ") { inside = 0 }
    if (inside) print line
  }
' <<<"$body_text")

requested=()
while IFS= read -r token; do
  [[ -n "$token" ]] && requested+=("$token")
done < <(tr ',' '\n' <<<"$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

if [[ -n "${VERSIONS-}" ]]; then
  known=$(tr ',' '\n' <<<"$VERSIONS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | awk 'NF && !seen[$0]++' | sort)
else
  known=$(gh api "repos/$REPO/branches?per_page=100" --paginate --jq '.[].name' \
    | sed -n 's#^\(.\+\)/development$#\1#p' | grep -E "$VERSION_RE" | sort -u || true)
fi
[[ -n "$known" ]] ||
  fail "$REPO has no <version>/development branch and no versions input was given"

valid_list=$(tr '\n' ',' <<<"$known" | sed 's/,$//; s/,/, /g')

reject() {
  local problem="$1"
  post_comment "$(printf '**This issue was closed by the version check.**\n\n**Reason:** %s\n\nSupported versions: %s\n\nEdit the **%s** field to only list versions that have a `<version>/development` branch, then reopen the issue.' \
    "$problem" "$valid_list" "$FIELD")"
  if [[ -n "$LABEL_ON_OPEN" ]]; then
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "$LABEL_ON_OPEN" > /dev/null 2>&1 || true
  fi
  gh issue close "$ISSUE_NUMBER" --repo "$REPO" --reason 'not planned' > /dev/null
  echo "#$ISSUE_NUMBER closed: $problem"
  {
    echo "closed=true"
    echo "versions="
  } >> "$GITHUB_OUTPUT"
  exit 0
}

if [[ -z "$value" ]]; then
  reject "The issue has no **$FIELD** field."
fi
if (( ${#requested[@]} == 0 )); then
  reject "The **$FIELD** field is empty."
fi

mapfile -t requested < <(printf '%s\n' "${requested[@]}" | awk '!seen[$0]++')

bad=()
for token in "${requested[@]}"; do
  [[ "$token" =~ $VERSION_RE ]] || bad+=("$token")
done
if (( ${#bad[@]} > 0 )); then
  quoted=$(printf '`%s`, ' "${bad[@]}")
  reject "Not a valid Minecraft version list: ${quoted%, }. Use comma-separated versions like \`1.19.2, 1.20.1\`."
fi

unknown=()
for version in "${requested[@]}"; do
  grep -qxF -- "$version" <<<"$known" || unknown+=("$version")
done
if (( ${#unknown[@]} > 0 )); then
  quoted=$(printf '`%s`, ' "${unknown[@]}")
  reject "No \`<version>/development\` branch exists for: ${quoted%, }. Port the version first, or list only supported versions."
fi

for version in "${requested[@]}"; do
  gh label create "versions/$version" --repo "$REPO" --color 1D76DB \
    --description "Affects Minecraft $version" --force > /dev/null
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "versions/$version" > /dev/null
done

labelled="${requested[*]}"
echo "#$ISSUE_NUMBER affects $labelled"
{
  echo "versions=$labelled"
  echo "closed=$closed"
} >> "$GITHUB_OUTPUT"
