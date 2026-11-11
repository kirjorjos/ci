#!/usr/bin/env bash
# Pins the templates each consumer installs.
#
# A template that starts or stops reaching a consumer is a real change to what runs in another
# repository, and it usually happens sideways: a file added under `minecraft-mods/templates/` joins
# every consumer whose types it shares, a type added to or dropped from a registry entry moves a
# whole group, an emptied type list retires a file nobody meant to retire. None of that is
# in the diff that causes it, and the sync then writes it into every version line of three
# repositories. This compares each consumer's installed set against `tests/template-sets.tsv` and
# fails on any difference, so the change has to be written down and reviewed.
#
#   bash tests/template-sets.sh            compare
#   bash tests/template-sets.sh --update   rewrite the file, then read the diff
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
# shellcheck source=../scripts/template-set.sh
source "$here/../scripts/template-set.sh"

registry="$root/consumers.jsonl"
templates="$root/minecraft-mods/templates"
table_file="$root/minecraft-mods/templates.jsonl"
expected="$here/template-sets.tsv"
update=0
[[ "${1:-}" == --update ]] && update=1

failed=0

table=$(jq -s 'map({key: .path, value: .types}) | from_entries' "$table_file") || {
  echo "::error::$table_file is not a list of {path, types} objects"
  exit 1
}

computed=$(mktemp)
trap 'rm -f "$computed"' EXIT
: > "$computed"

while IFS= read -r line; do
  [[ -z "${line//[[:space:]]/}" ]] && continue
  if ! repo=$(jq -er '.repo' <<<"$line"); then
    echo "::error::consumers.jsonl has an entry without a repo"
    failed=1
    continue
  fi
  skip=$(jq -c '.skip // []' <<<"$line")
  types=$(jq -c '.types // []' <<<"$line")

  if ! selection=$(template_selection "$table" "$templates" "$skip" "$types"); then
    echo "::error::$repo: selecting templates failed"
    failed=1
    continue
  fi
  # Canonical order inside the line too: `find | sort` follows the caller's locale, and the golden
  # file has to match the same path order on a laptop and on a runner.
  set=$(awk -F'\t' '$1 == "keep" {print $2}' <<<"$selection" | LC_ALL=C sort)
  [[ -n "$set" ]] || set='(none)'
  { printf '%s' "$repo"; printf '\t%s' $set; printf '\n'; } >> "$computed"
done < "$registry"

LC_ALL=C sort -o "$computed" "$computed"

if (( update )); then
  cp "$computed" "$expected"
  echo "wrote $expected"
  exit 0
fi

if [[ ! -f "$expected" ]]; then
  echo "::error::$expected is missing; run: bash tests/template-sets.sh --update"
  exit 1
fi

if ! diff -u --label "recorded in tests/template-sets.tsv" --label "installed now" \
  <(LC_ALL=C sort "$expected") <(cat "$computed"); then
  echo "::error::a consumer's installed templates changed. If that is intended, run" \
    "'bash tests/template-sets.sh --update' and commit the result with the change that caused it."
  failed=1
fi

if (( failed )); then
  exit 1
fi
echo "template sets match ($(wc -l < "$expected") consumers)"
