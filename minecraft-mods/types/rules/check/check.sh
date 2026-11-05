#!/usr/bin/env bash
# Judges a pull request's shape, then acts: close an invalid one, announce a loader removal, note an
# ungated target, or record `Fixed in <version>` when a development PR merges.
#
# The rule (`.notes/ci-structure-spec.md`, S5, S11, S14a, S18, S21):
#   <version>/development  - source must be <version>/development-issue-<n> of the same version
#   <version>/main         - the release job only (bot-authored, same repository, from development)
#   anything else          - a plain contribution: any source, forks included, never closed
#
# This runs on `pull_request_target`, which is what lets it comment on and close a fork's pull
# request. It never checks the pull request out: the two loader lists it compares are read through
# the contents API at the base and head SHAs, so a write-scoped job stays away from PR content (S17).
set -euo pipefail

: "${REPO:?}" "${PR_NUMBER:?}" "${BASE_REF:?}"

ACTION="${EVENT_ACTION:-}"
TARGET="$BASE_REF"
SOURCE="${HEAD_REF:-}"
HEAD_REPO_NAME="${HEAD_REPO:-$REPO}"
PR_AUTHOR="${AUTHOR:-}"
MERGED="${MERGED:-false}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"

LOADERS_MARKER='<!-- loaders-removed -->'
REMARKS_MARKER='<!-- rules-remarks -->'

VALID=true
REASON=""
TARGET_TYPE=other
TARGET_VERSION=""
SOURCE_KIND=""
SOURCE_VERSION=""
SOURCE_ISSUE=""
SOURCE_ISSUE_JSON=""
SOURCE_ISSUE_STATE=""
SOURCE_ISSUE_LABELS=""

# Branch grammar. `<version>` admits two-part Minecraft versions (1.8, 1.19, 26.1) and three-part
# ones (1.19.2); the capture groups are fixed so `BASH_REMATCH[3]` is the issue number below.
if [[ "$TARGET" =~ ^([0-9]+(\.[0-9]+){1,2})/development-issue-[0-9]+$ ]]; then
  TARGET_TYPE=issue
  TARGET_VERSION="${BASH_REMATCH[1]}"
elif [[ "$TARGET" =~ ^([0-9]+(\.[0-9]+){1,2})/development$ ]]; then
  TARGET_TYPE=development
  TARGET_VERSION="${BASH_REMATCH[1]}"
elif [[ "$TARGET" =~ ^([0-9]+(\.[0-9]+){1,2})/main$ ]]; then
  TARGET_TYPE=main
  TARGET_VERSION="${BASH_REMATCH[1]}"
fi

if [[ "$SOURCE" =~ ^([0-9]+(\.[0-9]+){1,2})/development-issue-([0-9]+)$ ]]; then
  SOURCE_KIND=issue
  SOURCE_VERSION="${BASH_REMATCH[1]}"
  SOURCE_ISSUE="${BASH_REMATCH[3]}"
elif [[ "$SOURCE" =~ ^([0-9]+(\.[0-9]+){1,2})/development$ ]]; then
  SOURCE_KIND=development
  SOURCE_VERSION="${BASH_REMATCH[1]}"
fi

