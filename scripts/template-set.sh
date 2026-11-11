#!/usr/bin/env bash
# Which templates one consumer installs - the single decision `sync.sh` applies and
# `tests/template-sets.sh` pins. Prints one tab-separated line per file under <templates-dir>:
#
#   keep<TAB><rel>
#   drop<TAB><rel><TAB><why>
#
# <table> is `<product>/templates.jsonl` reduced to {path: types}: a path the table does not name
# ships everywhere; any other list ships it where the consumer's `types` intersect it, so an empty
# list ships nowhere. `skip` is the registry's explicit refusal and wins over all of that.
#
# It lives beside sync.sh rather than inside it so the test runs this code instead of a second copy
# of the same rules, which would only ever agree with itself.

template_selection() {
  local table="$1" dir="$2" skip="$3" types="$4"
  local file rel owners
  while IFS= read -r file; do
    rel="${file#"$dir"/}"
    if jq -e --arg path "$rel" 'index($path) != null' <<<"$skip" > /dev/null; then
      printf 'drop\t%s\t%s\n' "$rel" registry
      continue
    fi

    owners=$(jq -r --arg rel "$rel" \
      'if has($rel) then (.[$rel] | join(" ")) else "any" end' <<<"$table") || return 1
    case "$owners" in
      any)
        ;;
      "")
        printf 'drop\t%s\t%s\n' "$rel" 'no type implies it'
        continue
        ;;
      *)
        if ! jq -n -e --arg owners "$owners" --argjson have "$types" \
          '$owners | split(" ") | any(. as $want | $have | index($want))' > /dev/null; then
          printf 'drop\t%s\t%s\n' "$rel" "no ${owners// / or } type"
          continue
        fi
        ;;
    esac

    printf 'keep\t%s\n' "$rel"
  done < <(find "$dir" -type f | sort)
}
