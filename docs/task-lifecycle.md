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
An unassigned task is valid: the launch owner binds its execution generation when it publishes metadata.

Save the semantic assessment and any prepared action before acknowledging its wake.
An inactive-goal wake refuses acknowledgement until the task revision advances, so a lease refusal cannot consume its only recovery trigger.
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
Cleanup has its own receipt and does not imply that archived work should resume.
A temporary parked or externally waiting task stays open.

Absent lifecycle records retain legacy behavior until explicitly reconciled.
For migration, inspect the exact current task generation, original brief and authoritative acceptance or stop receipt through the existing owners, including the configured tasks-axi current/history lookup.
Publish an assessment only when that evidence covers this generation.
Historical Done text, a status keyword, a newer timestamp, a matching task name or an old merge-ready event cannot close a newer request.
A reopened request needs a new goal revision and a distinct authority reference.
Corrupt records, changed briefs and generation conflicts remain unknown and preserve their original bytes.

Branch outcomes bind their delivery to the validated evidence key and task generation.
Reprocessing identical evidence reuses the original sequence without deleting it or advancing main's processed marker.
The [watcher continuity contract](watcher-continuity.md) still owns delivery, main/branch claims and successor recovery.
A stopped supervisor with no successor cannot make progress; durable obligations are available to the next locked startup.

## Remote results and resource cleanup

[iDA continuation](configuration.md#remote-research-agents) uses the existing provider adapter's same-session followup entry point.
It freezes the old terminal state and report, submits at most once, and binds the new provider task to a new execution generation.
A lost response permits only readback: task ordering or a single newly listed task does not identify the submission.
Without a uniquely correlated official response, the action remains uncertain and reports the missing provider identity.
A fresh dispatch cannot reuse a task identity that already owns a previous remote execution.
AIME's existing lifecycle remains compatible; iDA followup support grants no new AIME continuation capability.

[`fm-teardown.sh`](../bin/fm-teardown.sh) owns independent endpoint cleanup and [`fm-teardown-endpoint-lib.sh`](../bin/fm-teardown-endpoint-lib.sh) owns its receipt stages and retained reasons.
New Herdr launches bind a version 3 presentation journal to the execution generation, server instance, terminal identity and shell identity.
Older journals cannot acquire deletion authority from labels or a shared directory.
Endpoint cleanup closes only an exact idle task pane, preserves focused user tabs and active siblings, verifies workspace absence separately, and leaves directory safety checks in place.
Its cleanup-only backlog transition can recover bookkeeping after an actual close without deleting resource metadata or repeating endpoint/directory effects.
Whole-session snapshots can detect concurrent resource changes but cannot make Herdr's separate inspection and close operations atomic.

## Verification

[`tests/fm-task-lifecycle.test.sh`](../tests/fm-task-lifecycle.test.sh) covers revision conflicts, pending effects, explicit stop, generation mismatch, lost wake recovery, unassigned requests and outcome acknowledgement.
The existing send, control, remote-agent and backlog suites exercise their respective effect owners.
[`tests/fm-teardown-lifecycle-herdr-e2e.test.sh`](../tests/fm-teardown-lifecycle-herdr-e2e.test.sh) requires an explicitly authorized named-session helper and verifies real mixed/focused workspace behavior, active sibling preservation and interrupted bookkeeping.
Its helper is the only route to Herdr and verifies the default-session tripwire on teardown.
