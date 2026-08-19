# Cross-repo workspaces (design proposal)

Status: proposal. Rollout step 1 (the umbrella lab, `bin/fm-umbrella.sh`) and the design-to-backlog promote (`bin/fm-umbrella-promote.sh`, section 9 step 2a) are implemented; the `--epic` meta threading and aggregate epic status (section 9 step 2b) are not yet built.
Audience: firstmate maintainers.
This document proposes how firstmate should support a feature that spans several repositories at once, while keeping the captain close to the design and in control of the result.

## 1. The problem

Two tools sit at opposite corners of the same space.

Conductor gives the captain a separate workspace per task, each an isolated git worktree of one repository, and the captain drives the coding agent directly in that workspace: chat, watch the diff, review, open a PR, merge.
It is excellent at keeping the human close to the implementation, but a workspace is bound to a single repository, so a feature that cuts across a backend, a frontend, and a shared library cannot live in one workspace.

firstmate gives the captain one liaison that dispatches autonomous workers across many repositories in parallel, supervises them, and hands back finished PRs.
It is excellent at cross-repo scale, but the captain reaches the code through two layers of translation: intent becomes a chat message, the message becomes a brief, the brief becomes the worker's understanding.
The fidelity lost in those translations is largest exactly where the captain is needed most - design intuition, unstated constraints, "not that" - so delegating an under-specified design task feels worse than the captain doing it directly.

The gap is not that workers are weak.
The gap is that firstmate currently delegates *both* the design phase and the implementation phase, when only the implementation phase is well suited to delegation.
Design is ambiguous work; ambiguous work has a long correction loop, and every round of that loop pays the two-layer translation cost.

## 2. Design principle

Split the work by ambiguity, not by repository.

- The ambiguous phase - deciding the cross-repo contract, the shapes, the shared types - is where the captain drives directly, in one place that can see every repository at once.
- The specified phase - implementing each repository against a contract that is now concrete - is where firstmate delegates, one normal supervised task per repository.

This gives both properties the captain asked for.
Cross-repo design happens in a single session that sees all repositories, which Conductor cannot do.
Implementation stays close to the captain and under firstmate's control, because each delegated task is an ordinary firstmate ship task with the full pipeline behind it.

## 3. Why not "one task, N worktrees, N PRs"

The first sketch was `fm-spawn.sh --repos backend,frontend,shared` producing one task that owns several worktrees and opens several PRs.
Reading the pipeline shows why that is the wrong shape.

Every downstream contract assumes one worktree, one branch, one PR per task:

- `bin/fm-spawn.sh` records exactly one `worktree=<path>` line in `state/<id>.meta` and validates that single path is distinct from the primary checkout.
- `bin/fm-brief.sh` creates exactly one branch `fm/<id>` and its definition of done is one branch's landing.
- `bin/fm-teardown.sh` refuses teardown until *the* worktree's work has landed, reasoning about one branch and one PR.
- `bin/fm-pr-check.sh` records one canonical `pr=<url>` and arms one merge poll.

Fanning one task out to N of each would fork all four contracts and every safety invariant they carry (the landed-work refusal, the isolation assertion, the merge poll identity binding).
That is a large, fragile change whose only benefit is cosmetic grouping.

Instead the proposal keeps two clean constructs, neither of which breaks those invariants.

## 4. Two constructs

### 4.1 Umbrella workspace - the captain's cross-repo lab

An umbrella is a workspace, not an autonomous task.
It exists so the captain (or one agent the captain drives directly) can design across several repositories with every repository checked out side by side.

Layout under the firstmate home:

```
umbrellas/<umbrella-id>/
  DESIGN.md            the cross-repo contract being designed; the durable output
  AGENTS.md            how the repos relate, for whichever agent works here
  repos/
    backend/           worktree of the backend repo (projects/backend)
    frontend/          worktree of the frontend repo (projects/frontend)
    shared/            worktree of the shared repo (projects/shared)
```

Properties:

- Each `repos/<name>/` is a real worktree of that repo, created directly with `git worktree add --detach` against the `projects/<name>` clone at a clean default-branch base, distinct from every primary checkout - the same isolation firstmate already guarantees for a single task worktree. (The treehouse pool is deliberately not used; that is the supervised-crew path, not the lab path.)
- No autonomous worker is launched and no merge poll is armed.
  The umbrella is a laboratory; there is nothing for teardown or pr-check to reason about because there is no branch to land yet.
