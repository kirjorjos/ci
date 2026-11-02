#!/usr/bin/env bash
# Runs one loader's lifecycle suite and reports its result without swallowing it.
set -euo pipefail

: "${LOADER:?}" "${TASK:?}"
GRADLE_ARGS="${GRADLE_ARGS:---no-daemon --console=plain}"

read -r -a args <<< "$GRADLE_ARGS"

status=0
./gradlew "$TASK" "${args[@]}" || status=$?

{
  echo "### Lifecycle $LOADER"
  echo
  if (( status == 0 )); then
    echo "Passed: \`$TASK\`"
  else
    echo "Failed: \`$TASK\` (exit $status)"
  fi
} >> "$GITHUB_STEP_SUMMARY"

exit "$status"
