#!/usr/bin/env python3
"""The per-version test slot. Design: .notes/test-slot-design.md.

One expensive run at a time per Minecraft version line. State lives in an orphan branch
`ci-queue/<mc>` as a single `queue.json`. Every writer goes through `Line.update`, whose `git push`
is the compare-and-swap: a lost race is a rejected push and a retry, never a lost entry.

The slot gates *inside* a run rather than launching one. That is forced by the ruleset: the only
required context on `<mc>/development` is produced by the pull request's own `pull_request_target`
run, and a dispatched run's checks attach to the default branch's sha, so a dispatched matrix could
never satisfy a PR's required check.

Subcommands:
  event                 scheduler entry point; reads the Actions event payload
  take --mc --pr --sha  enqueue, then block until this entry holds the slot
  release --mc --pr     give the slot back and grant the next entry
  reconcile [--mc M]    prune, report positions, grant the head of the queue
  status [--mc M]       print a line's queue
  hold --mc M           hold the slot for a release
  free --mc M           drop a hold or a stuck holder
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

# Tuned in .notes/test-slot-design.md §5: a fork entry is promoted once it has waited this long or
# been overtaken this many times, so a busy same-repo day cannot starve it.
AGING_MINUTES = 45
AGING_GRANTS = 3
# Above the matrix's observed 30m34s worst case and the chore's 90-minute re-render timeout. A run
# that dies without releasing is recovered by this expiring, never by its own cleanup.
LEASE_MINUTES = 90
# A grant is only meaningful while the run that took it is still alive. A run can end between `take`
# and its `release` job - truncated, cancelled, or never scheduling the rest of its jobs - and then
# nothing hands the slot back, so the lease holds the line with nobody on the other end. The waiter
# is inside `take` seconds before the grant, so a run that is gone this much later is not coming
# back. Seen on 2026-11-09: a post-merge run took 1.19.2's slot, ended 98 seconds later, and blocked
# the line until 19:55.
PICKUP_MINUTES = 5

TIERS = {"chore": -1, "release": -1}
FORK_TIER = 1
BOT = re.compile(r"\[bot\]$")
VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
CHORE_NAME = "Post-merge screenshot baselines"
UNVERSIONED = "unversioned"  # the shared line for targets that name no Minecraft version


class SlotError(RuntimeError):
    pass


# --------------------------------------------------------------------------------------------------
# Environment and small helpers


def repo() -> str:
    return os.environ.get("REPO") or os.environ["GITHUB_REPOSITORY"]


def token() -> str:
    return os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""


def now() -> float:
    return time.time()


def iso(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text: str) -> float:
    return (
        datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
        .replace(tzinfo=datetime.timezone.utc)
        .timestamp()
    )


def gh(args: list[str], payload: dict | None = None, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        ["gh", *args],
        input=json.dumps(payload) if payload is not None else None,
        text=True,
        capture_output=True,
        env={**os.environ, "GH_TOKEN": token()},
    )
    if check and proc.returncode != 0:
        raise SlotError(f"gh {args[0]} failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc


def api(path: str, method: str = "GET", payload: dict | None = None) -> dict:
    args = ["api", "-X", method, path]
    if payload is not None:
        args += ["--input", "-"]
    proc = gh(args, payload=payload)
    return json.loads(proc.stdout) if proc.stdout.strip() else {}


def log(message: str) -> None:
    print(f"[slot] {message}", flush=True)


def warn(message: str) -> None:
    print(f"::warning::{message}", flush=True)


def emit(name: str, value: str) -> None:
    """Publish the resolved version line to the calling step's outputs."""
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


# --------------------------------------------------------------------------------------------------
# Pure ordering logic


def empty_state(mc: str) -> dict:
    return {"mc": mc, "seq": 0, "holder": None, "entries": [], "last_runs": {}}


