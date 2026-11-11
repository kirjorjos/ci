# ci

Shared check types, actions and GitHub hygiene files for my projects, plus the workflow that keeps
them in sync.

Product types live in their own folder (`minecraft-mods/` today). A repository opts in by appearing
in [`consumers.jsonl`](consumers.jsonl); nothing is inherited implicitly, and this repository is
deliberately **not** named `.github` so that one product type's templates can never leak into
another's repositories.

Spec: `.notes/shared-ci-repo-spec.md` in the minecheck repo.

## What a consumer gets

| Shared | Lands at | Mechanism |
|---|---|---|
| `<product>/templates/**` | the same relative path | pushed on every commit here |
| `<product>/labels.jsonl` | labels in the repo | `gh label create --force` during the same sync |
| `<product>/types/*` | nothing — actions are called by reference | `uses: kirjorjos/ci/<product>/types/<type>/<action>@<product>/v1` |

`<product>/templates/.github/workflows/` is where a consumer's CI actually lives. Every file there
is overwritten on each sync, so a consumer's copy is never the place to make a change:

| File | What it is |
|---|---|
| `minecheck-ci.yml` | the entry workflow: calls `dispatch.yml`, which reads this repository's registry and runs the check types listed for that repository |
| `minecheck-slot.yml` | when the per-version test-slot scheduler runs |
| `pr-validation.yml` | a pull request's matrix: wait for the shared rules verdict, take this version line's slot, run the shared `matrix` type on the head, hand the slot back, and report the `Merge gate` check a ruleset requires |
| `pr-screenshot-comment.yml` | the mismatch table and its required check, once a validation run finishes |
| `post-merge-screenshot-sync.yml` | the post-merge chore: write the merged run's captures into `tests/baselines/` and comment the source issue |
| `release.yml` | the release loop: bump, promote, tag, build, stage and publish one line at a time |

Nothing under a consumer's `.github/workflows/` is hand-written any more, and a file edited there is
overwritten on the next sync. What used to differ between version lines is now either metadata (the
jar prefix, the variants a line ships, the staging directory) or the registry (which release targets
publish).

A repository that appears in the registry but is not wired for a piece of this — no baselines, no
slot, a different build — says so with `skip` rather than by keeping a divergent copy. MineCam takes
the product's templates but lists neither `matrix` nor `screenshots` and skips `release.yml`, so it
gets the entry workflow with its `build` and `issues` checks, and nothing that would try to run a
suite or a release it has no configuration for.

One case is decided by the dispatcher rather than the entry file: a pull request whose base is a
`<version>/main` line is a **promotion**, and it resolves to no types. Its tests already ran on the
development line, the release job guarantees the three facts that make it legitimate, and `main`
validates again on its post-merge push. The run still appears, with one `resolve` job and a notice
saying why, so a promotion PR shows no matrix and nothing can sit on it until it expires.

### Pull request shape

`rules` is the one type that runs on `pull_request_target` instead of `pull_request`. It judges
`<version>/development` (source must be `<version>/development-issue-<n>` of the same version),
`<version>/main` (release job only) and everything else (a plain contribution: any source, forks
included). An invalid pull request is commented on, closed and failed; a loader dropped from the
metadata file is announced; a merged development pull request records `Fixed in <version>` on its
issue.

It needs that trigger because it writes: a fork's `pull_request` token is read-only, so those
comments and closes would silently fail. It never checks the pull request out - the loader lists it
compares are read through the contents API at the base and head SHAs - so the write token never
meets PR content. The type is gated to this one event, so nothing runs twice per push.

## Consumer configuration

`.github/metadata.json` in the consumer is the only configuration any shared workflow reads. Nothing
above carries a repository name, a loader list, a path or a Gradle property: those come from this
file or from the layout the product already assumes.

| Key | Read by | Meaning |
|---|---|---|
| `loaders` | `matrix` plan, `rules` | loader ids, `[a-z0-9][a-z0-9-]*`; one test job and one `tests/baselines/<id>/` tree each |
| `build.jdk` | `matrix` | JDK the line builds with; default `17` |
| `build.checkTask` | `matrix` | Gradle task covering formatting plus the plugin's own tests; default `checkModule` |
| `release` | the consumer's `release.yml`, `release-assets` | jar prefix, name format, variants (`-deobf`) and staging directory |

Every key is optional apart from `loaders`, and each default reproduces what the workflow ran
before the key existed, so a line that declares none of them behaves exactly as it did. The release
loop reads `release.prefix`, `release.variants` and `release.artifactsDir` to decide which jars must
be staged and which names belong to the tag: a line that ships one jar and a line that ships a
`-deobf` twin run the same check.

