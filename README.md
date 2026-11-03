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

`<product>/templates/.github/workflows/minecheck-ci.yml` is the one generated workflow a consumer
carries. It is identical everywhere and overwritten on every sync: it calls `dispatch.yml`, which
reads this repository's registry and runs the check types listed for that repository.

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
- `skip` — optional list of template paths this repository does not want.

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
| `release-assets` | release workflows, by reference | `check` |

`release-assets` is not dispatched: it asserts a staged release set, so it belongs in a release job,
not on a PR. Call it directly:

```yaml
- uses: kirjorjos/ci/minecraft-mods/types/release-assets/check@minecraft-mods/v1
  with:
    minecraft-version: "1.19.2"
    version: "2.0.0"
    prefix: "MineCheck-"
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

## Adding a type

1. Add `<product>/types/<type>/<action>/action.yml` (composite; another product type must not be able
   to reach it).
2. Add `.github/workflows/type-<type>.yml` (`on: workflow_call`).
3. Add one job to `.github/workflows/dispatch.yml` gated on
   `contains(fromJSON(needs.resolve.outputs.types), '<type>')` — `jobs.<id>.uses` cannot be built from
   a matrix, so the type list is enumerated once, there.
4. List it in the relevant `consumers.jsonl` entries.
