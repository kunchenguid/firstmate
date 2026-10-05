# Goal-directed task continuation

A worker run can end before the requested outcome is complete.
Firstmate therefore resumes work from the task's canonical `data/<task>/task.json` record.
That one record stores both the business identity and the acceptance method, current state, remaining gap, and next step.
MAIN compares each material result with those fields and routes the next authorized action until the acceptance method is satisfied.

A worker return, process exit, report, passing test, pull request, merge, or empty inbox is evidence. None of those events accepts the goal by itself.

## One ordinary progress record

[`fm-task-record.py`](../bin/fm-task-record.py) owns the canonical task record and its atomic writes.
[`fm-task-state.sh`](../bin/fm-task-state.sh) exposes its public commands:

- `progress <task>` reads the task title and four progress fields.
- `update-progress <task> --progress '<json>'` publishes a material MAIN-authored update.
- `progress-list` discovers tasks eligible for supervision.

There is no separate `fm-state-update` command in this repository.
The existing `fm-task-state.sh update-progress` command and Pi's existing `fm_task_continuation` tool remain the public update owners; this change replaces their expensive shared-backlog implementation rather than introducing another progress system.

The task record contains only the business and progress fields current behavior consumes.
There is no shared canonical backlog, persisted aggregate index, second progress mirror, evidence ledger, goal scheduler, assessment state machine, or model-maintained coordination record.

MAIN is the only writer and updates the record only after a material change.
Publication is one same-directory atomic replacement, so interruption cannot expose partial JSON.
Identical progress values do not write.
The update path does not acquire a task lease or metadata lock, refresh a fleet snapshot, validate provider lifecycle state, or reread the record after publication.

Reads still return an opaque `record_token` for a supervision branch to bind one admission to the exact projection it read.
It is not an update precondition, concurrency protocol, semantic evidence, or persisted field.

The old backlog and archive remain inert evidence and are not read, rewritten, or deleted by task/progress operations.
Historical rich lifecycle files may stay on disk unchanged.
New work does not create them, ordinary historical-task progress does not read or update them, and notification acknowledgement does not require inspect, assess, or reconcile.
Operation owners may read a historical file only to recover a concrete immutable fact such as an old merge receipt or execution identity; they never enroll, migrate, or reactivate it.

## From a result to the next action

Consider an illustrative ship task whose goal is “remove the obsolete adapter,” with acceptance “behavioral regression passes and the complete diff is reviewed.” A worker returns after deleting the adapter and the focused test passes, but final review has not run.

MAIN records the implementation and test as `current_state`, keeps final review in `remaining_gap`, and names the existing review path in `next_step`.
Supervision routes that action to the correct existing worker.
The passing test did not erase the gap.
If the worker exits, the session compacts, or the conversation changes topic, `progress-list` scans the canonical records once and `progress` reads the named task record directly.

After review and any corrections, MAIN compares the final artifacts with the acceptance method.
Only MAIN may clear both `remaining_gap` and `next_step`, and it clears them once the requested outcome is semantically accepted even when delivery or resource cleanup remains pending.
Delivery, merge authority, decisions, and cleanup retain their own records and guards instead of becoming a new business goal gap.
A captain hold remains an independent disposition constraint: cleanup verifies its decision inventory and retains the held task row, but the hold does not revoke an already recorded semantic acceptance.

Healthy unchanged execution and deliberate external waits stay quiet. A material result with an authorized remaining gap continues through an existing worker or action owner. The same task-record token and executor observation receives at most two unchanged continuation offers, then one visible coordination escalation, then no further offer until its record, executor, or disposition materially changes. The delivery receipts are existing Pi transcript entries, carry the exact operational home, and are recovered from prior same-cwd session files only when that home also matches after `/new` replaces the transcript. This pacing bounds duplicate observation; it is not a task retry limit, a second task store, or a reason to abandon authorized work.

If an existing owner refuses and no supported action remains, MAIN replaces the unexecutable next step with an existing canonical hold. The hold names who is responsible, the exact action or decision required, and the observable condition that clears it. A task blocker uses the task-record hold owner; a captain decision uses the captain-hold owner. A material result, changed executor evidence, or cleared disposition re-enters ordinary continuation. Continued pursuit never broadens authority or replays an uncertain effect.

## Supervision and notification delivery

The Pi primary discovers eligible tasks through `progress-list`.
A compact projection token may admit one branch supervision turn for the exact task record.
The branch can read the projection and route an already-authorized next step through an existing owner, but it cannot edit progress or accept the goal.

