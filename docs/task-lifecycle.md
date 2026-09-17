# Captain-facing task lifecycle

This page is the single owner of Firstmate's captain-facing task statuses, routes, acceptance rule, and closure prerequisites.
The captain-facing lifecycle is a derived view over the existing backlog, worker, hold, blocker, and delivery records.
It does not rename or replace the configured backlog states `queued`, `in_flight`, and `done`, the worker status-event protocol, or `fm-crew-state` vocabulary.

## Statuses

- `queued` means work is authorized but has not started.
- `working` means the result is actively being produced or corrected.
- `waiting` means an external condition is expected to clear without a Firstmate decision.
- `blocked` means a concrete problem remains for Firstmate to try to solve.
- `needs-you` means one exact captain decision, approval, credential, or security-sensitive action is required.
- `done` means a candidate result is ready for review, whether or not integration will eventually be selected.
- `reviewing` means review is actively under way.
- `accepted` means review passed and selected `close`, `deliver`, or `deliver-monitor` as the route.
- `delivering` means integration, merge, publication, release, or deployment is under way.
- `monitoring` means post-delivery health is being observed.
- `failed` means the attempt ended unsuccessfully.

`closed` is an archival disposition, not a current status, so it is absent from `/tasks` and available through `/history`.
A blocker becomes `needs-you` only when one concrete captain action exists.
Otherwise it remains `blocked`, becomes `waiting` when an external condition should clear, or becomes `failed` when the attempt has ended.

## Routes and loops

The ordinary successful path is `queued -> working -> done -> reviewing -> accepted`.
Review may return a candidate to `working` for correction.
An accepted result selects exactly one route:

- `close` proceeds directly to archival closure.
- `deliver` proceeds through `delivering` and then closure.
- `deliver-monitor` proceeds through `delivering`, then `monitoring`, then closure.

A problem found during delivery or monitoring returns the task to `working` and invalidates the prior acceptance for the changed result.
`waiting`, `blocked`, `needs-you`, and `failed` are branches from the applicable active phase, not substitute names for the successful phases.

## Acceptance and durable evidence

Acceptance is explicit review evidence, never an inference from backlog `done`, worker completion, passing tests, a merge, publication, or deployment.
Starting review creates `data/task-lifecycle/<canonical-id>.json` through `bin/fm-task-lifecycle.sh`.
That minimal private record preserves the review stage, acceptance actor and UTC timestamp, evidence, limitations, selected route, and delivery or monitoring completion evidence after runtime cleanup.
An existing task without that record remains honestly `done` when its candidate is ready and names review as the missing next action.
A legacy closure remains readable with acceptance unrecorded rather than acquiring false acceptance during migration.

The guarded transition commands are:

```text
bin/fm-task-lifecycle.sh review-start <selector>
bin/fm-task-lifecycle.sh accept <selector> --actor <actor> --evidence <text> --route <close|deliver|deliver-monitor> [--limitations <text>]
bin/fm-task-lifecycle.sh return-to-work <selector> --reason <text>
bin/fm-task-lifecycle.sh delivery-start <selector>
bin/fm-task-lifecycle.sh delivery-complete <selector> --evidence <text>
bin/fm-task-lifecycle.sh monitoring-start <selector>
bin/fm-task-lifecycle.sh monitoring-complete <selector> --evidence <text>
```

Successful review finishes with `accept`, while corrective review finishes with `return-to-work`.
Delivery and monitoring may also use `return-to-work` when they expose a problem.
Every command resolves the canonical id, validates the current derived status and selected route, and atomically replaces the task's private record.

`/close` refuses a task whose review, acceptance, delivery, or monitoring requirement is incomplete.
An explicit close may combine review acceptance with closure only through `fm-close.sh --accept-close --actor <actor> --evidence <text> <selector>`.
That path always selects `close` and still requires a candidate result with no unresolved captain call, public commitment, unsafe cleanup, or other closure blocker.
The closure archive embeds the complete acceptance and selected-route evidence before the live lifecycle record is retired.
A durable lifecycle record also retains the task's short reference and current-task visibility after worker cleanup or bounded backlog-history rotation; guarded closure retires that live record and its reference can then follow the ordinary cooldown.

## Attention allocation

`/next` is an attention-allocation interface rather than a lifecycle interface.
It operates in three phases: CHOOSE the fleet item that deserves attention, PREPARE that item as far as Firstmate safely can, then HAND OFF only the smallest useful action that still requires the captain.