## Registry

`consumers.jsonl`, one object per line:

```jsonl
{"repo":"kirjorjos/Minecheck","product":"minecraft-mods","types":["screenshots","lifecycle"]}
```

- `repo` — `owner/name`.
- `product` — whose `templates/` and `labels.jsonl` the repository takes.
- `types` — check types dispatched on its pull requests. May be empty: templates still sync.
- `release` — release targets, read by the consumer's own release workflow: `gh` today, `cf` and
  `modrinth` when those are wired. A target the array omits runs nothing, so adding one is a
  registry change rather than a workflow edit. Absent or empty means the release publishes nowhere,
  which the workflow refuses at the point it would tag.
- `keep` — optional list of template paths this repository takes even though no type in `types`
  implies them, given as the path under `templates/`. It restores a retired template, or takes one a
  line wants without its type; no consumer needs it today.
- `skip` — optional list of template paths this repository does not want, given as the path under
  `templates/` (`.github/workflows/release.yml`). Only the files no type implies have to be named here;
  everything else follows from `types` and [`templates.jsonl`](#which-templates-a-consumer-gets).
- `remove` — optional list of repository paths to delete from every version line on each sync. This
  is how a retired workflow leaves `*/main`: that branch takes no ordinary pull request, so the only
  thing that can take a file away from it is a write carrying the app's bypass. Absent is the steady
  state, so a second sync deletes nothing.

### Which templates a consumer gets

`<product>/templates.jsonl` says which check type owns a template, one object per line:

```jsonl
{"path":".github/workflows/post-merge-screenshot-sync.yml","types":["screenshots"]}
```

- Absent from the file — the template belongs to no type and ships to every consumer.
- `"types": ["screenshots"]` — ships only to a consumer whose `types` include `screenshots`.
- `"types": []` — retired: no type implies it, so only a `keep` entry brings it back.

`skip` still wins over all three, so a repository can refuse a file that one of its types would
otherwise bring. The point is that a consumer no longer has to enumerate the templates of the types
it omits, which is where a stale `skip` entry used to come from.

`tests/template-sets.sh` pins the resulting set for every consumer against
`tests/template-sets.tsv`. A template that starts or stops reaching a repository has to be recorded
there - `bash tests/template-sets.sh --update` - and reviewed with the change that caused it; the
test fails otherwise, and it runs on every pull request.

`tests/sync-loop.sh` covers the other half by running the sync against a stub `gh`: which templates
become blobs, what each branch's tree adds and deletes, and the commit it writes. A loop that
installs nothing reports "already matches this commit", so the sets alone cannot catch it.

The sync targets **every version line** — each `<version>/main` and `<version>/development`, plus
the repository's default branch. A workflow file only triggers on a branch that carries it (a push
runs the file on the pushed branch, a pull request runs its base branch's copy), so writing only the
default branch would leave every older Minecraft line with no shared checks at all.

## Check types

| Type | Trigger | Actions |
|---|---|---|
| `screenshots` | pull request | `run`, `diff`, `comment`, `chore` |
| `lifecycle` | pull request | `run` (one matrix leg per loader) |
| `scripts` | pull request | `audit` |
| `issues` | issue and issue-comment events | `version-check`, `confirm-version` |
| `rules` | pull request, on `pull_request_target` | `check` |
| `matrix` | not dispatched: called by a consumer's validation workflow, after its test slot | none — the type is a multi-job workflow, not an action |
| `release-assets` | release workflows, by reference | `check` |
| `slot` | not dispatched: called by a consumer's own jobs, plus the synced scheduler | `run` (`take`, `take-chore`, `release`, `event`) |

`matrix` is not dispatched either, for the opposite reason: it is the expensive half of a pull
request, and it has to run inside a run that already holds that version line's test slot. A
dispatched copy would be a second, unslotted writer on the same line — which is what the slot exists
to prevent. The caller is the type's template, so listing `matrix` in `types` brings both.

`release-assets` is not dispatched: it asserts a staged release set, so it belongs in a release job,
not on a PR. Call it directly:

```yaml
- uses: kirjorjos/ci/minecraft-mods/types/release-assets/check@minecraft-mods/v1
  with:
    minecraft-version: "1.19.2"
    version: "2.0.0"
    prefix: "MineCheck-"
```

### The test slot

One expensive run at a time per Minecraft version line. The queue is an orphan branch
`ci-queue/<version>` **in the consumer repository**, holding a single `queue.json`; every write is a
read-modify-write whose `git push` is the compare-and-swap, so a lost race retries instead of losing
an entry.

Ordering is `(tier, seq)`: the post-merge chore and a release hold at `-1`, same-repo pull requests
at `0`, forks at `1`. A fork is promoted after 45 minutes or three same-repo grants, so a busy day
cannot starve it. A grant carries a 90-minute lease, and the synced scheduler reclaims a holder
whose run died without releasing — and, after five minutes, a grant with no queued or running run
left behind it: a run can end between taking the grant and its `release` job, and the lease would
then hold a line for nobody.

A consumer wires two things:

1. The synced `minecheck-slot.yml` runs the scheduler on pull-request close, push to
   `*/development`, a ten-minute cron, and manual dispatch.
2. Its own matrix calls `slot/run` with `mode: take` before the work and `mode: release` after it
   (`if: always()`), because the required context has to be reported by the pull request's own run —
   a dispatched run's checks attach to the default branch and could never satisfy it.

```yaml
- uses: kirjorjos/ci/minecraft-mods/types/slot/run@minecraft-mods/v1
  env:
    GH_TOKEN: ${{ steps.app.outputs.token }}
  with:
    mode: take
    pr: ${{ github.event.pull_request.number }}
    sha: ${{ github.event.pull_request.head.sha }}
    target: ${{ github.event.pull_request.base.ref }}
    fork: ${{ github.event.pull_request.head.repo.full_name != github.repository }}
```

### Issue events

The generated entry workflow also triggers on `issues` and `issue_comment`, which is what the
`issues` type needs. Every type workflow gates itself on the event that produced it, because the
dispatcher runs on all of them: `screenshots`, `lifecycle` and `scripts` only start on a
`pull_request` or a `push`, `issues` only on its own events. Adding a type means deciding that gate.

`issues/version-check` validates the affected-version field against the repository's
`<version>/development` branches, applies `versions/<mc>`, and closes an issue naming a line that
does not exist. It also applies `unaddressed` on `opened`, so the tag means "CI has not said
anything yet".

`issues/confirm-version` labels an issue when a **collaborator** comments `Confirmed in <version>`
(comma-separated for several). The association is read from the event payload, so it needs no extra
API scope and a stranger's comment is ignored without a lookup. A version with no development
branch is skipped and reported in the step summary rather than labelled. Either action clears
`unaddressed`, because CI has now said something about the issue.

### Script coverage

`scripts/audit` warns on the pull request when a file under `tests/scripts/` is referenced by
nothing: the file name has to appear somewhere outside the script itself, which covers every real
wiring (a Gradle task, the coordinator, a driver file, another script, a docs page) while still
catching a script that looks like coverage and runs nowhere. One comment, upserted by marker and
deleted when the tree is clean, and the job never fails.

### Ruleset contexts

`Ruleset contexts` (scheduled, and dispatchable) closes the other way a gate goes quiet. It reads
every consumer's rulesets and compares each `required_status_checks[].context` against the check
names that repository's workflows can actually report, following a job's `uses:` into a reusable
workflow so a caller's `<job> / <callee job>` counts as a provider. A matrix name is matched as a
pattern, because the matrix expands it into one check per leg.

It fails on a required context no job reports (naming the ruleset, the context and the workflows it
searched), warns about a ruleset that is `disabled` since that gates nothing, and lists the contexts
that are reported but required nowhere. A literal name is not what GitHub reports: the job's `name:`
is, falling back to its id, which is why the check is about jobs rather than workflows.

Reading another repository's rulesets needs `administration: read` on the app, and its Actions event
policies need `administration: write` - that endpoint has no read-only form - so `rulesets.yml` asks
for write and one token carries both halves. `scripts/rulesets.rb` can also be run against a
checkout and exported lists (`--workflows`, `--rulesets`, `--policies`), which is how the matching
rules are exercised without a ruleset to break.

## Adding a type

1. Add `<product>/types/<type>/<action>/action.yml` (composite; another product type must not be able
   to reach it). A type that is only ever a reusable workflow (`matrix`) ships no action and skips
   steps 2-3.
2. Add `.github/workflows/type-<type>.yml` (`on: workflow_call`).
3. Add one job to `.github/workflows/dispatch.yml` gated on
   `contains(fromJSON(needs.resolve.outputs.types), '<type>')` — `jobs.<id>.uses` cannot be built from
   a matrix, so the type list is enumerated once, there.
4. List it in the relevant `consumers.jsonl` entries.
