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

## Human-action translation

Lifecycle projection and captain guidance have separate jobs.
`bin/fm-next.sh` deterministically decides which fleet item deserves captain attention, but its card describes the physical or mental action rather than the transition that action may cause.
The selection order is concrete captain actions that restart work, bounded actions that close high-value loops, unresolved decisions that release dependencies, other worthwhile captain attention, and closure only when no forward work can move.
Ordinary work Firstmate can continue without the captain is never eligible.
Priority, downstream work released, active work, wait age, callsign, and canonical id break ties in that order.

The task brief is the durable owner of an optional `## Captain review plan` subsection and stays available after worker cleanup through task closure and archival.
The subsection uses one-line `Review`, `Delivery`, or `Monitoring` fields named `Action`, `Context`, `Check`, `Success`, `Failure`, `Continue`, and `Fix`; `Check` may repeat, and an unprefixed field belongs to review.
For example:

```text
## Captain review plan
Review Action: Run the root-level Firstmate launcher and verify its documented behavior
Review Context: The launcher and README instructions are complete.
Review Check: From the repository root, run the launcher.
Review Check: Confirm it starts Firstmate in the intended repository context.
Review Check: Verify the README instructions match what the launcher actually does.
Review Success: The launcher starts in the intended context and the README matches reality.
Review Failure: The launcher starts in the wrong context or the README differs from observed behavior.
Review Fix: Name the first mismatch and return it as one concrete correction.
```

`bin/fm-task.sh` is the structured aggregation owner for that plan plus durable task intent, current outcome, artifact type, and artifact locations.
`bin/fm-next.sh` may turn only that supplied evidence into checks and outcomes; it never invents acceptance criteria.
When no specific plan or criterion exists, the card requests one concrete inspection and names the question it must answer.
A review correction is a possible outcome of the selected inspection, never a competing action.
At most two alternatives may be shown, and they are the next ranked eligible actions from the same immutable candidate set.

## Command surfaces

- `/report` writes the durable Markdown fleet briefing into normal conversation history, while `/bearings` remains its compatibility alias.
  It uses the structured fleet snapshot and this lifecycle projection for breadth, keeps the live `/tasks` display separate, and adds recommendations rather than changing lifecycle state.
- `/tasks [status] [project]` lists only current work with the statuses above, concise outcomes, and elapsed time for `working`, `reviewing`, `delivering`, and `monitoring`.
  The approved Pi `/t` router is its compact alias: bare `/t` toggles this dashboard, while `/t <selector>` routes to `/task <selector>`.
  Its JSON also provides `next_action`, `route`, `close_ready`, and the durable lifecycle record.
- `/task <selector>` shows the current or archived task, dates, result, acceptance evidence, selected route, artifacts, retained knowledge, follow-ups, and the exact next action.
- `/next` identifies the highest-value concrete thing for the captain to do, explains why it outranks the rest, and separates the action from its possible outcomes.
  Its ranking and evidence boundary are defined above, and it proposes archival closure only when no forward work can move and the selected route is complete.
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
