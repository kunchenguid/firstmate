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
Running umbrellas in parallel on different harnesses or models is fine and expected, one independent workspace per lab (`fm-umbrella.sh create`); consistency comes from the shared template, not from all labs sharing one harness or model.
The template exists to carry two rules every epic inherits: its stories land as PRs into `epic/<slug>` with evidence and firstmate review, and the full epic is validated by no-mistakes before it ships.
Parallel-on-different-harness never means autonomous design crews: architecture stays captain-direct tech-lead work, never delegated to a spawned scout, exactly as this skill already requires.

## Not yet built

Only the lab itself (`create`/`teardown`/`list`) is implemented.
The delegated `--epic` fan-out and aggregate status described in `docs/cross-repo-workspaces.md` section 9 are designed but not built, so the per-repo implementation hand-off is still ordinary tasks dispatched by hand.
