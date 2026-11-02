#!/usr/bin/env bash
# Mirrors each registry entry's product templates onto every version line of that repository, and
# creates its labels. One commit per branch, only the paths that actually changed.
#
# "Every version line" is each `<version>/main` and `<version>/development` branch, plus the
# repository's default branch: a workflow file only triggers on a branch that carries it (pushes run
# the file on the pushed branch, pull requests run the base branch's copy), so writing one default
# branch leaves every older Minecraft line without shared checks entirely.
#
# `set -e` is not relied on for the per-consumer work: the loop calls `sync_repo` in a condition, and
# bash disables errexit for the whole body of a function invoked that way. Every call that can fail is
# therefore checked by hand, so a rejected write fails the run instead of being reported as a success.
set -uo pipefail

: "${GH_TOKEN:?}" "${SOURCE_SHA:?}"
registry="${1:-consumers.jsonl}"
[[ -f "$registry" ]] || {
  echo "::error::registry '$registry' is missing"
  exit 1
}

failed=0

# api <description> [gh api args...] — prints the response, or reports it and returns non-zero.
api() {
  local what="$1" out
  shift
  if ! out=$(gh api "$@" 2>&1); then
    # stderr, so the cause survives being captured by the caller's `$(api ...)`.
    echo "::error::$repo: $what failed: $out" >&2
    return 1
  fi
  printf '%s' "$out"
}

# version_lines <repo> — the branches to write, one per line, the default branch first.
version_lines() {
  local repo="$1" default names
  default=$(api "reading the default branch" "repos/$repo" --jq .default_branch) || return 1
  names=$(api "listing branches" "repos/$repo/branches" --paginate --jq '.[].name') || return 1
  {
    printf '%s\n' "$default"
    grep -E '(^|/)(main|development)$' <<<"$names" || true
  } | awk '!seen[$0]++'
}

sync_repo() {
  local repo="$1" product="$2" skip="$3" wants_labels="$4"
  local branch base_sha base_tree entries changed=0 file rel blob current payload tree commit ref i
  local line name ok
  local -a branches=() paths=() blobs=()

  mapfile -t branches < <(version_lines "$repo")
  if (( ${#branches[@]} == 0 )); then
    echo "::error::$repo: no version line (no default branch?) to sync"
    return 1
  fi

  # One blob per template file, reused by every branch: the bytes do not depend on the branch.
  while IFS= read -r file; do
    rel="${file#"$product"/templates/}"
    if jq -e --arg path "$rel" 'index($path) != null' <<<"$skip" > /dev/null; then
      echo "skipping $rel (registry)"
      continue
    fi

    payload=$(mktemp)
    jq -n --rawfile content "$file" '{content: $content, encoding: "utf-8"}' > "$payload"
    if ! blob=$(api "creating a blob for $rel" -X POST "repos/$repo/git/blobs" --input "$payload" --jq .sha); then
      rm -f "$payload"
      return 1
    fi
    rm -f "$payload"

    paths+=("$rel")
    blobs+=("$blob")
  done < <(find "$product/templates" -type f | sort)

  for branch in "${branches[@]}"; do
    base_sha=$(api "reading the tip of $branch" "repos/$repo/git/ref/heads/$branch" --jq .object.sha) || return 1
    base_tree=$(api "reading the tree of $base_sha" "repos/$repo/git/commits/$base_sha" --jq .tree.sha) || return 1

    entries='[]'
    changed=0
    for i in "${!paths[@]}"; do
      rel="${paths[$i]}"
      blob="${blobs[$i]}"

      # A missing file is expected; anything else (an auth failure, most often) must not be read as one.
      if current=$(gh api "repos/$repo/contents/$rel?ref=$branch" --jq .sha 2>&1); then
        :
      else
        case "$current" in
          *"Not Found"*) current="" ;;
          *)
            echo "::error::$repo: reading $rel from $branch failed: $current"
            return 1
            ;;
        esac
      fi
      if [[ "$current" == "$blob" ]]; then
        continue
      fi

      entries=$(jq -c --arg path "$rel" --arg sha "$blob" \
        '. + [{path: $path, mode: "100644", type: "blob", sha: $sha}]' <<<"$entries")
      changed=$((changed + 1))
    done

    if (( changed == 0 )); then
      echo "$repo@$branch already matches this commit"
      continue
    fi

    payload=$(mktemp)
    jq -n --arg base "$base_tree" --argjson entries "$entries" \
      '{base_tree: $base, tree: $entries}' > "$payload"
    if ! tree=$(api "creating the tree for $branch" -X POST "repos/$repo/git/trees" --input "$payload" --jq .sha); then
      rm -f "$payload"
      return 1
    fi

    jq -n --arg message "chore: sync shared CI ($SOURCE_SHA)" --arg tree "$tree" \
      --arg parent "$base_sha" '{message: $message, tree: $tree, parents: [$parent]}' > "$payload"
    if ! commit=$(api "creating the commit for $branch" -X POST "repos/$repo/git/commits" --input "$payload" --jq .sha); then
      rm -f "$payload"
      return 1
    fi
    rm -f "$payload"

    if ! ref=$(api "moving $branch" -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$commit" --jq .object.sha); then
      return 1
    fi
    if [[ "$ref" != "$commit" ]]; then
      echo "::error::$repo: $branch points at $ref after the push, not $commit"
      return 1
    fi
    echo "Wrote $changed file(s) to $repo@$branch as ${commit:0:7}"
  done

  if [[ "$wants_labels" == "true" ]]; then
    ok=0
    while IFS= read -r line; do
      if [[ -z "${line//[[:space:]]/}" ]]; then continue; fi
      name=$(jq -r .name <<<"$line")
      if ! gh label create "$name" \
        --repo "$repo" \
        --color "$(jq -r .color <<<"$line")" \
        --description "$(jq -r '.description // ""' <<<"$line")" \
        --force > /dev/null; then
        echo "::error::$repo: creating label '$name' failed"
        ok=1
      fi
    done < "$product/labels.jsonl"
    if (( ok != 0 )); then
      return 1
    fi
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
