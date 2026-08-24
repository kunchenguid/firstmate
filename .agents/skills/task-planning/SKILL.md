---
name: task-planning
description: >-
  Agent-only procedure for turning a captain request into an inspectable implementation plan.
  Use at task intake when the request is ambiguous, cross-cutting, or large enough to benefit from explicit decomposition.
  Combines Wayfinder-style decision mapping with specification synthesis and vertical ticket decomposition, then hands execution to Firstmate's existing crew lifecycle.
  This skill owns planning artifacts and decomposition; it does not implement project code, spawn implementation crews before approval, or perform code review.
user-invocable: false
metadata:
  internal: true
---

# task-planning

This skill is Firstmate's native planning/decomposition layer.
It is inspired by the method behind Matt Pocock's Wayfinder, `to-spec`, and `to-tickets`, but it is deliberately rewritten for Firstmate's operating model.

**Do not copy Wayfinder's `implement` workflow.** Firstmate already owns implementation orchestration, crew lifecycle, worktrees, supervision, delivery mode, and merge authority.

The planning layer answers three different questions in order:

1. **Wayfinder question:** what must be decided before the implementation path is clear?
2. **Spec question:** what exactly are we agreeing to build once those decisions are resolved?
3. **Ticket question:** what independently executable vertical slices can Firstmate hand to crews, and what blocks what?

The output is a set of inspectable artifacts. The plan is not hidden reasoning.

## 1. Decide whether planning is warranted

Do not run this full workflow for every request. At intake, classify the request using evidence rather than a fixed token-expensive ritual.

At intake also inspect the target project's `docs/features/`: an existing feature directory covering this request means resume or extend that plan instead of duplicating it, and its resolved decisions are established evidence.

### Simple

Use the normal Firstmate crew lifecycle directly when all of the following are true:

- the requested behavior is already unambiguous;
- the affected area is narrow and known;
- there is one obvious implementation path;
- no meaningful architecture, data-model, migration, security, or cross-boundary decision is unresolved;
- the work can reasonably be completed by one crewmate without coordination.

Do not create Wayfinder/spec/ticket artifacts for a simple task.

### Planned

Use specification + ticket decomposition when the request is clear enough to implement but spans multiple meaningful changes, boundaries, or files, or when more than one crew may work independently.

The minimum artifact is `spec.md` plus `tickets/`.

### Wayfinder-planned

Use the full workflow when the destination is not yet clear. Signals include:

- multiple plausible architectures or implementation strategies;
- unresolved product or behavior decisions;
- greenfield work or a major feature;
- cross-cutting changes involving several subsystems;
- migrations or compatibility constraints;
- security, authorization, concurrency, or data-integrity decisions;
- uncertainty whose resolution could materially change the implementation scope;
- work that is clearly too large for one coherent agent session.

When uncertain between Planned and Wayfinder-planned, prefer the cheaper Planned path unless the unresolved uncertainty could invalidate the resulting ticket graph.

## 2. Establish the planning workspace

Before writing artifacts, allocate the Firstmate task id, choose a kebab-case `<feature-slug>` for the request, and create the feature directory inside the target project's primary clone:

```text
projects/<project>/docs/features/<feature-slug>/
  wayfinder.md   # only for Wayfinder-planned work
  spec.md
  tickets/
    T01.md
    T02.md
    ...
```

These documents live with their project so the captain can browse every planned or running feature per project in one place, and firstmate reads them back at intake and at dispatch. Writing the planning documents and design prototypes described here is hard rule 1's enumerated `task-planning` exception; nothing else under `projects/` is authorized. Leave them uncommitted working documents by default - versioning them into the repository happens only through the project's normal delivery path when the captain asks.

Record the `<project>:<feature-slug>` pair in the parent task's backlog note so runtime state stays linked to the documents.

The planning directory is evidence for the captain and for later supervision. It must contain conclusions and rationale, not hidden chain-of-thought or raw model deliberation.

## 3. Wayfinder phase: map the fog

For Wayfinder-planned work, create `wayfinder.md` before writing the implementation spec.

Record only decision-relevant information:

```markdown
# Wayfinder plan

## Goal
<one paragraph>

## Destination
<what success looks like>

## Decision map

### D01 — <decision question>
- Why it matters:
- Evidence to inspect:
- Options considered:
- Decision:
- Confidence: high|medium|low
- Consequence for implementation:

### D02 — ...

## Resolved assumptions
- ...

## Unresolved captain decisions
- ...

## Exit condition
<what must be true before this can graduate to a spec>
```

A decision is not an implementation ticket. Do not ask a crew to code a decision question when a scout, repository inspection, or captain answer can resolve it first.

Resolve decisions using Firstmate's existing mechanisms:

- repository/codebase evidence → delegate a focused `--scout` investigation;
- external/tool evidence → delegate a focused scout when appropriate;
- captain preference or product policy → use the existing decision/captain hold lifecycle;
- established project convention → cite the relevant file/document and record the conclusion.

Do not launch implementation crews while load-bearing decisions remain unresolved.

When a decision is resolved, update `wayfinder.md` rather than creating a second competing plan.

## 4. Graduate decisions into a specification

Once the destination is clear, write `spec.md`.

