# Goal-directed task continuation

A worker can finish a run while the requested outcome remains incomplete.
The original backlog task therefore carries the minimum restart context: its title is the goal, and a compact body block records the acceptance method, current state, remaining gap and next step.
MAIN compares material results with that contract and continues the next authorized action until the acceptance method is satisfied.
A process exit, worker return, report, pull request, empty inbox or provider success is never acceptance by itself.

## Active record and owners

[`fm-task-progress.py`](../bin/fm-task-progress.py) owns the bounded `firstmate-progress:v1` block embedded in the existing task body.
Its read token also binds the task's current hold and dependency-block flags; a held or blocked row is never eligible for compact continuation, even when its backlog state remains In flight.
[`fm-task-progress-lib.sh`](../bin/fm-task-progress-lib.sh) reads and updates that block through the configured tasks-axi owner.
[`fm-task-state.sh`](../bin/fm-task-state.sh) exposes `progress`, `update-progress` and `progress-list` as the public interface.
No task directory, lifecycle JSON, evidence list, scheduler or mirrored progress store is created for ordinary continuation.

The task title remains the canonical goal and is returned with every progress read.
The compact block contains only `acceptance`, `current_state`, `remaining_gap` and `next_step`, plus an opaque context version in its marker.
The caller must return the opaque `record_token` from `progress` when calling `update-progress`; a concurrent title/body correction refuses the stale update, while an authenticated brief update or executor-generation replacement also makes the recorded fields inactive until MAIN publishes corrected progress.
Executor identity comes from the existing local `spawn_gen`, native remote-agent generation, or legacy AIME execution generation owner, and an unreadable or unsupported active identity fails closed.
The token is only a compare-and-swap guard and is not an evidence reference or semantic assessment fingerprint.
An identical update performs no task-record write.
MAIN is the only progress writer, and it writes only after a material change.
The branch may read one token-bound compact admission while the original task remains exactly `in_flight` and route work already authorized through an existing owner, but it cannot update these fields or make final semantic acceptance.

The existing wake queue, actor claims, task inbox, handoff record, execution metadata, provider record, operation receipt, merge guard and cleanup receipt remain authoritative for their own effects.
An attempted or uncertain effect must still be read back through its existing owner before retry.
Continuation progress neither grants authority nor replaces any of those records.

## Intake, reminders and acceptance

At intake, create the ordinary backlog task with a clear outcome-oriented title.
Before the task can leave MAIN's current context, record a concrete acceptance method, current state, and either both a remaining gap and next step or neither.
Both gap fields empty means MAIN has judged the requested outcome satisfied; the existing delivery, captain-hold, merge and cleanup owners still gate retirement.

The Pi adapter discovers in-flight task identities through `progress-list`, reads their compact projections, and stays quiet for healthy unchanged execution or a deliberate wait.
When a material result leaves an authorized gap without a healthy executor, it first offers one token-bound continuation to the supervision branch.
The branch may inspect current artifacts and route the already-authorized next step through the existing owner; a no-mistakes start or ordinary gate continuation goes back to the same worker, which alone runs or responds to the pipeline.
A declined or failed branch offer falls back to MAIN.
It never derives task identity from a backend endpoint label.
A healthy unchanged wait and verified routine advancement are retained quietly in the branch session.
A changed executor observation admits another bounded Branch turn without a MAIN progress rewrite.
Only goal-ready evidence, a genuine blocker, or an authority decision is delivered through MAIN's durable sequence-bound processing and acknowledgement path; two unsuccessful unchanged offers may be paced before one visible coordination escalation.
These transcript entries are delivery receipts only and never become another progress source.
Topic switches, session reload and compaction therefore recover from the original task row, while ordinary commands and unchanged observations add no progress writes.