def effective_tier(entry: dict, at: float) -> int:
    tier = int(entry.get("tier", 0))
    if tier <= 0:
        return tier
    waited = (at - parse_iso(entry["enqueued_at"])) / 60.0
    if waited >= AGING_MINUTES or int(entry.get("overtaken", 0)) >= AGING_GRANTS:
        return 0
    return tier


def ordered(entries: list[dict], at: float) -> list[dict]:
    return sorted(entries, key=lambda e: (effective_tier(e, at), int(e.get("seq", 0))))


def line_of(target: str) -> str:
    """The slot a ref belongs to: its version line, or the shared unversioned line."""
    head = target.split("/")[0]
    return head if VERSION.match(head) else UNVERSIONED


def make_entry(kind: str, spec: dict, state: dict) -> dict:
    state["seq"] = int(state.get("seq", 0)) + 1
    return {
        "id": f"e-{state['seq']}",
        "kind": kind,
        "pr": spec.get("pr", ""),
        "sha": spec.get("sha", ""),
        "head_repo": spec.get("head_repo", ""),
        "fork": bool(spec.get("fork", False)),
        "target": spec.get("target", ""),
        "compare": spec.get("compare", ""),
        "tier": TIERS.get(kind, FORK_TIER if spec.get("fork") else 0),
        "seq": int(state["seq"]),
        "overtaken": 0,
        "enqueued_at": iso(now()),
    }


# --------------------------------------------------------------------------------------------------
# The queue branch


class Line:
    def __init__(self, mc: str):
        self.mc = mc
        self.branch = f"ci-queue/{mc}"
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix=f"slot-{re.sub(r'[^a-z0-9]+', '-', mc)}-"))

    def _url(self) -> str:
        return f"https://x-access-token:{token()}@github.com/{repo()}.git"

    def _git(self, args: list[str], check: bool = True) -> subprocess.CompletedProcess:
        proc = subprocess.run(args, cwd=str(self.dir), text=True, capture_output=True)
        if check and proc.returncode != 0:
            raise SlotError(f"git {args[1] if len(args) > 1 else ''} failed: {proc.stderr.strip()}")
        return proc

    def _ensure(self) -> None:
        if (self.dir / ".git").exists():
            return
        self._git(["git", "init", "-q"])
        self._git(["git", "remote", "add", "origin", self._url()])
        self._git(["git", "config", "user.name", "ci-pipeline-commits[bot]"])
        self._git(["git", "config", "user.email", "ci-pipeline-commits[bot]@users.noreply.github.com"])

    def read(self) -> tuple[dict, str | None]:
        self._ensure()
        if self._git(["git", "fetch", "-q", "--depth=1", "origin", self.branch], check=False).returncode != 0:
            return empty_state(self.mc), None
        parent = self._git(["git", "rev-parse", "FETCH_HEAD"]).stdout.strip()
        blob = self._git(["git", "show", "FETCH_HEAD:queue.json"], check=False)
        if blob.returncode != 0:
            return empty_state(self.mc), parent
        return json.loads(blob.stdout), parent

    def update(self, decide, attempts: int = 6) -> dict:
        for _ in range(attempts):
            state, parent = self.read()
            new = decide(json.loads(json.dumps(state)))
            if new is None:
                return state
            if parent:
                self._git(["git", "reset", "-q", "--hard", parent])
            else:
                self._git(["git", "rm", "-q", "--cached", "--ignore-unmatch", "queue.json"], check=False)
            (self.dir / "queue.json").write_text(json.dumps(new, indent=2, sort_keys=True) + "\n")
            self._git(["git", "add", "queue.json"])
            tree = self._git(["git", "write-tree"]).stdout.strip()
            commit_args = ["git", "commit-tree", tree, "-m", f"slot({self.mc}): update"]
            if parent:
                commit_args += ["-p", parent]
            commit = self._git(commit_args).stdout.strip()
            push = self._git(["git", "push", "-q", "origin", f"{commit}:refs/heads/{self.branch}"], check=False)
            if push.returncode == 0:
                return new
            log(f"{self.branch} moved under us; retrying")
            time.sleep(1)
        raise SlotError(f"could not write {self.branch} after {attempts} attempts")


