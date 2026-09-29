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
Herdr presentation-journal versions are diagnostic rather than cleanup permission gates.
A journal with the complete launch-identity field group binds the execution generation, server instance, terminal identity and shell identity directly.
An older journal with the complete exact-endpoint field group can also authorize cleanup when the current owned Herdr session demonstrably predates the unchanged journal and cleanup re-reads matching workspace, tab, pane, terminal and shell identity before mutation.
For a correlator-only journal, the task's independently validated meta endpoint can supply the exact session, workspace, tab and pane only when meta and lifecycle agree on a standard spawn generation and the current owned Herdr session demonstrably predates the unchanged journal.
Partial or conflicting identity groups, replaced sessions, malformed generations, labels alone and shared-directory membership do not acquire deletion authority.
Endpoint cleanup closes only an exact idle task pane, preserves focused user tabs and active siblings, verifies workspace absence separately, and leaves directory safety checks in place.
Its cleanup-only backlog transition can recover bookkeeping after an actual close without deleting resource metadata or repeating endpoint/directory effects.
Pool-directory return still follows the [existing teardown safety contract](architecture.md#delivery-modes-are-explicit-per-task): only an exact task-and-generation slot claim authorizes return, while a missing or ambiguous claim retains the cleanup obligation.
Whole-session snapshots can detect concurrent resource changes but cannot make Herdr's separate inspection and close operations atomic.

## Verification

[`tests/fm-task-lifecycle.test.sh`](../tests/fm-task-lifecycle.test.sh) covers revision conflicts, pending effects, explicit stop, generation mismatch, lost wake recovery, unassigned requests, unknown-record acknowledgement, terminal cleanup receipts and exact outcome replay.
The existing send, control, remote-agent and backlog suites exercise their respective effect owners.
[`tests/fm-teardown-endpoint-safety.test.sh`](../tests/fm-teardown-endpoint-safety.test.sh) covers the open-goal cleanup barrier, archived business-action retention and uncertain cleanup readback.
[`tests/fm-teardown-lifecycle-herdr-e2e.test.sh`](../tests/fm-teardown-lifecycle-herdr-e2e.test.sh) requires an explicitly authorized named-session helper and verifies real mixed/focused workspace behavior, active sibling preservation and interrupted bookkeeping.
Its helper is the only route to Herdr and verifies the default-session tripwire on teardown.
