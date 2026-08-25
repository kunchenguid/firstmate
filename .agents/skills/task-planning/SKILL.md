---
name: task-planning
description: >-
  Orchestrator of Firstmate's planning family (task-grill, task-design, task-planning).
  Use at ship-task intake when authorized work spans multiple meaningful changes or crews, or when unresolved decisions could materially change what is built.
  Classifies the request, routes non-Simple work through task-grill and optional task-design, owns the wayfinder/spec/ticket artifacts, and hands each approved ticket to the ordinary brief/spawn lifecycle.
  This skill does not implement project code, interrogate requirements, build prototypes, spawn implementation crews before approval, or perform code review.
user-invocable: false
metadata:
  internal: true
---

# task-planning

This skill is the orchestrator of Firstmate's planning family.
It classifies each ship request, routes work to the right family member, owns the planning artifacts, and ends at an approved ticket graph handed to Firstmate's existing crew lifecycle.
It is inspired by the method behind Matt Pocock's Wayfinder, `to-spec`, and `to-tickets`, but it is deliberately rewritten for Firstmate's operating model.

**Do not copy Wayfinder's `implement` workflow.**
Firstmate already owns implementation orchestration, crew lifecycle, worktrees, supervision, delivery mode, and merge authority.

## 1. The planning family

Each family member owns exactly one contract, and every other mention of it stays a one-line cross-reference.

- `task-grill` owns requirements interrogation: the design tree, frontier rounds, the facts-versus-decisions discipline, the hard gate, and the `grill.md` decision log.
- `task-design` owns throwaway prototypes that answer exactly one design question each, built and reviewed through Lavish.
- `task-planning`, this skill, owns classification, the wayfinder index, the specification, ticket decomposition, the ticket quiz, the recursion gate, and the dispatch handoff.

Non-Simple work always flows `task-grill` first, then optional `task-design`, then this skill's spec and tickets.

## 2. Classify at intake

Do not run this full workflow for every request.
At intake, classify the request using evidence rather than a fixed token-expensive ritual.

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

The minimum artifact set is `spec.md` plus `tickets/`.

### Wayfinder-planned

Use the full workflow when the destination is not yet clear.
Signals include:

- multiple plausible architectures or implementation strategies;
- unresolved product or behavior decisions;
- greenfield work or a major feature;
- cross-cutting changes involving several subsystems;
- migrations or compatibility constraints;
- security, authorization, concurrency, or data-integrity decisions;
- uncertainty whose resolution could materially change the implementation scope;
- work that is clearly too large for one coherent agent session.

When uncertain between Planned and Wayfinder-planned, prefer the cheaper Planned path unless the unresolved uncertainty could invalidate the resulting ticket graph.

### The grill gate

Every non-Simple classification routes through `task-grill` before any downstream planning artifact is written, and this skill may not proceed past it until that skill's frontier is exhausted and the captain confirms shared understanding; `task-grill` owns that gate.

## 3. Establish the planning workspace

Before writing artifacts, allocate the Firstmate task id, choose a kebab-case `<feature-slug>` for the request, and create the feature directory inside the target project's primary clone:

```text
projects/<project>/docs/features/<feature-slug>/
  grill.md       # owned by task-grill
  design/        # prototypes owned by task-design
  wayfinder.md   # only for Wayfinder-planned work
  spec.md
  tickets/
    T01.md
    T02.md
    ...
```

These documents live with their project so the captain can browse every planned or running feature per project in one place, and firstmate reads them back at intake and at dispatch.
Writing the planning documents and design prototypes described here is hard rule 1's enumerated `task-planning` exception; nothing else under `projects/` is authorized.
Leave them uncommitted working documents by default - versioning them into the repository happens only through the project's normal delivery path when the captain asks.

Record the `<project>:<feature-slug>` pair in the parent task's backlog note so runtime state stays linked to the documents.

The planning directory is evidence for the captain and for later supervision.
It must contain conclusions and rationale, not hidden chain-of-thought or raw model deliberation.

## 4. Wayfinder phase: index the decisions

For Wayfinder-planned work, maintain `wayfinder.md` from before grilling starts until the last ticket dispatches.
Interrogation itself belongs to `task-grill`; this phase organizes what interrogation produces instead of repeating it.

### Fog of war