def known_lines() -> list[str]:
    url = f"https://x-access-token:{token()}@github.com/{repo()}.git"
    proc = subprocess.run(
        ["git", "ls-remote", "--heads", url, "refs/heads/ci-queue/*"], text=True, capture_output=True
    )
    lines = []
    for row in proc.stdout.splitlines():
        _, ref = row.split("\t", 1)
        lines.append(ref[len("refs/heads/ci-queue/") :])
    return sorted(set(lines))


# --------------------------------------------------------------------------------------------------
# API side effects


def pr_info(number: int | str) -> dict | None:
    proc = gh(
        ["api", f"repos/{repo()}/pulls/{number}",
         "--jq", "{state, sha: .head.sha, draft, repo: .head.repo.full_name}"],
        check=False,
    )
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def run_alive(sha: str) -> bool:
    """Whether any workflow run for this commit is still queued or running."""
    try:
        runs = api(f"repos/{repo()}/actions/runs?head_sha={sha}&per_page=50").get("workflow_runs") or []
    except (SlotError, json.JSONDecodeError) as error:
        # A lookup that failed says nothing about the run, so it never reclaims on doubt.
        warn(f"could not list the runs for {sha[:7]}: {error}")
        return True
    live = {"queued", "in_progress", "waiting", "pending", "requested"}
    return any(run.get("status") in live for run in runs)


def put_check(sha: str, status: str, conclusion: str | None, title: str, summary: str) -> None:
    """Best effort: a fork's head commit is not in this repository, so its check cannot attach."""
    if not sha:
        return
    try:
        existing = gh(
            ["api", f"repos/{repo()}/commits/{sha}/check-runs?check_name=Test%20queue",
             "--jq", ".check_runs[0].id // empty"],
            check=False,
        ).stdout.strip()
        payload = {
            "name": "Test queue",
            "head_sha": sha,
            "status": status,
            "output": {"title": title, "summary": summary},
        }
        if conclusion:
            payload["conclusion"] = conclusion
        if existing:
            api(f"repos/{repo()}/check-runs/{existing}", method="PATCH", payload=payload)
        else:
            api(f"repos/{repo()}/check-runs", method="POST", payload=payload)
    except (SlotError, json.JSONDecodeError) as error:
        warn(f"could not report the Test queue check on {sha[:7]}: {error}")


# --------------------------------------------------------------------------------------------------
# State transitions


def prune(state: dict, force: bool) -> bool:
    changed = False
    holder = state.get("holder")
    if holder:
        lease_until = parse_iso(holder["lease_until"])
        # A holder written before grants recorded their start is still judged: its lease began when
        # the grant did.
        granted = (
            parse_iso(holder["granted_at"])
            if holder.get("granted_at")
            else lease_until - LEASE_MINUTES * 60
        )
        # A hold names no commit because no run takes it; only a granted run can be orphaned.
        abandoned = (
            bool(holder.get("sha"))
            and now() - granted > PICKUP_MINUTES * 60
            and not run_alive(holder["sha"])
        )
        if force:
            log(f"force-clearing the holder ({holder.get('kind')})")
            changed = True
        elif lease_until <= now():
            log(f"the holder's lease expired at {holder['lease_until']}")
            changed = True
        elif abandoned:
            log(
                f"the {holder.get('kind')} grant of {holder['sha'][:7]} is orphaned: no run of that "
                f"commit is queued or running, so nothing will release it before "
                f"{holder['lease_until']}"
            )
            changed = True
        if changed:
            state["holder"] = None

    keep = []
    seen_chore: dict[str, int] = {}
    for entry in state.get("entries", []):
        if entry["kind"] == "pr":
            info = pr_info(entry["pr"])
            if not info or info.get("state") != "open" or info.get("sha") != entry["sha"]:
                log(f"dropping PR #{entry['pr']}: closed, merged, or its head moved")
                changed = True
                continue
        elif entry["kind"] == "chore":
            # Same identity rule as `enqueue`: work that already holds the slot is not also
            # waiting in it. This also repairs a queue written before that guard existed.
            live = state.get("holder") or {}
            if live.get("kind") == "chore" and live.get("sha") == entry["sha"]:
                log(f"dropping chore {entry['sha'][:7]}: it already holds the slot")
                changed = True
                continue
            previous = seen_chore.get(entry["target"])
            if previous is not None and previous > int(entry["seq"]):
                changed = True
                continue
            seen_chore[entry["target"]] = int(entry["seq"])
        keep.append(entry)
    state["entries"] = keep
    return changed