The durable wake queue and branch outcome sequence remain delivery owners.
One targeted read can load several exact outcome sequences together with their current canonical task projection, recorded and current executor generations (including an explicit mismatch flag), applicable candidate identity, metadata digest, and runtime projection. MAIN acknowledges the exact sequence membership it actually loaded and handled. Acknowledgement rechecks the immutable durable outcome identity and authenticated load, but deliberately does not reject a task-record or executor mutation caused by that handling: it closes presentation of the loaded outcome, not the newer task state and not semantic acceptance. A generation mismatch therefore remains readable and actionable instead of wedging the sequence prefix. This is a derived observation, not another persisted task truth.
Acknowledging a presented notification does not enroll or reconcile another goal record.
Re-presenting unchanged work does not create a second goal wake.
Topic switches and reloads recover from the canonical task record rather than transcript history.

`fm_task_continuation` exposes `read`, `update`, and `hold`. `hold` does not execute an action or invent authority; it records the existing blocker or captain-decision disposition only after supported actions are exhausted.
When requirements change, MAIN edits the original `brief.md` through its ordinary file tools so `## Captain's intent` contains the consolidated processed requirement while the rest of the task contract remains intact.
The edited prose preserves the intended scope without claiming to be a verbatim quote, and MAIN separately refreshes compact progress and relays the change to the worker.
There is no dedicated intent-update tool, source-message selector, mapping, receipt, or intent history.
Cross-task work returns to MAIN, which uses the existing durable handoff owner rather than a branch-side lifecycle patch.

For a clean accepted finish, the supervision outcome is a compact authenticated completion capsule. MAIN still makes one semantic-acceptance and authority decision; it may then grant one bounded chain that invokes the existing merge, sync, and cleanup owners and returns their combined receipts. Each owner keeps its identity, lease, authority, uncertain-effect, and preservation guards. Unsupported activation, a genuine blocker, or an uncertain operation stops with the exact remaining gap instead of replaying the chain.

## Existing owners remain authoritative

Compact progress describes the outcome gap; it does not grant effects. Each operational responsibility keeps its existing owner:

| Responsibility | Authoritative owner |
|---|---|
| Worker start, stop, interrupt, relaunch | `fm-control.sh` and executor generation metadata |
| Steering and cross-task delivery | task inbox receipts and `fm-task-handoff.sh` stable IDs |
| Local or remote execution identity | local `spawn_gen` or provider generation records |
| Provider submission and follow-up | provider adapter stable-action records and exact readback |
| Merge authority and candidate identity | merge guard plus generation-bound merge receipts |
| Explicit stop or archive | canonical task disposition and captain authority |
| Endpoint and copy cleanup | cleanup receipt, exact endpoint identity, and preservation checks |

An attempted or uncertain operation is never replayed from compact progress. The operation owner must prove completion by exact readback or retain the uncertainty. This applies to provider submissions, merge effects, inbox delivery, and cleanup attempts.

Merge and cleanup receipts are operation-specific records, not replacement goal stores. A merge receipt binds the task generation, URL, and candidate head. A cleanup receipt binds the task generation, endpoint/copy identity, phase, and preservation result. Neither contains or updates the goal, acceptance method, current state, remaining gap, or next step.

## Acceptance, archive, and cleanup

Empty `remaining_gap` and `next_step` mean MAIN has semantically accepted the requested outcome. That does not itself authorize a merge, answer an open decision, or dispose of resources.

Explicit archive is a separate terminal business action.
It does not imply remote cancellation or provider success.
Viewer classification uses only the canonical task disposition; remote execution observations remain separately labelled and never change business status.

If the exact task is explicitly completed or archived after a continuation admission but before the branch reports, unchanged canonical task evidence and resume-state evidence settles that admission as durably superseded; only the state, close date, completion marker, and update timestamp may differ for the terminal transition. The branch neither reopens the task nor manufactures a missing-outcome failure. A new note, link, report, intent/progress change, changed nonterminal record, pending decision, mismatched executor identity, or uncertain effect still follows the ordinary reconciliation path.

[`fm-task-retire.sh`](../bin/fm-task-retire.sh) and [`fm-teardown.sh`](../bin/fm-teardown.sh) keep business completion separate from physical cleanup. They require current compact acceptance or explicit archive, then use delivery and cleanup owners for their own checks. A ship still needs the correct current-generation merge receipt; a scout still needs its report and decision gate.

Normal local and remote retirement also removes that task's volatile status presentation and runtime projections through their existing owners.
The status owner holds the presentation lock and refuses retirement while status bytes are unread or a decision is open.
The inbox owner refuses while any instruction is unhandled, and the handoff owner treats `delivered` as transport state rather than acknowledgement until the exact generation-bound inbox record exists under `handled/`.
The runtime owner removes task-scoped busy, session, control, handled inbox history, progress, and presentation projections only after endpoint/resource retirement and accepted completion are proven.
Cleanup and merge receipts move from active `state/` paths into task-owned archives under `data/<task>/`, and their original readers continue to resolve exact generations there.
Reports, canonical task records, remote-execution identity, provider captures and handled evidence, and retained copies remain outside this cleanup.