Some questions cannot yet be stated sharply enough to answer or schedule.
Record them under a `Not yet specified` section rather than splitting them into tickets or forcing premature decisions.
They graduate onto the decision map when the frontier reaches them.
The test is a single question: can this be stated as a sharp question now?

### Map-as-index

`wayfinder.md` is an index only.
Each decision's substance lives in exactly one place: the `grill.md` decision log while unsettled, the spec's Decisions section once graduated, or a prototype's recorded verdict.
An index entry names the decision, gives its current status, and points at that single place.

```markdown
# Wayfinder plan

## Goal
<one paragraph>

## Destination
<what success looks like>

## Not yet specified
<questions too fuzzy to ask yet; each graduates when it can be stated sharply>

## Decision map

### D01 - <decision question>
- Status: open | settled | discarded
- Substance: <pointer to the one place this decision's detail lives>
- Consequence for implementation:

### D02 - ...

## Exit condition
<what must be true before this graduates to a spec>
```

Update index entries whenever a decision moves or settles; never let `wayfinder.md` grow a second copy of any substance.

### Dispatch shape of non-code work

A decision is not an implementation ticket.
Map every pre-ticket work item onto its real dispatch shape:

| Work item | Dispatch | Who waits |
| --- | --- | --- |
| research question | focused `--scout` investigation | nobody; runs autonomously |
| design question | `task-design` prototype | the captain reviews |
| preference, policy, or trade-off | `task-grill` round or captain hold | the captain answers |
| manual work outside the codebase | captain checklist or ordinary crew task | depends on the work |

Whether an unknown is a fact to find or a decision to ask is `task-grill`'s facts-versus-decisions boundary.
Do not launch implementation crews while load-bearing decisions remain unsettled.

## 5. Graduate into a specification

Once the destination is clear, write `spec.md`.
The spec is an implementation contract, not a transcript of the planning conversation.
It should be concise enough for every ticket owner to read and complete enough that ticket owners do not need to rediscover product decisions.

### Seams first

Prefer existing seams over inventing new ones.
Choose the fewest seams that can carry all the user stories, and place each seam as high in the architecture as it will reach.
Confirm the seam choice with the captain, through the existing decision/captain hold lifecycle, before writing `spec.md`; a wrong seam invalidates every ticket cut against it.

### Template

```markdown
# Specification

## Goal

## User stories
<numbered and extensive; drafting rules below>

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

Two drafting rules bind every spec:

- the user-story list is numbered and extensive, one story per capability, so every ticket traces back to at least one story and every story back to settled decisions;
- the spec carries no file paths and no code snippets, with one exception: a validated prototype snippet that encodes a decision more precisely than prose may appear, explicitly noted as coming from the prototype that validated it.
- the no-paths rule binds the spec alone: tickets carry concrete file paths and surface lists because they are execution contracts, so keep path detail out of the spec and push it down into the tickets that need it.

Preserve project terminology.
Explicitly record constraints that would otherwise be rediscovered by every crew.

## 6. Decompose into vertical tickets

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
# T01 - <short title>

## Goal

## Why this slice

## Produces

## Consumers

## Touched surfaces

## Explicitly out of scope

## Locked decisions

## Evidence anchors

## Regression guards

## Scope

## Implementation notes

## Acceptance criteria

## Verification

## Depends on
- T00 / none

## Can run in parallel with
- ...
```

The seven structural fields between the slice's identity and its notes are mandatory, and each exists because omitting it has already cost a follow-up PR:

- `Produces` names the single value, state, or behavior change this slice creates, concretely enough to search the codebase for its other users.
- `Consumers` lists every existing place that reads, displays, counts, sorts, filters, joins, or stores that value, found by sweeping the project structure before the ticket is written.
  A ticket whose value touches existing seats never leaves this field empty; when the value is genuinely local, write the one line saying why instead.
- `Touched surfaces` carries the concrete file paths, modules, and subsystems expected to change, including every consumer listed above; the spec stays path-free precisely because this field owns paths at ticket level.
- `Explicitly out of scope` names neighboring surfaces the ticket deliberately leaves alone, so their absence later reads as a decision rather than a blind spot.
- `Locked decisions` records choices already settled by the captain, grill, or spec, each pointing at where it was settled, so crews implement instead of reopening.
- `Evidence anchors` points at the symbols, tests, or fixtures where implementation and verification start.
- `Regression guards` names the existing tests or checks covering the touched surfaces that must keep passing.

