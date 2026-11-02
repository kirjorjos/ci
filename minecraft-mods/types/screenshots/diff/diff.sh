#!/usr/bin/env bash
# Compares captures against a baseline subtree, by name and content hash.
set -euo pipefail

: "${LOADER:?}" "${CAPTURES_DIR:?}" "${BASELINES_DIR:?}" "${LIST_FILE:?}"

baselines="$BASELINES_DIR/$LOADER"
mkdir -p "$(dirname "$LIST_FILE")"
: > "$LIST_FILE"

hashes() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    return 0
  fi
  find "$root" -type f -name '*.png' -print0 |
    while IFS= read -r -d '' file; do
      printf '%s %s\n' "${file#"$root"/}" "$(sha256sum "$file" | cut -d' ' -f1)"
    done
}

declare -A base=() shot=()
while read -r name hash; do
  if [[ -n "$name" ]]; then base["$name"]="$hash"; fi
done < <(hashes "$baselines")
while read -r name hash; do
  if [[ -n "$name" ]]; then shot["$name"]="$hash"; fi
done < <(hashes "$CAPTURES_DIR")

record() {
  printf '{"capture":"%s","state":"%s"}\n' "$1" "$2" >> "$LIST_FILE"
}

for name in "${!shot[@]}"; do
  if [[ -z "${base[$name]:-}" ]]; then
    record "$name" added
  elif [[ "${base[$name]}" != "${shot[$name]}" ]]; then
    record "$name" changed
  fi
done
for name in "${!base[@]}"; do
  [[ -n "${shot[$name]:-}" ]] || record "$name" deleted
done

sort -o "$LIST_FILE" "$LIST_FILE"
changed=$(wc -l < "$LIST_FILE" | tr -d ' ')
[[ "$changed" -gt 0 ]] && mismatches=true || mismatches=false

{
  echo "list-file=$LIST_FILE"
  echo "changed=$changed"
  echo "has-mismatches=$mismatches"
} >> "$GITHUB_OUTPUT"

if [[ "$mismatches" == true ]]; then
  echo "::warning::$changed capture(s) for $LOADER differ from $baselines"
fi