There is no fleet sweeper or inference-based historical deletion command.
For one already-retired task, MAIN may run `fm-task-retire.sh <task-id> --historical-state dry-run --generation <generation>` and then repeat it with `apply`.
Canonical records carry no execution generation, so legacy-only state sweeping is refused and preserves historical runtime material.
A missing record cannot inherit business authority from a retained lifecycle disposition, and backfill archival grants no resource disposal authority.
Exact-generation completed cleanup and merge receipts remain readable and may be archived by their existing owners without changing the task record.

Endpoint cleanup binds the exact task, executor generation, Herdr session, and pane. It refuses conflicting ownership and never closes a whole workspace. Copy disposal is independent: primary, shared, dirty, unintegrated, or unverified copies remain available with an explicit cleanup disposition. Only an exclusive clean copy proved integrated into the default branch can be returned or removed. A pending or uncertain disposal requires exact readback before any further effect.

Historical private files, reports, operation receipts, dirty copies, and unlanded work remain untouched. Removing the rich lifecycle subsystem does not authorize deleting or rewriting them.

### Cleanup guard boundary and failure history

The October 2026 repeated cleanup failure had two separate causes. Commit `4f852e49` made the compact record authoritative and rejected the still-held task as not accepted; that exposed the stale progress wording but did not create the reservation. Earlier commit `a70ee10e` wrote a cleanup effect marker before calling teardown, so that preflight refusal had no refused/no-effect receipt and retained the resource reservation. A replacement request then correctly refused the occupied resource. The continuation change therefore contributed to the first refusal, while the earlier ShortTask effect boundary caused the repeated refusal.

The cleanup checks remain deliberately split:

| Current fact and owner | Risk protected | Refusal or safe outcome |
|---|---|---|
| MAIN's canonical acceptance, with no hold or only an exact `captain` hold | An executor result, commit, PR, or success exit must not accept an unmet goal | Other holds, blockers, or a business gap refuse; a captain hold retains its task row after resource cleanup |
| Current-generation merge receipt for a ship, or report plus decision gate for a scout | Cleanup must not grant merge authority or discard an undelivered result | Missing or mismatched delivery proof refuses |
| Exact task generation, endpoint binding, and exclusive reservation | A stale task must not close a reused pane or race another owner | Identity conflict, a live owner, or an unknown effect refuses |
| Exact endpoint readback, independently from copy disposition | Pane retirement must not imply that a copy is disposable | The correct pane may retire while a primary, shared, dirty, unintegrated, or unverified copy is retained |
| Owner receipt after the mutation boundary | An intent is not proof that an effect occurred | Completed cleanup settles from exact owner facts; current pre-effect refusal records `refused`; uncertainty remains reserved |
| Durable acceptance-preflight refusal plus unchanged task binding, no cleanup record, a dead runner, and an exact endpoint state of present or dead | Repair the missing-receipt crash window without guessing from stderr or exit status alone; an effect-bearing case additionally requires the runner-owned marker shape shared by the old wrapper and current cleanup CLI, while the exact refusal can only be emitted before the current owner's first effect boundary | This conjunction records a refused/no-effect settlement; any other post-effect output, unknown endpoint state, or conflicting fact preserves the reservation |

These are behavior boundaries, not keyword classification. In particular, there is no “cleanup-only” bypass, no automatic acceptance from `done`, and no relaxation for unknown effects or unsafe copies. `tests/fm-task-progress.test.sh` covers captain versus non-captain holds; `tests/fm-short-operations-cases.mjs` covers the legacy false-effect settlement, uncertain-evidence retention, normal accepted cleanup, completed readback, and replay idempotence; endpoint and copy safety remain covered by `tests/fm-teardown-endpoint-safety.test.sh`.

## Executable evidence

[`tests/fm-task-progress.test.sh`](../tests/fm-task-progress.test.sh) covers one-file CRUD, filtered inventory, atomic publication, unchanged-write elision, MAIN-only updates, restart recovery, held-lock independence, terminal safety, snapshot derivation, and semantic-acceptance consumers.
The same suite verifies retained backlog/archive files cannot supply task or progress data and a missing canonical record is not reconstructed.

The Pi branch and primary suites cover compact admission, MAIN-only acceptance, quiet unchanged work, reload recovery, and sequence-bound outcome delivery. Send, handoff, control, remote-agent, merge, retirement, viewer, and teardown suites cover their own authority, generation, readback, archive, and unsafe-copy boundaries.

The critical behavioral invariant is observable through public interfaces: after a material result, the task's one canonical record still reports the authorized remaining gap; no aggregate or rich lifecycle file is created or required; and the next action routes through the existing owner until MAIN clears the gap.