The producer-consumer rule behind `Produces` and `Consumers`: a ticket that creates or changes a value must name every existing place that reads, displays, counts, sorts, filters, joins, or stores that value.
Those seats are structural facts found by sweeping, not judgment calls, so finding them is planning work that belongs in the ticket, never discovery left for the crew.
A crew that lands a produced value while known seats still read the old shape has not finished the ticket.

A ticket markdown file carries no status field - execution state lives in the backlog as separate work items with blocked-by edges, and consumers such as gootte join tickets by `<parent-id>-t<TNN>` id.

Keep each ticket small enough for one crew, but large enough to produce a meaningful, testable vertical slice.
Do not split merely to increase the crew count.
The size ceiling is one fresh agent context window per ticket: if the honest work cannot fit one clean context, the ticket is too big.

Every dependency must be explicit.
If T02 cannot start until T01 produces a concrete seam, write `Depends on: T01` and explain the dependency briefly.
The resulting ticket graph must be acyclic unless a human explicitly approves an unusual cycle.

### Wide refactors: expand, migrate, contract

A mechanical change with codebase-wide blast radius, such as a rename, an interface migration, or a dependency swap, must never be one ticket and must never interleave its phases.
Decompose it in three stages:

1. expand - introduce the new mechanism alongside the old, behind a spec-chosen seam;
2. migrate - move call sites in independent batches, one batch per ticket;
3. contract - remove the old mechanism in a final ticket, only after the last migration lands.

### Terminal review ticket

Every approved ticket graph MUST end with a terminal captain-review ticket blocked by all other tickets in the graph.
Dispatch it last, handing the captain the landed result together with the graph's accumulated evidence.
Light feedback means the existing crew fixes it inline and updates the docs to match reality.
Major feedback means a new parent plan through the recursion gate, not an ever-growing patch series.

## 7. Ticket quality gate

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
- the graph ends with the required terminal captain-review ticket;
- every ticket would pass the recursion gate today: one coherent change, no unresolved decisions, one context window;
- the ticket graph is executable by Firstmate's existing dispatch lifecycle.

The seven structural fields carry their own gate checks on top:

- every producing ticket names its consumers; an empty `Consumers` field fails the gate unless the ticket carries its one-line genuine-locality justification;
- `Touched surfaces` covers every listed consumer, so no seat that reads the produced value is left unowned;
- deliberate exclusions appear under `Explicitly out of scope`, never nowhere;
- locked decisions point at where they were settled, and evidence anchors plus regression guards resolve to real code and real tests.

If a quality check fails, revise the decomposition before asking for approval.

## 8. Ticket-to-code contrast review

Between the quality gate and the captain quiz, contrast every ticket against the actual codebase structure.
The quiz judges judgment; this step verifies the facts a structural sweep can settle mechanically, and the two stay separate.

Split the sweep work by feature size:

- a plan of two to three tickets: firstmate performs the sweep directly with structure queries against the target project;
- a larger graph, or one spanning several subsystems: commission a dedicated scout whose report carries the per-ticket contrast evidence, then fold its findings back into the tickets before the quiz.

Check mechanically, per ticket:

- every claimed consumer exists in the code where the ticket says it does;
- every place the codebase actually reads, displays, counts, sorts, filters, joins, or stores the produced value appears under `Consumers`;
- every `Touched surfaces` path resolves;
- every `Evidence anchors` and `Regression guards` entry resolves to real code and a real test or check.

Ask the captain only what the sweep cannot answer: whether an explicit exclusion is the right call, and whether a newly discovered seat changes the plan.
Findings are fixed by revising the tickets and re-running the gate - never by planning to explain gaps in the brief later.
A ticket that passes this review but still sends its crew researching scope it should already cover, or re-deciding a choice recorded as settled, is evidence the review failed: the crew stops and escalates, and firstmate repairs the ticket instead of patching the brief.

## 9. Captain review: the ticket quiz

When this skill was invoked for Planned or Wayfinder-planned work, do not dispatch implementation crews merely because the artifacts were generated.

Present the captain with:

