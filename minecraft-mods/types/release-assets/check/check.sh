#!/usr/bin/env bash
# Verifies that a staged release holds exactly the jars this version should publish.
#
# The failure this exists for: a release dispatch that builds several versions on one runner leaves
# the previous version's jars in the staging directory, so the later version's tag ships the earlier
# version's build. Both checks below are needed - presence catches a missing jar, the name check and
# the count catch anything that should not be there at all.
set -euo pipefail

: "${ARTIFACTS_DIR:?}" "${LOADERS_FILE:?}" "${MC:?}" "${VERSION:?}"
PREFIX="${PREFIX:-}"
# Not a single ${NAME_FORMAT:-...} default: the first closing brace inside one ends the expansion
# early, so a default containing placeholders silently truncates and every jar name comes out wrong.
NAME_FORMAT="${NAME_FORMAT-}"
[[ -n "$NAME_FORMAT" ]] || NAME_FORMAT='{loader}-{mc}-{version}{deobf}.jar'
VARIANTS="${VARIANTS-,-deobf}"
WRITE_CHECKSUMS="${WRITE_CHECKSUMS:-true}"

fail() {
  echo "::error::$*"
  exit 1
}

[[ -d "$ARTIFACTS_DIR" ]] || fail "staging directory '$ARTIFACTS_DIR' does not exist"
[[ -f "$LOADERS_FILE" ]] || fail "metadata file '$LOADERS_FILE' does not exist"

# The consumer's own metadata file, not a bare loader list: loaders and the release's naming facts
# live in one object so the set that gets built cannot disagree with the set that gets verified.
mapfile -t LOADERS < <(jq -er '.loaders[]' "$LOADERS_FILE")
(( ${#LOADERS[@]} > 0 )) || fail "'$LOADERS_FILE' lists no loaders"

# An explicitly empty VARIANTS means one jar per loader whose {deobf} is empty, which is a real
# layout (a branch that ships no development-names twin), so it must not be rejected.
if [[ -z "$VARIANTS" ]]; then
  variants=("")
else
  IFS=',' read -r -a variants <<< "$VARIANTS"
fi

expected=()
for loader in "${LOADERS[@]}"; do
  # One jar per variant: the default is the loadable jar plus its development-names twin.
  for deobf in "${variants[@]}"; do
    # sed, not ${name//pattern/replacement}: the brace placeholders are the kind of pattern bash
    # expansion mangles silently, and a wrong name here fails as "missing jar" rather than
    # loudly.
    name=$(sed \
      -e "s/{loader}/$loader/g" \
      -e "s/{mc}/$MC/g" \
      -e "s/{version}/$VERSION/g" \
      -e "s/{deobf}/$deobf/g" <<< "$NAME_FORMAT")
    expected+=("$PREFIX$name")
  done
done

missing=0
for name in "${expected[@]}"; do
  if [[ ! -f "$ARTIFACTS_DIR/$name" ]]; then
    echo "::error::missing $name"
    missing=1
  fi
done
(( missing == 0 )) || fail "the staged set is incomplete for $MC $VERSION"

shopt -s nullglob
staged=("$ARTIFACTS_DIR"/*.jar)
for path in "${staged[@]}"; do
  base="$(basename "$path")"
  wanted=false
  for name in "${expected[@]}"; do
    if [[ "$base" == "$name" ]]; then
      wanted=true
      break
    fi
  done
  [[ "$wanted" == true ]] || fail "$base does not belong to $MC $VERSION"
done
(( ${#staged[@]} == ${#expected[@]} )) ||
  fail "staged ${#staged[@]} jar(s), expected ${#expected[@]} for $MC $VERSION"

assets=()
if [[ "$WRITE_CHECKSUMS" == "true" ]]; then
  (
    cd "$ARTIFACTS_DIR"
    sha256sum "${expected[@]}" > SHA256SUMS.txt
  )
  assets+=("$(cd "$ARTIFACTS_DIR" && pwd)/SHA256SUMS.txt")
fi
for name in "${expected[@]}"; do
  assets+=("$(cd "$ARTIFACTS_DIR" && pwd)/$name")
done

{
  echo "count=${#expected[@]}"
  echo "assets<<ASSETS_EOF"
  printf '%s\n' "${assets[@]}"
  echo "ASSETS_EOF"
} >> "$GITHUB_OUTPUT"

echo "Verified ${#expected[@]} jar(s) for $MC $VERSION in $ARTIFACTS_DIR"
