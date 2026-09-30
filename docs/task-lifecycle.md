# Durable task acceptance and continuation

A worker can finish a run while its requested result is still incomplete.
Firstmate retains the requested outcome, evidence, remaining gap and next authorized step with that task, so switching topics or restarting a session does not erase the earlier request.
A supervisor judges acceptance against the brief; neither a process exit nor a provider success makes that judgment automatically.

For example, a completed investigation may share its directory with another task.
After acceptance, Firstmate can remove the investigation's positively identified pane, verify whether its dedicated workspace disappeared, and retain the shared directory and final report.
An ambiguous old endpoint remains a named cleanup obligation; it does not restart the investigation.

## Owners and prerequisites

The brief owns the natural-language contract.
[`fm-task-state.sh`](../bin/fm-task-state.sh) exposes its assessment operations; [`fm-task-lifecycle.py`](../bin/fm-task-lifecycle.py) owns the bounded JSON schema, evidence checks and revision transitions, and [`fm-task-lifecycle-lib.sh`](../bin/fm-task-lifecycle-lib.sh) composes the existing task lease and metadata lock.
The record requires Python 3.9 or newer and uses only its standard library.
The task's existing private data directory retains the assessment after execution metadata is removed.
It is not a second backlog, execution engine, permission grant or scheduler.

The existing wake queue, actor claims, task inbox, control transaction, provider record and cleanup receipt retain their respective effects and acknowledgements.
[`fm-inactive-reconcile.sh`](../bin/fm-inactive-reconcile.sh) discovers current tasks through metadata, cleanup receipts and the configured backlog within its existing scan deadline and cursor.
It never traverses historical task directories to find work.
The Pi adapter batches record reads off the UI thread with a bounded subprocess and returns uncertain tasks to main.

## Intake and evidence reconciliation

Finalize the brief and create the ordinary backlog item, then initialize its lifecycle assessment before deferring an accepted request without an executor.
Local, iDA and AIME dispatch initialize records for new executions as well.
Use the task-state header's read and reconciliation interface to submit a private candidate with the expected revision.
An unassigned task is valid.
For a local launch, the launch owner binds its execution generation only after launch delivery and the backlog commit both succeed; metadata left by an attempted but unconfirmed launch remains unknown for reconciliation.
When ordinary dispatch has no prepared lifecycle action, observation can still prove execution from the bound brief, matching generation, confirmed launch publication and actual harness activity.
A synthetic launch busy marker cannot supply that proof, and observation never creates an action or accepts the goal.

Save the semantic assessment and any prepared action before acknowledging its wake.
An inactive-goal wake with a known lifecycle revision refuses acknowledgement until that revision advances, while an unknown lifecycle record refuses acknowledgement until it is repaired.
A lease refusal therefore cannot consume the task's only recovery trigger.
A confirmed action still leaves an unaccepted goal open.
A future bounded wait defers the next review; expiry asks for reconciliation and does not itself restart a healthy worker or cancel a query.

The next action binds exact payload bytes, authority evidence, execution generation and a monotonic action identity.
Use that identity with the existing automatic send, spawn, relaunch or iDA followup owner.
An interrupted send reuses its original inbox record, including after worker acknowledgement.
A published launch reuses its metadata identity; an attempted launch without a verified publication refuses another allocation until its control or launch evidence is reconciled.
A confirmed replacement retains both the original expected generation and the resulting execution generation.
The record is not evidence that the new worker achieved its goal.

A prepared action can be attempted only within its deadline and bounded attempt budget.
The current effect owners make one attempt and reuse its receipt; the two-attempt schema ceiling does not authorize a second ambiguous effect.
An uncertain effect must be read back before it can be replaced.
A refused effect cannot reset its budget by preparing the same kind and payload under another action id in the same goal revision.
Choose a materially different authorized diagnostic or record the exact missing decision, authority or external change.
No monitoring default authorizes additional model spend, query spend, merging, file disposal or security changes.

## Stops, older records and delivery

Accepted and explicitly archived records leave ordinary busy/stale checks and automatic business continuation.
Their existing late results, unprocessed branch outcomes and keyed decisions remain deliverable.
Moving an open goal to archived requires distinct explicit stop authority; its brief or existing acceptance authority cannot be reused for that transition.
An archived goal retains any attempted or uncertain business action as evidence, but that action is neither due nor executable and does not block independently authorized cleanup.
An attempted or uncertain cleanup action still requires exact readback before cleanup can proceed.
Concrete cleanup metadata keeps a terminal goal due for reconciliation until the cleanup owner records the complete generation-bound receipt; that supervision does not authorize business execution to resume.
A complete cleanup receipt makes the terminal goal quiet without erasing its retained evidence.
The due reader evaluates the required cleanup postconditions semantically: additive diagnostics and historical ShortTask request version labels do not change the verdict, while persisted receipt bytes remain immutable evidence.
Main can retain an accepted or archived disposition while recording a prepared, unattempted cleanup wait with an evidence-bound dependency.
That wait defers cleanup reconciliation only until its recheck or deadline; changed or missing release evidence requests readback immediately.
It cannot replace an unresolved effect or authorize business execution.
A temporary parked or externally waiting task stays open.

Absent lifecycle records retain legacy behavior until explicitly reconciled.
For migration, inspect the exact current task generation, original brief and authoritative acceptance or stop receipt through the existing owners, including the configured tasks-axi current/history lookup.
Publish an assessment only when that evidence covers this generation.
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
An enrolled open goal retains its endpoint, directory, slot and task records; cleanup begins only after semantic acceptance or a separately authorized archive, and discard authority does not bypass that boundary.
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
Legacy records without an accepted or archived lifecycle retain the detailed ordinary teardown contract in `fm-teardown.sh`.
Herdr's separate inspection and close operations cannot exclude concurrent external mutations atomically.
The due reader recognizes current cleanup-owner facts and assessed historical ShortTask completion chains through the read-only contract in [`fm-task-lifecycle.py`](../bin/fm-task-lifecycle.py).
A result summary alone cannot retire a cleanup obligation; incomplete, conflicting, or unbound evidence remains due for readback without replay.

## Verification

[`tests/fm-task-lifecycle.test.sh`](../tests/fm-task-lifecycle.test.sh) covers revision conflicts, pending effects, explicit stop, generation mismatch, lost wake recovery, unassigned requests, unknown-record acknowledgement, terminal cleanup receipts and exact outcome replay.
The existing send, control, remote-agent and backlog suites exercise their respective effect owners.
[`tests/fm-teardown-endpoint-safety.test.sh`](../tests/fm-teardown-endpoint-safety.test.sh) covers the open-goal barrier, completed exact-pane cleanup without historical admission gates, foreign or shared endpoint refusal, and dirty, unlanded or uncertain-owner copy retention.
[`tests/fm-short-operations-herdr.test.sh`](../tests/fm-short-operations-herdr.test.sh) is the current real-Herdr completed-cleanup guard; the [runtime evidence](verification/runtime-backends.md#independent-task-workspace-cleanup) owns its environment, observed results and limits.
[`tests/fm-teardown-lifecycle-herdr-e2e.test.sh`](../tests/fm-teardown-lifecycle-herdr-e2e.test.sh) continues to cover the legacy structural-journal and focus-preserving path.
