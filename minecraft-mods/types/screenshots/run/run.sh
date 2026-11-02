#!/usr/bin/env bash
# Runs one screenshot task and reports the capture directory, without judging anything.
set -euo pipefail

: "${TASK:?}" "${CAPTURES_DIR:?}"
GRADLE_ARGS="${GRADLE_ARGS:---no-daemon --console=plain}"

read -r -a args <<< "$GRADLE_ARGS"
./gradlew "$TASK" "${args[@]}"

[[ -d "$CAPTURES_DIR" ]] || {
  echo "::error::$TASK produced no capture directory at '$CAPTURES_DIR'"
  exit 1
}

shopt -s nullglob
captures=("$CAPTURES_DIR"/*.png)
[[ ${#captures[@]} -gt 0 ]] || {
  echo "::error::$TASK wrote no captures into '$CAPTURES_DIR'"
  exit 1
}

{
  echo "captures-dir=$(cd "$CAPTURES_DIR" && pwd)"
  echo "count=${#captures[@]}"
} >> "$GITHUB_OUTPUT"
echo "Captured ${#captures[@]} screenshot(s) with $TASK"
