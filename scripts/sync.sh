#!/usr/bin/env bash
# Mirrors each registry entry's product templates onto every version line of that repository,
# deletes the paths the registry retires, and creates its labels. One commit per branch, only the
# paths that actually changed.
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

# The per-template decision this script applies; tests/template-sets.sh runs the same function,
# so the test pins the sets the sync would actually write.
source "$(dirname "${BASH_SOURCE[0]}")/template-set.sh"

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
  local repo="$1" product="$2" skip="$3" wants_labels="$4" prune="$5" types="$6"
  local branch base_sha base_tree entries changed=0 rel blob current payload tree commit ref i
  local line name ok verdict reason template_types='{}'
  local -a branches=() paths=() blobs=()

  mapfile -t branches < <(version_lines "$repo")
  if (( ${#branches[@]} == 0 )); then
    echo "::error::$repo: no version line (no default branch?) to sync"
    return 1
  fi

  # Which check type a template belongs to (`$product/templates.jsonl`). A file the table does not
  # name ships everywhere; any other list ships it to the consumers whose types intersect it, so an
  # empty list ships nowhere. That is what lets a consumer's `skip` shrink: it no longer has to
  # enumerate every template of a type it does not take.
  if [[ -f "$product/templates.jsonl" ]]; then
    if ! template_types=$(jq -s 'map({key: .path, value: .types}) | from_entries' \
      "$product/templates.jsonl"); then
      echo "::error::$product/templates.jsonl is not a list of {path, types} objects"
      return 1
    fi
  fi

  # One blob per installed template, reused by every branch: the bytes do not depend on the branch.
  while IFS=$'\t' read -r verdict rel reason; do
    if [[ "$verdict" != keep ]]; then
      echo "skipping $rel ($reason)"
      continue
    fi

    payload=$(mktemp)
    jq -n --rawfile content "$product/templates/$rel" '{content: $content, encoding: "utf-8"}' > "$payload"
    if ! blob=$(api "creating a blob for $rel" -X POST "repos/$repo/git/blobs" --input "$payload" --jq .sha); then
      rm -f "$payload"
      return 1
    fi
    rm -f "$payload"

    paths+=("$rel")
    blobs+=("$blob")
  done < <(template_selection "$template_types" "$product/templates" "$skip" "$types")

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

    # Retired paths. A workflow only stops running once the branch that carries it no longer does,
    # and `*/main` takes no ordinary pull request, so a hand PR could only ever clean up
    # `*/development` and leave the default branch running the file for another release. The app
    # token is a bypass actor on both rulesets, so this is the one write that can reach every line.
    # Absent is the steady state, which makes a second sync a no-op.
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      if ! current=$(gh api "repos/$repo/contents/$rel?ref=$branch" --jq .sha 2>&1); then
        case "$current" in
          *"Not Found"*) continue ;;
          *)
            echo "::error::$repo: reading $rel from $branch failed: $current"
            return 1
            ;;
        esac
      fi
      entries=$(jq -c --arg path "$rel" \
        '. + [{path: $path, mode: "100644", type: "blob", sha: null}]' <<<"$entries")
      changed=$((changed + 1))
      echo "removing $rel from $branch"
    done < <(jq -r '.[]?' <<<"$prune")

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
  if ! sync_repo "$repo" "$product" "$(jq -c '.skip // []' <<<"$line")" "$(jq -r '.labels // true' <<<"$line")" "$(jq -c '.remove // []' <<<"$line")" "$(jq -c '.types // []' <<<"$line")"; then
    echo "::error::$repo did not finish syncing"
    failed=1
  fi
  echo "::endgroup::"
done < "$registry"

exit "$failed"