1. the planning level selected;
2. the key decisions;
3. the spec summary;
4. the ticket graph and dependencies;
5. notable risks or unresolved choices;
6. the artifact paths.

Before asking for approval, run the ticket quiz on the proposed breakdown and iterate until the captain approves:

- granularity: is each slice the right size?
- blocking edges: does every dependency reflect reality, or is some ordering invented?
- merge or split: which tickets are really one change wearing two numbers?

Revise the decomposition and repeat the quiz across as many rounds as the graph needs.

Then use Firstmate's existing decision/captain hold lifecycle for approval when the captain has not already explicitly authorized automatic execution of the resulting plan.

A captain approval of the plan authorizes implementation of the approved ticket graph only.
It does not grant merge authority or override other Firstmate hard rules.

## 10. Recursion gate at dispatch

Re-judge the section 2 complexity gate at EVERY dispatch, not only at intake.
Before any ticket is briefed or spawned, ask the classification question again against everything learned since.

A ticket that now spans multiple meaningful changes, or that carries unresolved decisions, stops being a ticket: it becomes its own parent feature and runs the same family pipeline of `task-grill`, then optional `task-design`, then this skill.
Give it a new `<feature-slug>` under the project's `docs/features/`, file it as its own parent task, and let its own decomposition produce `<parent-id>-t<TNN>` children.

Dispatching an overgrown ticket anyway is precisely the failure this gate exists to prevent.

## 11. Hand off to Firstmate execution

After approval, stop planning and return to Firstmate's existing execution path.

For each ready ticket:

1. run the recursion gate;
2. resolve its concrete delivery mode and yolo posture using the existing Firstmate intake rules;
3. file the ticket as its own backlog work item and create the normal brief at `data/<parent-id>-t<TNN>/brief.md` by passing the ticket file to `fm-brief.sh --ticket <projects/<project>/docs/features/<feature-slug>/tickets/TNN.md>`, which inserts the ticket body verbatim into the brief's task slot - never re-elaborate, paraphrase, or summarize it - and point at `projects/<project>/docs/features/<feature-slug>/spec.md`;
4. spawn the existing crewmate using `fm-spawn.sh` and the selected harness/profile;
5. supervise through the existing lifecycle;
6. unlock dependent tickets only after their declared predecessor is actually complete; filing tickets as separate backlog items with explicit blocked-by notes lets ordinary queue re-evaluation own this unlocking.

The parent task id owns the plan artifacts; each ticket is an ordinary task whose id is `<parent-id>-t<TNN>` (valid per `fm_task_id_creation_valid`), so teardown, supervision, and merge authority apply per ticket unchanged.
The terminal captain-review ticket files and dispatches like any other ticket once its blockers complete.

**Do not create a second dispatch system.**
`task-planning` ends at an approved ticket graph; `fm-brief.sh`, `fm-spawn.sh`, supervision, delivery, and merge rules remain authoritative.

## 12. Verification is risk-based

This planning layer records verification requirements per ticket, but it does not force `no-mistakes` on every ticket.

Use the ticket's verification section to distinguish:

- routine: normal tests/checks owned by the project and crew;
- elevated: targeted review or additional test evidence;
- critical: the existing no-mistakes pipeline or another explicitly required gate.

The planner must not call an external review agent merely because a ticket exists.

## 13. Composition and imports

This skill deliberately composes with, rather than replaces:

- `task-grill` for requirements interrogation;
- `task-design` for prototypes;
- `diagnostic-reasoning` for bug causality and reproduction;
- `captain-hold-lifecycle` for captain decisions;
- `project-management` for project lifecycle and delivery posture;
- `quota-array-dispatch` and existing harness adapters for crew selection;
- `fm-brief.sh` and `fm-spawn.sh` for actual execution.

For a reported bug, diagnosis comes first when the cause is uncertain.
A confirmed diagnosis can then feed this planning skill if the fix is large enough to require decomposition.

Do not import:

- Wayfinder's `implement` phase;
- branch/worktree orchestration from another system;
- another issue tracker as the source of truth;
- another agent/crew runtime;
- mandatory planning for every task;
- mandatory code review for every ticket.

The useful imported ideas are fog graduation, the map-as-index decision map, seams-first specification, vertical ticket slicing with explicit blocking edges, the expand-contract pattern, and inspectable planning artifacts.