- The captain enters the umbrella and runs their own coding-agent session there (`cd umbrellas/<umbrella-id> && claude`), or firstmate spawns one worker scoped to the whole umbrella dir for a design/scout deliverable.
  AGENTS.md already treats direct captain work in a pane as authoritative, so this is a first-class mode, not a bypass.

The umbrella's job is finished when it produces a **concrete contract that can land first**: an OpenAPI spec, a proto file, a shared types package, a schema migration - something mergeable into the shared repo on its own.
That artifact, once on `main`, is what turns every remaining per-repo task from ambiguous into specified.

The umbrella is scratch like a scout worktree: once DESIGN.md and any landed contract exist, its `repos/` worktrees are discardable under the same unresolved-decision completion gate scouts already use.

### 4.2 Epic - the delegated implementation fan-out

An epic is a grouping over several ordinary single-repo ship tasks that share one DESIGN.md and cross-link their PRs.
Each child is a normal firstmate task: one worktree, one branch `fm/<child-id>`, one PR, the full delivery pipeline.
Nothing in spawn, brief, teardown, or pr-check changes per child.

The epic adds only three things on top of ordinary tasks:

1. **Shared contract injection.** Each child brief points at the same landed DESIGN.md / contract artifact and copies its acceptance criteria verbatim, so no child re-derives the design.
2. **Dependency ordering.** The contract-bearing repo (usually the shared library) is a child that must land before the dependent children dispatch; this is the existing backlog dependency mechanism, not new machinery.
3. **Aggregate status.** The captain sees "epic X: 1 of 3 PRs merged" instead of tracking three unrelated task ids; this is a thin projection over the children's existing state.

Because children are ordinary tasks, the captain keeps full firstmate control of the result: per-repo review, per-repo `no-mistakes` or `direct-PR` posture, per-repo merge authority.

## 5. The full flow

1. **Umbrella (you-drive design).** Firstmate stands up `umbrellas/<umbrella-id>/` with worktrees of the involved repos and an empty DESIGN.md.
   The captain drives one session across all of them and produces DESIGN.md plus a contract artifact.
2. **Land the contract first.** The contract artifact ships as its own ordinary task into the shared repo and merges before anything depends on it.
   Now the contract is real code on `main`, not prose in a brief.
3. **Epic (delegate implementation).** Firstmate opens an epic whose children are one ordinary ship task per remaining repo, each brief anchored to the landed contract, dispatched when its dependency (the contract) has landed.
4. **Control the result.** Each child runs the normal pipeline; the captain reviews and merges each PR under its project's posture.

The captain drives exactly the phase that needs them and delegates exactly the phase that is safe to delegate.

This flow is packaged as the harness-agnostic public epic pipeline - the `/epic-*` skills under `skills/` (see `skills/README.md`): `/epic-new` -> `/epic-scaffold` -> `/epic-plan` -> `/epic-review` -> `/epic-handoff` -> `/epic-ship`.
`/epic-new` stands up the umbrella lab; `/epic-handoff` wraps `bin/fm-umbrella-promote.sh` (section 9 step 2a); `/epic-ship` wraps `bin/fm-epic-ship.sh`.
Each skill's `SKILL.md` is the single owner of its step, and the AGENTS.md that `bin/fm-umbrella.sh` writes into a lab points the design agent at that chain regardless of harness.

## 6. Concrete changes required

### 6.1 New: `bin/fm-umbrella.sh`

Creates and tears down umbrella workspaces.

- `fm-umbrella.sh create <umbrella-id> --repos <name>,<name>,...`
  - For each named repo, resolved directly to its clone at `projects/<name>`, create a worktree with `git worktree add --detach` at the fetched default-branch tip into `umbrellas/<umbrella-id>/repos/<name>/`.
  - Write a skeleton `DESIGN.md` and a cross-repo `AGENTS.md` describing the repo relationships.
  - Record `umbrellas/<umbrella-id>/umbrella.meta` (deliberately under `umbrellas/`, a sibling of `data/`, NOT `state/<id>.meta`, so no single-repo task/watcher/teardown/pr-check scan ever sees it) with `kind=umbrella` and one `worktree_<name>=<path>` line per repo.
  - Do **not** arm a poll, launch a worker, or create a branch. This is a lab.
