#!/usr/bin/env bash
# Reports the test scripts nothing references, as one updated pull-request comment.
#
# "Referenced" is deliberate and generous: the file name has to appear somewhere outside the script
# itself. That covers every real wiring in a consumer - a Gradle task naming `script = "x.lua"`, a
# coordinator or driver file naming it, another script loading it, a docs page describing it - while
# still catching the case the issue is about: a script that looks like coverage and runs nowhere.
#
# The comment is upserted by marker and deleted when there is nothing to report, so a fixed PR does
# not keep a stale warning. The job never fails: it reports.
set -euo pipefail

: "${REPO:?}"
SCRIPTS_DIR="${SCRIPTS_DIR:-tests/scripts}"
MARKER="${MARKER:-<!-- minecheck-script-coverage -->}"
PR_NUMBER="${PR_NUMBER-}"

orphans=()
emit() {
  {
    echo "count=${#orphans[@]}"
    echo "orphans<<ORPHANS_EOF"
    printf '%s\n' "${orphans[@]}"
    echo "ORPHANS_EOF"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
}

if [[ ! -d "$SCRIPTS_DIR" ]]; then
  echo "::notice::no $SCRIPTS_DIR directory; nothing to audit"
  emit
  exit 0
fi

shopt -s nullglob
scripts=("$SCRIPTS_DIR"/*.lua)
for path in "${scripts[@]}"; do
  name="$(basename "$path")"
  # -I skips binaries (the baseline pictures live in the same checkout), --exclude keeps the script
  # from referencing itself.
  if grep -rIlF --exclude-dir=.git --exclude-dir=build --exclude-dir=run --exclude-dir=.gradle \
    --exclude="$name" -- "$name" . > /dev/null 2>&1; then
    continue
  fi
  orphans+=("$path")
done

if (( ${#orphans[@]} == 0 )); then
  echo "every script in $SCRIPTS_DIR is referenced"
else
  echo "::warning::${#orphans[@]} script(s) in $SCRIPTS_DIR are referenced by nothing"
fi

if [[ -n "$PR_NUMBER" ]]; then
  existing=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" --paginate \
    --jq --arg m "$MARKER" '.[] | select((.body // "") | contains($m)) | .id' | head -1 || true)

  if (( ${#orphans[@]} == 0 )); then
    if [[ -n "$existing" ]]; then
      gh api -X DELETE "repos/$REPO/issues/comments/$existing" > /dev/null
    fi
  else
    body=$(printf '%s\n\n**%d test script(s) run nowhere.** Nothing in this repository references them: no Gradle task, no coordinator, no driver file, no other script.\n' \
      "$MARKER" "${#orphans[@]}")
    for path in "${orphans[@]}"; do
      body+=$'\n'"- \`$path\`"
    done
    body+=$'\n\n'"Wire each one into a task or a script, or delete it — a script that nothing names looks like coverage and is not."$'\n'
    if [[ -n "$existing" ]]; then
      gh api -X PATCH "repos/$REPO/issues/comments/$existing" -f body="$body" > /dev/null
    else
      gh api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" -f body="$body" > /dev/null
    fi
  fi
fi

{
  echo "### Script coverage"
  echo
  if (( ${#orphans[@]} == 0 )); then
    echo "Every script in \`$SCRIPTS_DIR\` is referenced."
  else
    echo "Referenced by nothing:"
    echo
    for path in "${orphans[@]}"; do
      echo "- \`$path\`"
    done
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

emit
