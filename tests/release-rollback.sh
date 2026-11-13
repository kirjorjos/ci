#!/usr/bin/env bash
# Pins the rollback in the release workflow's prepare step: a version that step bumped onto a
# PR-only branch must go back when the job fails before a promotion pull request carries the bump.
#
# The damage is invisible from every angle. The bump is the one write the step makes with the app
# token, so it never appears in a pull request diff; the run left behind is red, and nobody reads
# the side effects of a red run; and the next dispatch cheerfully bumps whatever number it finds
# again. Three failed prepares left RegistryExtractor at 0.0.4 with nothing published, and the
# first release of the repository was therefore v0.0.5.
#
# The script under test is extracted from release.yml rather than copied, because a test of a copy
# keeps passing after the workflow changes. Nothing here touches GitHub: `gh` and `git` are stubs
# that answer only the calls the step makes, pull request creation fails on purpose, and the
# assertion is that the stub's build.gradle.kts holds the version the step found.
#
#   bash tests/release-rollback.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
workflow=$root/minecraft-mods/templates/.github/workflows/release.yml

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
state=$work/state
mkdir -p "$state" "$work/bin"

# The prepare step's Python, dedented. The step is a `run: |` block, so the file on disk is indented
# by the block's own indentation and every line has to be shifted back by the `python3` line's.
prepare=$work/prepare.py
awk '
  /name: Preflight, bump and promote$/ { step = 1 }
  step && /python3 - <<.PY.$/ {
    grab = 1
    match($0, /^ */)
    indent = RLENGTH
    next
  }
  grab {
    line = substr($0, indent + 1)
    if (line == "PY") exit
    print line
  }
' "$workflow" > "$prepare"

if ! grep -qF 'put back' "$prepare"; then
  echo "::error::$workflow: the prepare step no longer carries the rollback this test pins"
  exit 1
fi
python3 -m py_compile "$prepare" || {
  echo "::error::$workflow: the prepare step's Python does not compile once extracted"
  exit 1
}

# The branch the step finds, and a changelog with pending notes: enough to plan a release.
cat > "$state/build.gradle.kts" <<'EOF'
plugins {
    id("java")
}

group = "net.example"
version = "0.0.5"
EOF
printf '# Changelog\n\nAdd a thing\n' > "$state/CHANGELOG.md"
printf '{"release": {"docs": false}}\n' > "$state/metadata.json"
: > "$state/puts.jsonl"

cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env python3
"""A stand-in for `gh` that answers only what release.yml's prepare step asks.

The branch's files live in FAKE_STATE. `build.gradle.kts` is read, written and read back, so the
version the step leaves behind is what the test asserts on; a write is accepted only when its `sha`
matches the file, which is the API's own guard against a lost update.

Every content write is appended to `puts.jsonl` with the version and the token it used, which is
what lets the test say "bumped, then put back" instead of merely "ended at the right version".
"""
import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

state = pathlib.Path(os.environ["FAKE_STATE"])
writes_log = state / "puts.jsonl"

argv = sys.argv[1:]
if not argv:
    sys.exit("stub gh: no arguments")
mode = argv.pop(0)


def die(message):
    sys.stderr.write(f"gh: {message}\n")
    sys.exit(1)


def blob_sha(data):
    return hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()


def emit(text, jq):
    if jq is None:
        sys.stdout.write(text)
        return
    done = subprocess.run(["jq", "-r", jq], input=text, text=True, capture_output=True)
    if done.returncode != 0:
        sys.stderr.write(done.stderr)
        sys.exit(1)
    sys.stdout.write(done.stdout)


if mode == "label":
    sys.exit(0)

if mode == "run":
    # No post-merge chore in flight, so the step has nothing to wait for.
    sys.stdout.write("[]\n")
    sys.exit(0)

if mode == "pr":
    command = argv[0] if argv else ""
    if command == "list":
        sys.stdout.write("[]\n")
        sys.exit(0)
    if command == "create":
        # The failure every rollback exists for: the bump is on the branch and nothing will carry it.
        die("pull request creation failed (HTTP 403)")
    die(f"unsupported pr command {command!r}")

if mode != "api":
    die(f"unsupported command {mode!r}")

