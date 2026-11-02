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
- `skip` — optional list of template paths this repository does not want.

The sync targets the repository's **default branch** (its current version line's `main`); the
`development` line receives the same files through that repository's post-merge chore, never
directly.

## Check types

| Type | Trigger | Actions |
|---|---|---|
| `screenshots` | pull request | `run`, `diff`, `comment`, `chore` |
| `lifecycle` | pull request | `run` (one matrix leg per loader) |
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

## Adding a type

1. Add `<product>/types/<type>/<action>/action.yml` (composite; another product type must not be able
   to reach it).
2. Add `.github/workflows/type-<type>.yml` (`on: workflow_call`).
3. Add one job to `.github/workflows/dispatch.yml` gated on
   `contains(fromJSON(needs.resolve.outputs.types), '<type>')` — `jobs.<id>.uses` cannot be built from
   a matrix, so the type list is enumerated once, there.
4. List it in the relevant `consumers.jsonl` entries.