if [[ "$ACTION" != 'closed' ]]; then
  case "$TARGET_TYPE" in
    issue | other)
      # Anything may open a pull request into an issue, collation or feature branch.
      ;;
    development)
      if [[ "$SOURCE_KIND" != 'issue' ]]; then
        VALID=false
        REASON="Source branch \`$SOURCE\` is not \`<version>/development-issue-{issue}\`."
      elif [[ "$SOURCE_VERSION" != "$TARGET_VERSION" ]]; then
        VALID=false
        REASON="Source version \`$SOURCE_VERSION\` does not match target version \`$TARGET_VERSION\`."
      elif [[ "$SOURCE_ISSUE" =~ ^0+$ ]]; then
        VALID=false
        REASON="Source branch \`$SOURCE\` names issue #$SOURCE_ISSUE; the issue number must be a positive, non-zero integer."
      elif ! SOURCE_ISSUE_JSON=$(gh api "repos/$REPO/issues/$SOURCE_ISSUE" 2> /dev/null); then
        # GitHub answers 404 for a number that never existed and for one that was deleted alike, and
        # both mean the same thing here: nothing in this repository can be worked under that number.
        VALID=false
        REASON="Source branch \`$SOURCE\` names issue #$SOURCE_ISSUE, which does not exist in \`$REPO\`."
      elif jq -e 'has("pull_request")' <<< "$SOURCE_ISSUE_JSON" > /dev/null; then
        VALID=false
        REASON="Source branch \`$SOURCE\` names #$SOURCE_ISSUE, which is a pull request; the source must name an issue."
      else
        SOURCE_ISSUE_STATE=$(jq -r '.state // ""' <<< "$SOURCE_ISSUE_JSON")
        SOURCE_ISSUE_LABELS=$(jq -r '[.labels[]? | if type == "object" then .name else . end] | join(",")' \
          <<< "$SOURCE_ISSUE_JSON")
      fi
      ;;
    main)
      # `main` is release-only: bot-authored, same repository, from that version's development line.
      if [[ "$PR_AUTHOR" != 'github-actions[bot]' ]]; then
        VALID=false
        REASON="\`<version>/main\` only accepts pull requests opened by the release workflow (author \`github-actions[bot]\`), not by \`$PR_AUTHOR\`."
      elif [[ "$HEAD_REPO_NAME" != "$REPO" ]]; then
        VALID=false
        REASON="\`<version>/main\` only accepts releases from \`$REPO\`; PRs from \`$HEAD_REPO_NAME\` are rejected."
      elif [[ "$SOURCE_KIND" != 'development' ]]; then
        VALID=false
        REASON="Source branch \`$SOURCE\` is not \`<version>/development\`."
      elif [[ "$SOURCE_VERSION" != "$TARGET_VERSION" ]]; then
        VALID=false
        REASON="Source version \`$SOURCE_VERSION\` does not match target version \`$TARGET_VERSION\`."
      fi
      ;;
  esac
fi

{
  echo "valid=$VALID"
  echo "target-type=$TARGET_TYPE"
  echo "version=$TARGET_VERSION"
} >> "${GITHUB_OUTPUT:?}"

# Marks the issue a merged development PR came from, so the release can find and later edit it. The
# marker is what the release searches for; the prose is what a reader sees.
record_fixed_in() {
  local marker="minecheck-fixed-in:$TARGET_VERSION"
  if gh api "repos/$REPO/issues/$SOURCE_ISSUE/comments" --paginate --jq '.[].body' \
    | grep -F "$marker" > /dev/null; then
    echo "Issue #$SOURCE_ISSUE already records $marker"
    return
  fi
  jq -n --arg body "Fixed in **$TARGET_VERSION** via PR #$PR_NUMBER. <!-- $marker -->" '{body: $body}' \
    | gh api "repos/$REPO/issues/$SOURCE_ISSUE/comments" --input - > /dev/null
  echo "Issue #$SOURCE_ISSUE will close when every affected version is released."
}

