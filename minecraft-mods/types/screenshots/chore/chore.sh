#!/usr/bin/env bash
# Writes a merged run's captures into the baseline tree and commits exactly that subtree.
set -euo pipefail

: "${LOADER:?}" "${LIST_FILE:?}" "${CAPTURES_DIR:?}" "${BASELINES_DIR:?}"
# Two steps on purpose: a default containing `}` inside ${VAR:-...} would end the expansion early.
COMMIT_SUBJECT="${COMMIT_SUBJECT-}"
[[ -n "$COMMIT_SUBJECT" ]] || COMMIT_SUBJECT='chore: sync screenshot baselines ({loader})'

target="$BASELINES_DIR/$LOADER"
applied=0

if [[ -f "$LIST_FILE" ]]; then
  while IFS=$'\t' read -r state capture; do
    case "$state" in
      added | changed)
        [[ -f "$CAPTURES_DIR/$capture" ]] || {
          echo "::warning::$capture is listed as $state but missing from '$CAPTURES_DIR'"
          continue
        }
        mkdir -p "$(dirname "$target/$capture")"
        cp "$CAPTURES_DIR/$capture" "$target/$capture"
        applied=$((applied + 1))
        ;;
      deleted)
        rm -f "$target/$capture"
        applied=$((applied + 1))
        ;;
      *)
        echo "::warning::unknown state '$state' for $capture"
        ;;
    esac
  done < <(jq -r '[(.state), (.capture)] | @tsv' "$LIST_FILE")
fi

echo "applied=$applied" >> "$GITHUB_OUTPUT"

if (( applied == 0 )); then
  echo "Nothing to sync for $LOADER"
  exit 0
fi

git add -A -- "$target"
if git diff --cached --quiet -- "$target"; then
  echo "The baseline tree already matches these captures"
  exit 0
fi

subject=${COMMIT_SUBJECT//\{loader\}/$LOADER}
git -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -m "$subject" -- "$target"
git push

echo "Committed $applied capture change(s) for $LOADER as: $subject"