def report_positions(state: dict) -> None:
    at = now()
    queue = ordered(state.get("entries", []), at)
    for index, entry in enumerate(queue):
        ahead_forks = sum(1 for other in queue[:index] if effective_tier(other, at) > effective_tier(entry, at))
        put_check(
            entry["sha"],
            "queued",
            None,
            f"queued: position {index + 1} of {len(queue)}",
            f"{ahead_forks} fork entr{'y' if ahead_forks == 1 else 'ies'} ahead. The matrix starts when "
            "this version line's slot is free.",
        )


def reconcile(mc: str, force: bool = False) -> None:
    """Prune, refresh positions, and grant the head of the queue if the slot is free."""
    line = Line(mc)

    def decide(state: dict):
        changed = prune(state, force)
        if state.get("holder") is None:
            head = ordered(state.get("entries", []), now())
            if head:
                entry = head[0]
                state["entries"] = [e for e in state["entries"] if e["id"] != entry["id"]]
                state["holder"] = {
                    "id": entry["id"],
                    "kind": entry["kind"],
                    "pr": entry.get("pr", ""),
                    "sha": entry["sha"],
                    "granted_at": iso(now()),
                    "lease_until": iso(now() + LEASE_MINUTES * 60),
                }
                if not entry.get("fork"):
                    for waiting in state["entries"]:
                        if waiting.get("fork"):
                            waiting["overtaken"] = int(waiting.get("overtaken", 0)) + 1
                log(f"granted {mc} to {entry['kind']} {entry.get('pr') or entry['sha'][:7]}")
                changed = True
        return state if changed else None

    report_positions(line.update(decide))


def enqueue(kind: str, mc: str, spec: dict) -> None:
    def same(entry: dict) -> bool:
        """Whether this entry (or holder) is the same piece of work as `spec`.

        A line holds one version's work, so the commit alone identifies a chore; a pull request
        is identified by its number. Target is deliberately not compared: it is what `mc` was
        derived from, and on the shared unversioned line two refs can name the same commit.
        """
        if entry.get("kind") != kind:
            return False
        if kind == "pr":
            return str(entry.get("pr")) == str(spec.get("pr"))
        return entry.get("sha") == spec.get("sha")

    def decide(state: dict):
        before = json.dumps(state, sort_keys=True)
        # A chore is enqueued twice for one push: once by the scheduler (`event`) and once by the
        # post-merge workflow's own `take-chore`. Two entries for the same commit would leave the
        # second one granted after the first releases, a phantom holder nobody is waiting on and
        # nobody releases, so they are collapsed by commit. Different pushes stay separate: each
        # one carries baselines the other does not.
        state["entries"] = [e for e in state.get("entries", []) if not same(e)]
        # The same commit can also already be the *holder*: whichever of the scheduler and
        # `take-chore` wins the grant empties `entries`, so the collapse above finds nothing and
        # this append would re-queue work already running. That entry is granted again the moment
        # the holder releases, and nothing ever takes or releases it - a 90-minute block.
        if not same(state.get("holder") or {}):
            state["entries"].append(make_entry(kind, spec, state))
        return None if json.dumps(state, sort_keys=True) == before else state

    Line(mc).update(decide)
    log(f"queued {kind} {spec.get('pr') or spec.get('sha', '')[:7]} on {mc}")