# One comment naming the shape that was violated plus the model, then close. Exiting non-zero is the
# third half of S5: a rejected pull request must not look healthy in a list or a dashboard.
close_invalid() {
  local body
  body=$(jq -nr --arg reason "$REASON" '
    "**This pull request was automatically closed by CI validation.**\n\n" +
    "**Reason:** \($reason)\n\n" +
    "Branch model:\n" +
    "- `<version>/development-issue-<n>` — work branch; any source\n" +
    "- `<version>/development` — source: `<version>/development-issue-<n>` of the same version\n" +
    "- `<version>/main` — release workflow only (bot-authored, same repository, from `<version>/development`)\n" +
    "- any other branch — feature or collation branch; any source, gated by nothing\n\n" +
    "See `.notes/branching-versioning-migration-spec.md` for the full model.\n"
  ')
  jq -n --arg body "$body" '{body: $body}' \
    | gh api "repos/$REPO/issues/$PR_NUMBER/comments" --input - > /dev/null
  gh api "repos/$REPO/pulls/$PR_NUMBER" -X PATCH -f state=closed > /dev/null
  echo "::error::closed #$PR_NUMBER: $REASON"
  exit 1
}

# `.loaders` from the metadata file every version line carries. A failed read yields nothing, which
# reads as "this side lists no loaders" and so announces no removal.
read_loaders() {
  local ref="$1"
  gh api "repos/$REPO/contents/.github/metadata.json?ref=$ref" \
    -H "Accept: application/vnd.github.raw" 2> /dev/null \
    | jq -r '.loaders[]? // empty' 2> /dev/null || true
}

# Removing a loader deletes its jobs, which is allowed but must never be silent (S18). One comment,
# and only the first one: a synchronize must not announce the same removal again.
announce_loader_removal() {
  local base head removed body
  [[ -n "$BASE_SHA" && -n "$HEAD_SHA" ]] || return 0

  base="$(read_loaders "$BASE_SHA" | sed '/^$/d' | sort -u)"
  head="$(read_loaders "$HEAD_SHA" | sed '/^$/d' | sort -u)"
  removed="$(comm -23 <(printf '%s\n' "$base") <(printf '%s\n' "$head") | sed '/^$/d')"
  if [[ -z "$removed" ]]; then
    echo "No loader was removed."
    return 0
  fi

  if gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate --jq '.[].body' \
    | grep -F "$LOADERS_MARKER" > /dev/null; then
    echo "Already announced a loader removal."
    return 0
  fi

  body="$LOADERS_MARKER
This PR removes $(wc -l <<<"$removed" | tr -d ' ') loader(s) from \`.github/metadata.json\`, so CI will run fewer jobs:

$(printf -- '- `%s`\n' $removed)

Confirm this is intentional before merging."

  jq -n --arg body "$body" '{body: $body}' \
    | gh api "repos/$REPO/issues/$PR_NUMBER/comments" --input - > /dev/null
  echo "Announced the removal of: $(tr '\n' ' ' <<<"$removed")"
}

# S11's two remarks, neither of which blocks: a pull request into `<version>/development` is valid
# when its source issue is closed, and when that issue is not labelled `versions/<version>`. Both
# mean the issue will not be visited at release time (S13b), so the reviewer is told. One comment
# carries both, and it is removed when neither condition holds - a label added after the fact must
# not leave a claim behind that is no longer true.
remark_source_issue() {
  local remarks=() existing body
  if [[ "$SOURCE_ISSUE_STATE" != 'open' ]]; then
    remarks+=("is **$SOURCE_ISSUE_STATE**. The pull request still merges; the issue simply starts from a closed state.")
  fi
  if [[ ",$SOURCE_ISSUE_LABELS," != *",versions/$TARGET_VERSION,"* ]]; then
    remarks+=("is not labelled \`versions/$TARGET_VERSION\`, so the release loop will not visit it")
  fi

  existing=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
    --jq --arg m "$REMARKS_MARKER" '.[] | select((.body // "") | contains($m)) | .id' 2> /dev/null \
    | head -1 || true)

  if (( ${#remarks[@]} == 0 )); then
    if [[ -n "$existing" ]]; then
      gh api -X DELETE "repos/$REPO/issues/comments/$existing" > /dev/null
      echo "Removed the source-issue remarks: neither condition holds any more."
    fi
    return 0
  fi

  body=$(
    printf '%s\n\n' "$REMARKS_MARKER"
    printf '**Source issue #%s**\n\n' "$SOURCE_ISSUE"
    printf -- '- The source issue %s\n' "${remarks[@]}"
  )

  if [[ -n "$existing" ]]; then
    jq -n --arg body "$body" '{body: $body}' \
      | gh api -X PATCH "repos/$REPO/issues/comments/$existing" --input - > /dev/null
  else
    jq -n --arg body "$body" '{body: $body}' \
      | gh api "repos/$REPO/issues/$PR_NUMBER/comments" --input - > /dev/null
  fi
  echo "Remarked on source issue #$SOURCE_ISSUE: ${remarks[*]}"
}

if [[ "$ACTION" == 'closed' ]]; then
  if [[ "$MERGED" == 'true' && "$TARGET_TYPE" == 'development' && -n "$SOURCE_ISSUE" ]]; then
    record_fixed_in
  fi
  exit 0
fi

if [[ "$VALID" != 'true' ]]; then
  close_invalid
fi

# A valid development pull request may still have something to say about its source issue.
if [[ "$TARGET_TYPE" == 'development' && -n "$SOURCE_ISSUE_STATE" ]]; then
  remark_source_issue
fi

# A target that is neither a development nor a main line is a plain contribution (S21): the notice
# is the only signal it gets, because nothing gates it and it is never closed for its shape.
if [[ "$TARGET_TYPE" == 'other' ]]; then
  {
    echo "### Ungated target"
    echo ""
    echo "\`$TARGET\` is neither \`<version>/development\` nor \`<version>/main\`. This PR runs the"
    echo "full loader matrix, no required check gates it, and it is never closed for its shape."
    echo ""
    echo "Recognized gated shapes: \`<version>/development\` (from \`<version>/development-issue-<n>\`)"
    echo "and \`<version>/main\` (release workflow only)."
  } >> "${GITHUB_STEP_SUMMARY:?}"
fi

announce_loader_removal