- `fm-umbrella.sh teardown <umbrella-id>`
  - Completion gate: proceed only once DESIGN.md exists and is non-empty; `--force` bypasses that gate.
  - Return each worktree, discarding the scratch `repos/` checkouts even if dirty after printing each one's `git status` so nothing is discarded silently, and keep DESIGN.md as the durable artifact.

`kind=umbrella` is new and is deliberately invisible to every single-repo mechanism, so no existing invariant is touched.

### 6.2 New: epic grouping

Prefer to build this on the existing backlog rather than a new store.

- Add an optional `epic=<umbrella-id>` field to child task meta and a `--epic <id>` flag threaded through `fm-brief.sh` and `fm-spawn.sh` (recorded, not behavior-changing per child).
- `fm-brief.sh` gains an `--anchor-design <path>` input that injects a "Design contract" section pointing at the landed DESIGN.md / artifact and requires the crewmate to treat it as the spec.
- Aggregate status is a read-only projection: extend `bin/fm-fleet-snapshot.sh` to group tasks sharing an `epic=` value and report their combined PR state. No new watcher, no new daemon.

### 6.3 Unchanged

`fm-teardown.sh`, `fm-pr-check.sh`, and the per-task branch/PR contract are untouched, because every delegated child is still a one-worktree, one-branch, one-PR task.
That is the point of the two-construct split.

## 7. Keeping delegation faithful (control mechanisms)

These make the delegated phase behave as well as the captain doing it directly.

- **Contract-first, always.** Never delegate a per-repo task whose contract has not already landed as code. If the contract is still prose, the work belongs back in the umbrella.
- **Plan-gate the ambiguous edges.** A child brief may require the worker to post a short plan and stop for approval before writing code, using the existing `needs-decision` / `--resolve-key` flow. Reading a plan is cheap; reviewing a wrong PR is not.
- **DESIGN.md is a contract, not a reference.** Acceptance criteria in each child brief are copied verbatim from DESIGN.md so there is nothing left to infer.
- **A recall threshold.** If a child needs steering more than about twice for the same misunderstanding, that is the signal the work was under-specified, not that the worker is weak - pull it back into the umbrella and design the missing piece directly rather than steering again.

## 8. Open questions

- **Umbrella worker vs pure you-drive.** Should firstmate ever spawn an autonomous worker scoped to the whole umbrella (a cross-repo scout), or is the umbrella strictly captain-driven? Proposed: allow a scout-style umbrella worker for investigation, but keep contract *decisions* captain-held via the completion gate.
- **Contract that cannot land independently.** Some designs have no cleanly separable contract artifact (tightly coupled changes across repos). For those the umbrella may need to produce coordinated ready branches instead of one landed contract; this is a harder case and is out of scope for the first cut.
- **Cross-repo PR linking.** Whether to auto-insert "part of epic X" cross-links in each child PR body, or leave that to the captain. Proposed: opt-in, off by default.

## 9. Rollout

1. Ship `fm-umbrella.sh create`/`teardown` and the `kind=umbrella` metadata. This alone delivers the you-drive cross-repo lab (the Conductor-beating capability) with zero risk to existing task flow.
2. a. Promote a designed epic into the home: move `plans/<epic-dir>/` into `data/plans/` and seed its stories into the backlog, deriving each backlog id and `[<epic>]` tag from the story frontmatter so they match the story files by construction (no orphans, one epic). Built as `bin/fm-umbrella-promote.sh` - idempotent, fail-closed, and it stops at the sign-off gate rather than signing, cutting branches, or dispatching; see `bin/fm-umbrella-promote.sh --help`.
   b. Add `--epic` / `--anchor-design` threading and the fleet-snapshot grouping for aggregate epic status. Not yet built.
3. Consider the coordinated-ready-branches case (open question) only if real usage demands it.

The first step is small and self-contained, and it is the one that closes the capability gap; the rest is convenience over machinery firstmate already has.