def drop_pr(mc: str, number: int | str) -> None:
    def decide(state: dict):
        keep = [e for e in state.get("entries", []) if not (e["kind"] == "pr" and str(e.get("pr")) == str(number))]
        if len(keep) == len(state.get("entries", [])):
            return None
        state["entries"] = keep
        return state

    Line(mc).update(decide)


def holds(mc: str, pr: int | str, sha: str) -> bool:
    """Whether this caller's commit holds the slot.

    A chore has no pull request to compare: the post-merge workflow cannot know the merged number
    before the slot is granted, so it passes none and the commit is the whole identity.
    """
    holder = Line(mc).read()[0].get("holder") or {}
    return (not str(pr) or str(holder.get("pr")) == str(pr)) and holder.get("sha") == sha


def release(mc: str, pr: int | str, sha: str) -> None:
    def decide(state: dict):
        holder = state.get("holder") or {}
        # Same identity rule as `holds`: a caller that named no pull request is identified by its
        # commit alone. A mismatch is not an error - a re-push already handed the slot on.
        if (str(pr) and str(holder.get("pr")) != str(pr)) or holder.get("sha") != sha:
            return None
        state["holder"] = None
        if str(pr):
            state.setdefault("last_runs", {})[str(pr)] = {"sha": sha, "at": iso(now())}
        return state

    Line(mc).update(decide)
    put_check(sha, "completed", "success", "released", f"{mc} slot released")
    log(f"{mc}: released by PR #{pr}")
    reconcile(mc)


def take(mc: str, kind: str, spec: dict, minutes: int = 90) -> int:
    """Enqueue, then block until this entry holds the slot. Any writer may grant: the CAS decides."""
    enqueue(kind, mc, spec)
    deadline = time.monotonic() + minutes * 60
    while True:
        reconcile(mc)
        if holds(mc, spec["pr"], spec["sha"]):
            put_check(
                spec["sha"], "in_progress", None, "running",
                f"the {mc} slot is running this pull request.",
            )
            log(f"{mc}: PR #{spec['pr']} now holds the slot")
            return 0
        state, _ = Line(mc).read()
        queue = ordered(state.get("entries", []), now())
        position = next((i + 1 for i, e in enumerate(queue) if str(e.get("pr")) == str(spec["pr"])), None)
        holder = state.get("holder") or {}
        log(
            f"{mc}: waiting"
            + (f" at position {position}" if position else " (not in the queue)")
            + f"; slot held by {holder.get('kind') or 'nobody'}"
        )
        if time.monotonic() >= deadline:
            warn(f"{mc}: PR #{spec['pr']} was still queued after {minutes} minutes")
            return 1
        time.sleep(20)


# --------------------------------------------------------------------------------------------------
# Events


def on_pull_request(payload: dict) -> None:
    pr = payload["pull_request"]
    target = pr["base"]["ref"]
    mc = line_of(target)
    if payload["action"] == "closed":
        drop_pr(mc, pr["number"])
    reconcile(mc)


def on_push(payload: dict) -> None:
    ref = payload["ref"].removeprefix("refs/heads/")
    if not ref.endswith("/development"):
        return
    message = ((payload.get("head_commit") or {}).get("message") or "").splitlines()
    if message and message[0].startswith("chore: sync screenshot baselines"):
        log("this push is the chore's own; not queueing it")
        return
    # The same two guards as the post-merge workflow's `slot` job, and they have to stay identical:
    # that job is what takes and releases a granted chore. A push it skips (a shared-CI sync, say)
    # still arrives here, and queueing a chore for it would be granted within seconds at tier -1 and
    # then held for the whole 90-minute lease by nobody at all, blocking the line.
    pusher = (
        (payload.get("pusher") or {}).get("name")
        or (payload.get("sender") or {}).get("login")
        or ""
    )
    if BOT.search(pusher):
        log(f"pushed by {pusher}, which the chore skips; not queueing it")
        return
    mc = line_of(ref)
    sha = payload["after"]
    enqueue("chore", mc, {"pr": "", "sha": sha, "target": ref, "compare": ""})
    reconcile(mc)


