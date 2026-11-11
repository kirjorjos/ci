#!/usr/bin/env bash
# Exercises the write half of scripts/sync.sh - which templates become blobs, what each branch's tree
# contains, and what the commit says - against a stub `gh` (tests/fake-gh/gh). tests/template-sets.sh
# pins *which* templates are selected; this pins what the loop does with them, because that is where a
# regression reads as success: a loop that installs nothing reports "already matches this commit".
#
# Nothing here touches GitHub. The fixture is a one-loader product, a consumer that takes one of the
# two typed templates, and two branches: one that already has the untyped file and one that has a
# file the registry retires.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

product=$work/minecraft-mods
state=$work/state
mkdir -p "$product/templates" "$state/branches/1.0/development" "$state/branches/1.0/main"

printf 'shared doc\n' > "$product/templates/a.md"
printf 'alpha template\n' > "$product/templates/type1.yml"
printf 'beta template\n' > "$product/templates/type2.yml"
printf 'retired\n' > "$product/templates/old.yml"
cat > "$product/templates.jsonl" <<'JSONL'
{"path":"type1.yml","types":["alpha"]}
{"path":"type2.yml","types":["beta"]}
{"path":"old.yml","types":[]}
JSONL
printf '%s\n' '{"name":"ci","color":"ededed","description":"shared"}' > "$product/labels.jsonl"

cat > "$work/registry.jsonl" <<'JSONL'
{"repo":"acme/widget","product":"minecraft-mods","types":["alpha"],"remove":["old.yml"],"labels":true}
JSONL

# `a.md` on development is byte-identical to the template, so it must produce no blob entry.
# `type1.yml` is absent there although `alpha` is one of the consumer's types, which is what proves a
# type-owned template reaches the loop at all.
printf 'shared doc\n' > "$state/branches/1.0/development/a.md"
# The default branch starts with only the file the registry retires.
printf 'stale\n' > "$state/branches/1.0/main/old.yml"
printf '1.0/development\n1.0/main\n' > "$state/branch-names"
: > "$state/log.jsonl"

out=$(cd "$work" && env \
  GH_TOKEN=stub \
  SOURCE_SHA=test-sha \
  PATH="$here/fake-gh:$PATH" \
  FAKE_GH_DIR="$state" \
  FAKE_DEFAULT_BRANCH="1.0/development" \
  bash "$root/scripts/sync.sh" registry.jsonl 2>&1)
status=$?
printf '%s\n' "$out"
if (( status != 0 )); then
  echo "::error::scripts/sync.sh exited $status against the stub"
  exit 1
fi

python3 - "$state/log.jsonl" <<'PY'
import hashlib, json, sys

log = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]

def sha(text):
    data = text.encode()
    return hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()

problems = []
blobs = {e["sha"] for e in log if e["op"] == "blob"}
expected_blobs = {sha("shared doc\n"), sha("alpha template\n")}
if blobs != expected_blobs:
    problems.append(f"blob shas {sorted(s[:7] for s in blobs)} != {sorted(s[:7] for s in expected_blobs)}"
                    " (a beta-typed template becoming a blob means the selection is not honoured)")
if sha("beta template\n") in blobs:
    problems.append("a template the consumer has no type for was uploaded")

trees = [e["body"]["tree"] for e in log if e["op"] == "tree"]
if len(trees) != 2:
    problems.append(f"{len(trees)} trees written, expected 2 (one per branch)")
else:
    by_branch = {}
    for tree in trees:
        paths = sorted((entry["path"], entry["sha"]) for entry in tree)
        by_branch.setdefault(tuple(paths), 0)
        by_branch[tuple(paths)] += 1
    development = [("type1.yml", sha("alpha template\n"))]
    default = sorted([("a.md", sha("shared doc\n")), ("type1.yml", sha("alpha template\n")),
                      ("old.yml", None)])
    got = {k for k in by_branch}
    if tuple(development) not in got:
        problems.append(f"development tree {sorted(got)} has no entry set == {development}")
    if tuple(default) not in got:
        problems.append(f"no tree deletes old.yml and adds a.md + type1.yml; got {sorted(got)}")

commits = [e["body"] for e in log if e["op"] == "commit"]
if len(commits) != 2:
    problems.append(f"{len(commits)} commits, expected 2")
for commit in commits:
    if commit.get("message") != "chore: sync shared CI (test-sha)":
        problems.append(f"commit message {commit.get('message')!r}")
    if len(commit.get("parents", [])) != 1:
        problems.append(f"commit parents {commit.get('parents')}")
    if commit.get("tree") != "tree-new":
        problems.append(f"commit tree {commit.get('tree')!r}")

refs = {e["branch"]: e["sha"] for e in log if e["op"] == "ref"}
if set(refs) != {"1.0/development", "1.0/main"}:
    problems.append(f"branches moved: {sorted(refs)}")
if set(refs.values()) != {"commit-new"}:
    problems.append(f"refs point at {sorted(set(refs.values()))}")

if problems:
    for problem in problems:
        print(f"::error::{problem}")
    sys.exit(1)
print(f"write loop ok: {len(blobs)} blobs, {len(trees)} trees, {len(commits)} commits")
PY
status=$?

for expected in \
  "skipping type2.yml (no beta type)" \
  "skipping old.yml (retired template; name it in keep to restore)" \
  "Wrote 1 file(s) to acme/widget@1.0/development" \
  "Wrote 3 file(s) to acme/widget@1.0/main"
do
  if ! grep -qF -- "$expected" <<<"$out"; then
    echo "::error::missing from the sync's output: $expected"
    status=1
  fi
done

(( status == 0 )) || exit 1