The native `fm_task_continuation` tool exposes `list`, `read`, `update`, `route` and read-only `legacy` actions.
`read` followed by a material `update` replaces the former evidence-heavy `inspect` then `assess` routine.
No progress action accepts evidence paths, authority references, lifecycle JSON or caller-reconstructed judgments.
`route` remains the authenticated path for appending a selected original user correction to the task brief and retains its existing interruption-safe transaction.
`legacy` keeps rich historical lifecycle records readable without enrolling them into active monitoring.

Neither the monitor nor the branch replaces an action owner.
The branch may call that owner's existing interface for an already-authorized routine next step, while MAIN handles genuine scope/product/architecture, destructive, security, merge and cleanup decisions, reviews actual artifacts, writes material progress changes, and alone accepts the goal.
Ask-user findings remain MAIN-owned.
Project-required routine confirmations follow the same in-scope rule; all other decisions return to MAIN.
An empty inbox or unchanged wait is quiet, but a recorded actionable gap does not disappear until MAIN advances it, records a genuine blocker, or satisfies acceptance.

## Stops, older records and delivery

Accepted and explicitly archived records leave ordinary busy/stale checks and automatic business continuation.
Their existing late results, unprocessed branch outcomes and keyed decisions remain deliverable.
Moving an open goal to archived requires distinct explicit stop authority; its brief or existing acceptance authority cannot be reused for that transition.
If an exact pending handoff's bound source becomes accepted or archived, the lifecycle owner classifies that source barrier as permanent and the handoff owner records a terminal rejection under the same stable id; it neither delivers, revives the source nor invites a retry under another id.
An archived goal retains any attempted or uncertain business action as evidence, but that action is neither due nor executable and does not block independently authorized cleanup.
An attempted or uncertain cleanup action still requires exact readback before cleanup can proceed.
Concrete cleanup metadata keeps a terminal goal due for reconciliation until the cleanup owner records the complete generation-bound receipt; that supervision does not authorize business execution to resume.
A complete cleanup receipt makes the terminal goal quiet without erasing its retained evidence.
The due reader evaluates the required cleanup postconditions semantically: additive diagnostics and historical ShortTask request version labels do not change the verdict, while persisted receipt bytes remain immutable evidence.
For a historical cleanup observation recorded before retained-copy preservation fields existed, omitting those still-absent fields is equivalent to the current null-field projection and does not rewrite the stored digest.
Present preservation fields, every other fact in the cleanup observation and each separately assessed evidence item remain bound, so this compatibility does not admit changed evidence.
Business completion is independent of physical cleanup: after validated closure, the task leaves the active backlog even when its endpoint or copy must remain, and its cleanup receipt keeps that residual obligation discoverable.
The retained-resource completion path in [`fm-task-retire.sh`](../bin/fm-task-retire.sh) closes an accepted delivered ship or completed scout through the existing backlog-close marker and cleanup receipt; explicit archive retains uncertain effects separately.
When a ship retains multiple merge receipts from its current execution generation, completion requires exactly one receipt matching the task metadata's current PR URL and head; absent, duplicate or conflicting identity refuses without pruning history.
With a single current-generation receipt, delivery metadata may be absent, but any supplied URL or head must agree and duplicate identity fields still refuse.
The selected receipt supplies the backlog completion reference, independently of receipt ordering, while all merge history remains intact.
Open goals, unmerged required delivery and incomplete scout decision inventories refuse that closure.
If tasks-axi has already pruned the exact Done row, the existing backlog-close owner can acknowledge bookkeeping from the configured Done archive only with matching terminal execution generation and preserved delivery reference.
A missing, ambiguous, conflicting or unapplied archive reference keeps the close marker pending; recovery neither recreates the business task nor repeats endpoint/copy effects.
Main can retain an accepted or archived disposition while recording a prepared, unattempted cleanup wait with an evidence-bound dependency.
That wait defers cleanup reconciliation only until its recheck or deadline; changed or missing release evidence requests readback immediately.
It cannot replace an unresolved effect or authorize business execution.
A terminal lifecycle dependency is observed through its task, intent, disposition and relevant delivery facts; assessment notes, coordination timestamps, receipt presentation and unrelated task changes do not release the wait.
Unchanged scans remain quiet; relevant release facts or the first reached time bound produce one readback observation.
A temporary parked or externally waiting task stays open.