def hold(mc: str, kind: str, pr: str) -> None:
    def decide(state: dict):
        state["holder"] = {
            "id": f"h-{int(now())}",
            "kind": kind,
            "pr": pr,
            "sha": "",
            "lease_until": iso(now() + 120 * 60),
        }
        return state

    Line(mc).update(decide)
    log(f"{mc}: held for {kind} {pr}".strip())


def free(mc: str) -> None:
    holder = Line(mc).read()[0].get("holder")
    if not holder:
        log(f"{mc}: nothing to free")
        reconcile(mc)
        return

    def decide(state: dict):
        if not state.get("holder"):
            return None
        state["holder"] = None
        return state

    Line(mc).update(decide)
    log(f"{mc}: freed the {holder.get('kind')} holder")
    reconcile(mc)


# --------------------------------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("event", help="handle the Actions event in GITHUB_EVENT_PATH")

    rec = sub.add_parser("reconcile", help="prune, report positions and grant")
    rec.add_argument("--mc", default=None)
    rec.add_argument("--force", action="store_true")

    take_p = sub.add_parser("take", help="enqueue and wait for the slot")
    take_p.add_argument("--mc", default="")
    take_p.add_argument("--kind", default="pr", choices=sorted(TIERS) + ["pr"])
    take_p.add_argument("--pr", required=True)
    take_p.add_argument("--sha", required=True)
    take_p.add_argument("--target", default="")
    take_p.add_argument("--compare", default="")
    take_p.add_argument("--fork", default="false")
    take_p.add_argument("--head-repo", default="")
    take_p.add_argument("--minutes", type=int, default=90)

    rel = sub.add_parser("release", help="give the slot back")
    rel.add_argument("--mc", default="")
    rel.add_argument("--pr", required=True)
    rel.add_argument("--sha", default="")
    rel.add_argument("--target", default="")

    status_p = sub.add_parser("status", help="print a line's queue")
    status_p.add_argument("--mc", default=None)

    hold_p = sub.add_parser("hold", help="hold the slot for a release")
    hold_p.add_argument("--mc", required=True)
    hold_p.add_argument("--pr", default="")

    free_p = sub.add_parser("free", help="drop a hold or a stuck holder")
    free_p.add_argument("--mc", required=True)

    args = parser.parse_args()

    if args.command == "event":
        event = os.environ.get("GITHUB_EVENT_NAME", "")
        payload = json.loads(pathlib.Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        force = os.environ.get("FORCE", "").lower() == "true"
        if event == "pull_request_target":
            on_pull_request(payload)
        elif event == "push":
            on_push(payload)
        else:
            for mc in known_lines():
                reconcile(mc, force=force)
        return 0

    if args.command == "reconcile":
        for mc in [args.mc] if args.mc else known_lines():
            reconcile(mc, force=args.force)
        return 0

    if args.command == "take":
        # An expression cannot slice a ref, so the caller passes the target and the line is
        # resolved here (which is also what maps an unversioned target onto its shared line).
        mc = args.mc or line_of(args.target)
        emit("mc", mc)
        return take(
            mc,
            args.kind,
            {
                "pr": args.pr,
                "sha": args.sha,
                "target": args.target,
                "compare": args.compare,
                "fork": args.fork.lower() == "true",
                "head_repo": args.head_repo,
            },
            minutes=args.minutes,
        )

    if args.command == "release":
        mc = args.mc or line_of(args.target)
        emit("mc", mc)
        release(mc, args.pr, args.sha)
        return 0

    if args.command == "status":
        for mc in [args.mc] if args.mc else known_lines():
            state, _ = Line(mc).read()
            print(json.dumps({"mc": mc, **state}, indent=2, sort_keys=True))
        return 0

    if args.command == "hold":
        hold(args.mc, "release", args.pr)
        return 0

    if args.command == "free":
        free(args.mc)
        return 0

    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SlotError as error:
        print(f"::error::{error}", flush=True)
        sys.exit(1)