`bin/fm-next.sh` is the deterministic CHOOSE owner.
It ranks concrete captain actions that restart work, bounded actions that close high-value loops, unresolved decisions that release dependencies, other worthwhile captain attention, and closure only when no forward work can move.
Ordinary work Firstmate can continue without the captain is never eligible.
Priority, downstream work released, active work, wait age, callsign, and canonical id break ties in that order.
The model never re-ranks that result or substitutes a task from memory.

Schema `fm-next.v4` separates the selected task's `fm-next-prepare.v1` evidence packet from opt-in diagnostics.
The preparation packet composes durable intent, the phase-specific plan, lifecycle evidence, artifacts, repository location and state, the existing result, and closure preflight evidence.
The `/next` skill may use model judgment and read-only tools to inspect those inputs, run an already-authorized focused check, open an existing safe review surface, or reduce a decision before asking for attention.
Preparation does not grant authority to edit code, change lifecycle state, accept, deliver, merge, close, start speculative work, or perform a destructive, irreversible, or security-sensitive action.
If preparation proves the selected action obsolete, the skill reruns the same deterministic selector once against fresh state and never loops or hands off the stale action.

The task brief remains the durable owner of the optional `## Captain review plan` subsection used as preparation input.
The subsection uses one-line `Review`, `Delivery`, or `Monitoring` fields named `Action`, `Context`, `Check`, `Success`, `Failure`, `Continue`, and `Fix`; `Check` may repeat, and an unprefixed field belongs to review.
For example:

```text
## Captain review plan
Review Action: Test the new fm launcher
Review Context: The launcher implementation, executable tests, and README are the bounded preparation targets.
Review Check: From the repository root, run `./fm --mode text` and confirm the expected Firstmate extensions and repository context.
Review Success: The launcher starts in the expected context.
Review Failure: The launcher fails or starts in the wrong context.
```

`bin/fm-task.sh` is the structured aggregation owner for the plan plus durable task intent, current outcome, artifact type, and artifact locations.
Normal `/next` output is limited to an action title, short reference and meaningful name, at most two short context sentences saying what preparation established, one exact command, location, choice, or physical check, and one simple response or observable done condition.
It omits selection rationale, ranking and candidate counts, alternatives, lifecycle transitions, outcome taxonomies, raw requirements, raw revision hashes, delivery and worker mechanics, and task-detail detours.
`/next --why` adds a concise human explanation after the action, while `/next --debug` returns structured ranking, candidate, and lifecycle diagnostics.
Neither mode changes selection or state.

## Command surfaces

- `/report` writes the durable Markdown fleet briefing into normal conversation history, while `/bearings` remains its compatibility alias.
  It uses the structured fleet snapshot and this lifecycle projection for breadth, keeps the live `/tasks` display separate, and adds recommendations rather than changing lifecycle state.
- `/tasks [status] [project]` lists only current work with the statuses above, concise outcomes, and elapsed time for `working`, `reviewing`, `delivering`, and `monitoring`.
  The approved Pi `/t` router is its compact alias: bare `/t` toggles this dashboard, while `/t <selector>` routes to `/task <selector>`.
  Its JSON also provides `next_action`, `route`, `close_ready`, and the durable lifecycle record.
- `/task <selector>` shows the current or archived task, dates, result, acceptance evidence, selected route, artifacts, retained knowledge, follow-ups, and the exact next action.
- `/next` chooses and prepares the highest-value use of captain attention, then returns only the smallest remaining action.
  `/next --why` adds concise selection rationale and `/next --debug` exposes structured diagnostics without changing selection or state.
- `/close` previews or performs guarded archival closure.
  It refuses incomplete review, acceptance, delivery, or monitoring and supports the explicit combined `--accept-close` form described above.
- `/history [query]` searches closed tasks and displays their acceptance and route evidence; version-1 archives remain visible with `acceptance not recorded`.
- The Pi task widget consumes the same `/tasks` projection, so its status, outcome, and elapsed-time behavior cannot diverge from the command.

## Examples

- An investigation produces a report, becomes `done`, enters `reviewing`, is accepted with route `close`, and moves to history.
- A local feature produces an isolated branch, becomes `done`, is accepted with route `deliver`, enters `delivering` for the local landing, and closes after delivery evidence is recorded.
- A pull request or release becomes `done` when its candidate is reviewable, not when the whole lifecycle is over, then enters `delivering` only after review accepts the delivery route.
- A production change accepted with route `deliver-monitor` enters `monitoring` only after delivery completes and closes only after the observation evidence is recorded.
- A review finding moves `reviewing -> working`, and the corrected result must become `done` and be reviewed and accepted again.
- A monitoring regression moves `monitoring -> working`, invalidates the earlier acceptance for the changed result, and requires a new candidate review before another delivery.
