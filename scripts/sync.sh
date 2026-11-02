#!/usr/bin/env bash
# Mirrors each registry entry's product templates onto that repository's default branch, and creates
# its labels. One commit per consumer, only the paths that actually changed.
set -euo pipefail

: "${GH_TOKEN:?}" "${SOURCE_SHA:?}"
registry="${1:-consumers.jsonl}"
[[ -f "$registry" ]] || {
  echo "::error::registry '$registry' is missing"
  exit 1
}

failed=0

sync_repo() {
  local repo="$1" product="$2" skip="$3" wants_labels="$4"
  local branch base_sha base_tree entries='[]' changed=0 file rel blob current payload tree commit

  branch=$(gh api "repos/$repo" --jq .default_branch)
  base_sha=$(gh api "repos/$repo/git/ref/heads/$branch" --jq .object.sha)
  base_tree=$(gh api "repos/$repo/git/commits/$base_sha" --jq .tree.sha)

  while IFS= read -r file; do
    rel="${file#"$product"/templates/}"
    if jq -e --arg path "$rel" 'index($path) != null' <<<"$skip" > /dev/null; then
      echo "skipping $rel (registry)"
      continue
    fi

    payload=$(mktemp)
    jq -n --rawfile content "$file" '{content: $content, encoding: "utf-8"}' > "$payload"
    blob=$(gh api -X POST "repos/$repo/git/blobs" --input "$payload" --jq .sha)
    rm -f "$payload"

    current=$(gh api "repos/$repo/contents/$rel?ref=$branch" --jq .sha 2> /dev/null || true)
    if [[ "$current" == "$blob" ]]; then
      continue
    fi

    entries=$(jq -c --arg path "$rel" --arg sha "$blob" \
      '. + [{path: $path, mode: "100644", type: "blob", sha: $sha}]' <<<"$entries")
    changed=$((changed + 1))
  done < <(find "$product/templates" -type f | sort)

  if (( changed == 0 )); then
    echo "$repo@$branch already matches this commit"
  else
    payload=$(mktemp)
    jq -n --arg base "$base_tree" --argjson entries "$entries" \
      '{base_tree: $base, tree: $entries}' > "$payload"
    tree=$(gh api -X POST "repos/$repo/git/trees" --input "$payload" --jq .sha)

    jq -n --arg message "chore: sync shared CI ($SOURCE_SHA)" --arg tree "$tree" \
      --arg parent "$base_sha" '{message: $message, tree: $tree, parents: [$parent]}' > "$payload"
    commit=$(gh api -X POST "repos/$repo/git/commits" --input "$payload" --jq .sha)
    rm -f "$payload"

    gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$commit" --jq .object.sha > /dev/null
    echo "Wrote $changed file(s) to $repo@$branch as ${commit:0:7}"
  fi

  if [[ "$wants_labels" == "true" ]]; then
    local line
    while IFS= read -r line; do
      if [[ -z "${line//[[:space:]]/}" ]]; then continue; fi
      gh label create "$(jq -r .name <<<"$line")" \
        --repo "$repo" \
        --color "$(jq -r .color <<<"$line")" \
        --description "$(jq -r '.description // ""' <<<"$line")" \
        --force
    done < "$product/labels.jsonl"
    echo "Labels applied to $repo"
  fi
}

while IFS= read -r line; do
  if [[ -z "${line//[[:space:]]/}" ]]; then continue; fi

  if ! repo=$(jq -er '.repo' <<<"$line"); then
    echo "::error::registry line without a string .repo: $line"
    failed=1
    continue
  fi
  if ! product=$(jq -er '.product' <<<"$line"); then
    echo "::error::$repo: registry line without a string .product"
    failed=1
    continue
  fi
  if [[ ! -d "$product/templates" ]]; then
    echo "::error::$repo: product '$product' has no templates directory"
    failed=1
    continue
  fi

  echo "::group::$repo ($product)"
  if ! sync_repo "$repo" "$product" "$(jq -c '.skip // []' <<<"$line")" "$(jq -r '.labels // true' <<<"$line")"; then
    echo "::error::$repo did not finish syncing"
    failed=1
  fi
  echo "::endgroup::"
done < "$registry"

exit "$failed"