method = "GET"
path = None
body = None
raw = False
jq = None
i = 0
while i < len(argv):
    arg = argv[i]
    if arg == "--jq":
        jq = argv[i + 1]
        i += 2
    elif arg in ("-X", "--method"):
        method = argv[i + 1].upper()
        i += 2
    elif arg == "-H":
        raw = "vnd.github.raw" in argv[i + 1]
        i += 2
    elif arg == "--input":
        body = json.loads(pathlib.Path(argv[i + 1]).read_text())
        i += 2
    elif arg.startswith("-"):
        i += 1
    else:
        path = path or arg
        i += 1

if path is None:
    die("no API path")

contents = re.fullmatch(r"repos/[^/]+/[^/]+/contents/([^?]+)(?:\?ref=.*)?", path)
if contents:
    # Flat on purpose: `.github/metadata.json` is the only nested path the step reads.
    target = state / pathlib.Path(contents.group(1)).name
    if method == "PUT":
        text = base64.b64decode(body["content"]).decode("utf-8")
        current = target.read_bytes() if target.is_file() else b""
        if body.get("sha") != blob_sha(current):
            die(f"{target.name}: sha does not match the file (HTTP 409)")
        target.write_text(text, encoding="utf-8")
        found = re.search(r'^version[ \t]*=[ \t]*"(.*)"[ \t]*$', text, re.M)
        with writes_log.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({
                "version": found.group(1) if found else None,
                "token": os.environ.get("GH_TOKEN"),
            }) + "\n")
        sys.stdout.write('{"commit": {"sha": "commit-new"}}\n')
        sys.exit(0)
    if method != "GET":
        die(f"nothing handles {method} {path}")
    if not target.is_file():
        die("Not Found (HTTP 404)")
    data = target.read_bytes()
    if raw:
        sys.stdout.write(data.decode("utf-8"))
        sys.exit(0)
    emit(json.dumps({
        "sha": blob_sha(data),
        "content": base64.b64encode(data).decode(),
        "encoding": "base64",
    }), jq)
    sys.exit(0)

die(f"nothing handles {method} {path}")
STUB

cat > "$work/bin/git" <<'STUB'
#!/usr/bin/env bash
# The read-only git questions the prepare step asks, answered without a repository: the development
# branch exists, the tag for the version about to be released does not, and the branch has commits
# since the last release.
case "$*" in
  *--exit-code*--tags*) exit 1 ;;
  *--exit-code*--heads*) exit 0 ;;
  *for-each-ref*) exit 0 ;;
  log\ --oneline*) echo "abc1234 Add the thing"; exit 0 ;;
  *ls-remote*) printf 'base-sha\trefs/heads/1.19.2/development\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$work/bin/gh" "$work/bin/git"

out=$(cd "$work" && env \
  REPO=acme/widget \
  VERSIONS_RAW=1.19.2 \
  BUMP=patch \
  DRY_RUN=false \
  GH_TOKEN=stub-default-token \
  APP_TOKEN=stub-app-token \
  FAKE_STATE="$state" \
  PATH="$work/bin:$PATH" \
  python3 "$prepare" 2>&1)
status=$?
printf '%s\n' "$out"
printf '%s\n' "$out" > "$work/out.log"

if (( status == 0 )); then
  echo "::error::the prepare step exited 0 even though creating its pull request failed"
  exit 1
fi

python3 - "$state" "$work/out.log" <<'PY'
import json
import pathlib
import re
import sys

state, out_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
problems = []

writes = [json.loads(line) for line in (state / "puts.jsonl").read_text().splitlines() if line.strip()]
versions = [write["version"] for write in writes]
if versions != ["0.0.6", "0.0.5"]:
    problems.append(
        f"content writes were {versions}, expected ['0.0.6', '0.0.5'] "
        "(the bump, then the same version put back)"
    )
for write in writes:
    if write["token"] != "stub-app-token":
        problems.append(
            f"a content write used token {write['token']!r}; only the app token bypasses the "
            "PR-only rule on the branch"
        )

text = (state / "build.gradle.kts").read_text()
found = re.search(r'^version[ \t]*=[ \t]*"(.*)"[ \t]*$', text, re.M)
final = found.group(1) if found else None
if final != "0.0.5":
    problems.append(f"the branch ends at version {final!r}, not the 0.0.5 the step found")

out = out_file.read_text()
for expected in ("::error::prepare failed:", "version 0.0.5 put back"):
    if expected not in out:
        problems.append(f"missing from the prepare step's output: {expected}")
if "the version stays incremented" in out:
    problems.append("the step reported that it could not restore the version")

if problems:
    for problem in problems:
        print(f"::error::{problem}")
    sys.exit(1)
print("rollback ok: 0.0.6 written, pull request refused, 0.0.5 put back")
PY