The spec is an implementation contract, not a transcript of the planning conversation. It should be concise enough for every ticket owner to read and complete enough that ticket owners do not need to rediscover product decisions.

Use this structure:

```markdown
# Specification

## Goal

## User-visible behavior

## Scope

## Out of scope

## Decisions

## Existing seams / integration points

## Data and migration

## Security / authorization

## Compatibility / rollout

## Acceptance criteria

## Verification strategy
```

Prefer existing seams over inventing new ones. Preserve project terminology. Explicitly record constraints that would otherwise be rediscovered by every crew.

## 5. Decompose into vertical tickets

Create `tickets/TNN.md` from the spec.

Tickets are implementation units for Firstmate crews, not architecture-layer chores.

Prefer vertical slices:

```text
GOOD:
T01 = one user-visible behavior across the necessary data/API/UI/test path

AVOID:
T01 = database only
T02 = API only
T03 = UI only
```

A ticket should contain:

```markdown
# T01 — <short title>

## Goal

## Why this slice

## Scope

## Implementation notes

## Acceptance criteria

## Verification

## Depends on
- T00 / none

## Can run in parallel with
- ...
```

Keep each ticket small enough for one crew, but large enough to produce a meaningful, testable vertical slice. Do not split merely to increase the crew count.

Every dependency must be explicit. If T02 cannot start until T01 produces a concrete seam, write `Depends on: T01` and explain the dependency briefly.

The resulting ticket graph must be acyclic unless a human explicitly approves an unusual cycle.

## 6. Ticket quality gate

Before presenting the plan, check:

- every in-scope requirement is covered by one or more tickets;
- every ticket has an observable acceptance criterion;
- every ticket has a verification method;
- dependencies are explicit and acyclic;
- no ticket is merely a database/API/UI layer without a good reason;
- no ticket is so broad that it becomes a second project;
- shared-file contention is minimized;
- unresolved decisions are not hidden inside implementation notes;
- out-of-scope items are not accidentally represented as work;
- the ticket graph is executable by Firstmate's existing dispatch lifecycle.

If a quality check fails, revise the decomposition before asking for approval.

## 7. Captain review gate

When this skill was invoked for Planned or Wayfinder-planned work, do not dispatch implementation crews merely because the artifacts were generated.

Present the captain with:

1. the planning level selected;
2. the key decisions;
3. the spec summary;
4. the ticket graph and dependencies;
5. notable risks or unresolved choices;
6. the artifact paths.

Then use Firstmate's existing decision/captain hold lifecycle for approval when the captain has not already explicitly authorized automatic execution of the resulting plan.

A captain approval of the plan authorizes implementation of the approved ticket graph only. It does not grant merge authority or override other Firstmate hard rules.

## 8. Hand off to Firstmate execution

After approval, stop planning and return to Firstmate's existing execution path.

For each ready ticket:

1. resolve its concrete delivery mode and yolo posture using the existing Firstmate intake rules;
2. file the ticket as its own backlog work item and create the normal brief at `data/<parent-id>-t<TNN>/brief.md`, embedding the ticket content and pointing at `projects/<project>/docs/features/<feature-slug>/spec.md`;
3. spawn the existing crewmate using `fm-spawn.sh` and the selected harness/profile;
4. supervise through the existing lifecycle;
5. unlock dependent tickets only after their declared predecessor is actually complete; filing tickets as separate backlog items with explicit blocked-by notes lets ordinary queue re-evaluation own this unlocking.

The parent task id owns the plan artifacts; each ticket is an ordinary task whose id is `<parent-id>-t<TNN>` (valid per `fm_task_id_creation_valid`), so teardown, supervision, and merge authority apply per ticket unchanged.

**Do not create a second dispatch system.** `task-planning` ends at an approved ticket graph; `fm-brief.sh`, `fm-spawn.sh`, supervision, delivery, and merge rules remain authoritative.

## 9. Verification is risk-based

This planning layer records verification requirements per ticket, but it does not force `no-mistakes` on every ticket.

Use the ticket's verification section to distinguish:

- routine: normal tests/checks owned by the project and crew;
- elevated: targeted review or additional test evidence;
- critical: the existing no-mistakes pipeline or another explicitly required gate.

The planner must not call an external review agent merely because a ticket exists.

## 10. Relationship to other Firstmate skills

This skill deliberately composes with, rather than replaces:

- `diagnostic-reasoning` for bug causality and reproduction;
- `captain-hold-lifecycle` for captain decisions;
- `project-management` for project lifecycle and delivery posture;
- `quota-array-dispatch` and existing harness adapters for crew selection;
- `fm-brief.sh` and `fm-spawn.sh` for actual execution.

For a reported bug, diagnosis comes first when the cause is uncertain. A confirmed diagnosis can then feed this planning skill if the fix is large enough to require decomposition.

## 11. What this skill intentionally does not import from Matt's workflow

Do not import:

- Wayfinder's `implement` phase;
- branch/worktree orchestration from another system;
- another issue tracker as the source of truth;
- another agent/crew runtime;
- mandatory planning for every task;
- mandatory code review for every ticket.

The useful imported ideas are the decision map, graduation from uncertainty to a spec, vertical ticket slicing, explicit blocking edges, and inspectable planning artifacts.
