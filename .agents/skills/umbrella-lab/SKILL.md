---
name: umbrella-lab
description: >-
  Agent-only procedure for Firstmate cross-repo umbrella design labs.
  Use before standing up, tearing down, or reasoning about a workspace that checks out several project repos side by side so the captain can design a feature spanning them.
  Owns the choice between an umbrella lab and ordinary single-repo tasks, the prerequisite and contract-first discipline, and what is not yet built.
user-invocable: false
metadata:
  internal: true
---

# umbrella-lab

Use this procedure before standing up, tearing down, or reasoning about a cross-repo umbrella design lab.
An umbrella is a captain-driven workspace, not an autonomous task: it launches no worker, arms no merge poll, and creates no branch.
`docs/cross-repo-workspaces.md` is the single owner of the rationale and the full flow.
`bin/fm-umbrella.sh --help` is the single owner of the exact commands, flags, and layout.
This skill owns only the decision of when to reach for the lab and the discipline around it.

## When an umbrella is the right construct

Reach for an umbrella only when the ambiguous phase of the work is a design that spans several repos at once.
The test is ambiguity, not repository count: the captain needs every repo visible while deciding the cross-repo contract - the shapes, the shared types, the API - and a per-brief delegation would lose that fidelity.

Do not stand up an umbrella when:

- The work fits one repo, even if it is large or hard.
  That is an ordinary ship task.
- The cross-repo contract is already concrete.
  Skip straight to ordinary per-repo tasks anchored to that contract.
- The captain only needs an investigation or a written design, with no side-by-side checkout.
  That is a scout.

When intake looks like a cross-repo feature and the design is still ambiguous, name the umbrella option to the captain in plain language before creating one.

## Prerequisite

Every `--repos` name must resolve to a git clone at `projects/<name>`.
If a named repo is not cloned, load `project-management` and register it first; an umbrella checks out existing clones, it does not fetch new ones.

## Contract-first discipline

The umbrella's only durable output is `umbrellas/<umbrella-id>/DESIGN.md`; the `repos/` worktrees are scratch, exactly like a scout worktree.
The design is finished when it produces a concrete contract that can land first on its own - an OpenAPI spec, a proto file, a shared types package, a schema migration.
Ship that contract as its own ordinary task and let it merge before any dependent per-repo work is delegated.
Never delegate a per-repo task whose contract is still prose; if it has not landed as code, the work belongs back in the lab.
Teardown keeps `DESIGN.md` and discards the scratch worktrees, and follows the same unresolved-decision completion gate scouts use (`decision-hold-lifecycle`).

## Epic-design output standard

The lab's design is the start of an epic, so its durable output conforms to your fleet's epic template and epic-convention, not to whatever harness produced it.
`DESIGN.md`, and any `epic.md` scaffolded from it, must match that shared template; the template is the standard, not the harness.
Point at your fleet's own epic template and convention rather than copying its shape here, because that template is its single owner.
The public `/epic-*` skills drive that standard end to end - `/epic-new` -> `/epic-scaffold` -> `/epic-plan` -> `/epic-review` -> `/epic-handoff` -> `/epic-ship` - and each skill's SKILL.md is the single owner of its step; the AGENTS.md that `bin/fm-umbrella.sh` writes into the lab points the design agent at that chain, harness-agnostically.
Running umbrellas in parallel on different harnesses or models is fine and expected, one independent workspace per lab (`fm-umbrella.sh create`); consistency comes from the shared template, not from all labs sharing one harness or model.
The template exists to carry two rules every epic inherits: its stories land as PRs into `epic/<slug>` with evidence and firstmate review, and the full epic is validated by no-mistakes before it ships.
Parallel-on-different-harness never means autonomous design crews: architecture stays captain-direct tech-lead work, never delegated to a spawned scout, exactly as this skill already requires.

## From a designed epic to queued backlog work

When the umbrella's design produces a delegable epic - a `plans/<epic-dir>/epic.md` plus `stories/*.md` (the harness-agnostic standard) - promote it with `bin/fm-umbrella-promote.sh <umbrella-id>`, run with `FM_HOME` set to this home.
It moves the epic dir into `data/plans/` and seeds every story into the backlog, deriving each backlog id and `[<epic>]` tag from the story frontmatter so they match the story files by construction.
That construction is the whole point: a hand-seed whose ids or tags drift from the story files (`lh-01`/`[lh]` against story files `LH-01`/`aimica-learning-hub`) leaves orphan tasks and a doubled epic in the dashboard, which is exactly what two home firstmates did by hand.
The helper is idempotent and fail-closed - all validation runs before any write, a re-run is a safe no-op, and a mismatched prior seed is refused rather than duplicated - and it STOPS at the sign-off gate: it never signs the epic, cuts a branch, or dispatches.
Those remain human/firstmate steps, and the helper prints them: review `DESIGN.md` and sign `epic.md`, `bin/fm-epic-branch.sh create <slug> <repo>` per involved repo, dispatch the queued stories, then tear down the umbrella.
`bin/fm-umbrella-promote.sh --help` owns the exact contract.

## Not yet built

The aggregate epic status described in `docs/cross-repo-workspaces.md` section 9 - an `epic=` grouping projected over child task state - is designed but not built, so once the stories are queued, dispatch and progress tracking are ordinary per-repo tasks.