Existing rich lifecycle records remain readable for historical effect and cleanup reconciliation, but they are not migrated into compact progress or scanned as active work.
When such a record must be reconciled, inspect the exact current task generation, original brief and authoritative acceptance or stop receipt through the existing owners, including the configured tasks-axi current/history lookup.
Publish a historical assessment only when that evidence covers this generation.
Historical Done text, a status keyword, a newer timestamp, a matching task name or an old merge-ready event cannot close a newer request.
A reopened request needs a new goal revision and a distinct authority reference.
Corrupt records, changed briefs and generation conflicts remain unknown and preserve their original bytes.

The outcome store deduplicates only an identical delivery for the same validated evidence and task generation.
Reprocessing that delivery reuses the original sequence without deleting it or advancing main's processed marker, while a different late outcome receives its own sequence; [`fm-branch-outcome.sh`](../bin/fm-branch-outcome.sh) owns the exact key fields.
The [watcher continuity contract](watcher-continuity.md) still owns delivery, main/branch claims and successor recovery.
A stopped supervisor with no successor cannot make progress; durable obligations are available to the next locked startup.

## Remote results and resource cleanup

[`fm-remote-agent-ida.sh`](../bin/fm-remote-agent-ida.sh) exposes the existing provider adapter's same-session followup entry point.
It freezes the old terminal state and report, submits at most once, and binds the new provider task to a new execution generation.
A lost response permits only readback: task ordering or a single newly listed task does not identify the submission.
Without a uniquely correlated official response, the action remains uncertain and reports the missing provider identity.
A fresh dispatch cannot reuse a task identity that already owns a previous remote execution.
AIME's existing lifecycle remains compatible; iDA followup support grants no new AIME continuation capability.

[`fm-teardown.sh`](../bin/fm-teardown.sh) owns independent endpoint cleanup and [`fm-teardown-endpoint-lib.sh`](../bin/fm-teardown-endpoint-lib.sh) owns its receipt stages and retained reasons.
An open task retains its endpoint, directory, slot and task records; cleanup begins only after semantic acceptance or a separately authorized archive, and discard authority does not bypass that boundary.
For an accepted or archived goal, cleanup validates the exact task's home-local metadata and recorded Herdr session/pane, refuses an endpoint claimed by another task, and confirms that exact pane is absent after closing it.
An explicit expected generation must still match; missing, conflicting or uncertain endpoint routing refuses before effects.
The worker may still be running or its tab may be focused: completed-task window retirement does not depend on composer state, presentation journals, continuation receipts, historical process identities or a ShortTask actor-binding gate.
Closing the recorded pane leaves sibling panes and reports intact; it does not close a whole workspace.

