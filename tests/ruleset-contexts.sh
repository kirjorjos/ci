#!/usr/bin/env bash
# Pins the check-name matching in scripts/rulesets.rb against the shape that broke it silently.
#
# The script decides whether a ruleset's required context has a provider by matching each reported
# name against the required one, treating a `${{ ... }}` as a wildcard. A name that *ends* in one -
# `type-lifecycle.yml`'s suite job is `${{ matrix.loader }}`, reported as `dispatch / Lifecycle /
# ${{ matrix.loader }}` - split into a single literal part, so its wildcard was dropped and
# `dispatch / Lifecycle / forge` matched nothing. The sweep then reported a context the run does
# report, and the ruleset looked stale while the matcher was wrong.
#
# Nothing here touches GitHub: the call tree is a fixture that mirrors the real one (entry -> dispatch
# -> type workflow, two levels of `name:`), and the rulesets are exported JSON. Two trees, because a
# wildcard that matches everything would pass any single run: the first asserts a matrix-named leg
# resolves, the second - which has no matrix in it at all - asserts a context no job defines still
# fails.
#
#   bash tests/ruleset-contexts.sh
#   RULESETS_SCRIPT=scripts/.older.rb bash tests/ruleset-contexts.sh   # what the fix pins
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
script=${RULESETS_SCRIPT:-$root/scripts/rulesets.rb}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The documented offline form names the directory itself, which is why `dir_workflows` strips the
# `.github/workflows` suffix rather than assuming a checkout root.
write_tree() {
  local dir=$1 suite=$2
  mkdir -p "$dir"

  cat > "$dir/minecheck-ci.yml" <<'YAML'
name: Shared CI
on:
  pull_request:
jobs:
  dispatch:
    uses: ./.github/workflows/dispatch.yml
YAML

  cat > "$dir/dispatch.yml" <<'YAML'
on:
  workflow_call:
jobs:
  resolve:
    name: Resolve check types
    runs-on: ubuntu-latest
    steps:
      - run: "true"
  lifecycle:
    name: Lifecycle
    uses: ./.github/workflows/type-lifecycle.yml
  rules:
    name: Rules
    uses: ./.github/workflows/type-rules.yml
YAML

  # The suite job's name is the whole point, so it is substituted rather than written twice: a
  # heredoc that expands would read `${{` as a bad parameter substitution.
  cat > "$dir/type-lifecycle.yml" <<'YAML'
on:
  workflow_call:
jobs:
  loaders:
    name: Read the loaders
    runs-on: ubuntu-latest
    steps:
      - run: "true"
  suites:
    name: __SUITE__
    runs-on: ubuntu-latest
    strategy:
      matrix:
        loader: [fabric, forge]
    steps:
      - run: "true"
YAML
  sed -i "s|__SUITE__|$suite|" "$dir/type-lifecycle.yml"

  cat > "$dir/type-rules.yml" <<'YAML'
on:
  workflow_call:
jobs:
  rules:
    name: Validate PR rules
    runs-on: ubuntu-latest
    steps:
      - run: "true"
YAML
}

# One ruleset shape; the contexts are what differ between the runs.
write_rulesets() {
  local file=$1 context=$2
  cat > "$file" <<JSON
[
  {
    "name": "Version development",
    "target": "branch",
    "enforcement": "active",
    "conditions": {"ref_name": {"include": ["refs/heads/*/development"], "exclude": []}},
    "rules": [
      {
        "type": "required_status_checks",
        "parameters": {
          "strict_required_status_checks_policy": true,
          "required_status_checks": [{"context": "$context"}]
        }
      }
    ]
  }
]
JSON
}

# A matrix-named leg beside a literal nested name: the fix for the suffix cannot be a wildcard that
# matches anything without the literal context below still having to match literally.
write_tree "$work/matrix/.github/workflows" '${{ matrix.loader }}'
write_rulesets "$work/reportable.json" "dispatch / Lifecycle / forge"
python3 - "$work/reportable.json" <<'PY'
import json, sys
path = sys.argv[1]
rulesets = json.load(open(path))
checks = rulesets[0]["rules"][0]["parameters"]["required_status_checks"]
checks.append({"context": "dispatch / Rules / Validate PR rules"})
json.dump(rulesets, open(path, "w"))
PY

write_tree "$work/plain/.github/workflows" "loader suite"
write_rulesets "$work/absent.json" "dispatch / Forge / Build"

fail=0
run() {
  GH_TOKEN=stub ruby "$script" --repo acme/widget --workflows "$1" --rulesets "$2" 2>&1
}

if ! out=$(run "$work/matrix/.github/workflows" "$work/reportable.json"); then
  printf '%s\n' "$out" | sed 's/^/  /'
  echo "::error::a name ending in a matrix expression no longer matches its expanded context"
  fail=1
elif [[ $out != *"every required context has a provider"* ]]; then
  printf '%s\n' "$out" | sed 's/^/  /'
  echo "::error::the offline run passed without reporting that every context has a provider"
  fail=1
fi

if out=$(run "$work/plain/.github/workflows" "$work/absent.json"); then
  echo "::error::a context no job reports passed, so the matcher accepts anything"
  fail=1
elif [[ $out != *'requires `dispatch / Forge / Build`, which no job reports'* ]]; then
  printf '%s\n' "$out" | sed 's/^/  /'
  echo "::error::the unprovided context failed without naming itself"
  fail=1
fi

(( fail == 0 )) || exit 1
echo "ruleset matcher ok: matrix suffix matches, absent context still fails"