Copy disposal is independent. For example, an accepted task with an uncommitted copy loses its completed worker window and resource metadata, while that copy stays available for recovery.
Primary, shared, dirty, unintegrated or unverified copies are retained with an explicit disposition in the cleanup receipt.
Only an exclusive clean copy whose content is proved integrated in the default branch is removed or returned to its Treehouse pool; a merely pushed feature branch is retained.
The existing project allocation/return lock protects the sharing observation and disposal; contention retains the copy without blocking window retirement.
Pool copies whose current task/home/generation claim cannot establish exclusive ownership are also retained; primary checkout subdirectories are preserved, while independent nested worktrees remain eligible.
[`fm-teardown-worktree-lib.sh`](../bin/fm-teardown-worktree-lib.sh) owns the shared content-preservation checks; historical slot-claim or journal bookkeeping is not an additional completed-cleanup admission gate.
The endpoint-only form retains metadata and the copy and records exact-pane absence through the existing phase receipt.
Completed retirement captures exact retained-copy identity in that same receipt before metadata removal.
Its copy-only follow-through in `fm-teardown.sh` verifies this binding and current preservation checks without recreating task records or repeating endpoint/business effects.
Pending disposal requires exact readback; absent copy can be confirmed without replay, while a changed directory/Git identity or missing historical binding refuses.
The narrow ShortTask retained-copy recoveries are documented by their [operation owner](short-agents.md#access-limits-and-uncertain-effects).
The retained phase records the verified current reason; an old generic unverified disposition does not establish its cause.
Legacy records without an accepted or archived lifecycle retain the detailed ordinary teardown contract in `fm-teardown.sh`.
Herdr's separate inspection and close operations cannot exclude concurrent external mutations atomically.
The due reader recognizes current cleanup-owner facts and assessed historical ShortTask completion chains through the read-only contract in [`fm-task-lifecycle.py`](../bin/fm-task-lifecycle.py).
A result summary alone cannot retire a cleanup obligation; incomplete, conflicting, or unbound evidence remains due for readback without replay.

## Verification

[`tests/fm-task-progress.test.sh`](../tests/fm-task-progress.test.sh) covers original-row reuse, explicit goal and acceptance projection, MAIN-only compare-and-swap updates, concurrent task and authenticated-intent correction refusal, local and remote execution-generation invalidation, unchanged-write suppression, terminal safety and absence of a second progress store.
[`tests/fm-task-lifecycle.test.sh`](../tests/fm-task-lifecycle.test.sh) covers revision conflicts, pending effects, explicit stop, generation mismatch, routine-policy grant fencing and renewal, exact handled-receipt recovery, lost wake recovery, unchanged-wake outcome coverage, unreadable unknown-record refusal, guarded acknowledgement after repair, current-wake preservation, relevant-change-only terminal observations and exact outcome replay.
[`tests/fm-task-handoff.test.sh`](../tests/fm-task-handoff.test.sh) covers durable rejection when an exact pending handoff's bound source becomes terminal.
[`tests/lifecycle-native.mjs`](../tests/lifecycle-native.mjs), run by [`tests/fm-pi-branch-extension.test.sh`](../tests/fm-pi-branch-extension.test.sh), covers topic-switch restart, intermediate-result continuation, canonical task identity reminders, compact call and response measurements, quiet unchanged work and read-only historical lifecycle access through the installed Pi SDK.
The same branch suite also exercises the harmless Herdr-shaped path from an incomplete checkpoint through real `fm-send.sh` inbox receipts, stale-intent, stopped-task and cross-task refusal, sequence-acknowledged authority escalation, intermediate continuation, and final MAIN-only acceptance.
[`tests/fm-backlog-atomicity.test.sh`](../tests/fm-backlog-atomicity.test.sh), including its [`retirement-business.py`](../tests/retirement-business.py) fixture, covers business closure with resources retained, current-delivery selection among multiple receipts, identity and generation refusal, interruption recovery, and exact Done-history convergence.
The existing send, control, remote-agent and backlog suites exercise their respective effect owners.
[`tests/fm-teardown-endpoint-safety.test.sh`](../tests/fm-teardown-endpoint-safety.test.sh) covers the open-goal barrier, completed exact-pane cleanup without historical admission gates, foreign or shared endpoint refusal, and dirty, unlanded or uncertain-owner copy retention.
[`tests/fm-short-operations-herdr.test.sh`](../tests/fm-short-operations-herdr.test.sh) is the current real-Herdr completed-cleanup guard; the [runtime evidence](verification/runtime-backends.md#independent-task-workspace-cleanup) owns its environment, observed results and limits.
[`tests/fm-teardown-lifecycle-herdr-e2e.test.sh`](../tests/fm-teardown-lifecycle-herdr-e2e.test.sh) continues to cover the legacy structural-journal and focus-preserving path.
