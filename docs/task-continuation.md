# Goal-directed task continuation

A worker run can end before the requested outcome is complete. Firstmate therefore resumes work from the original backlog task: the task title states the goal, and its compact `firstmate-progress:v1` block records the acceptance method, current state, remaining gap, and next step. MAIN compares each material result with those fields and routes the next authorized action until the acceptance method is satisfied.

A worker return, process exit, report, passing test, pull request, merge, or empty inbox is evidence. None of those events accepts the goal by itself.

## One ordinary progress record

[`fm-task-progress.py`](../bin/fm-task-progress.py) owns the compact block embedded in the configured backlog task body. [`fm-task-state.sh`](../bin/fm-task-state.sh) exposes its public commands:

- `progress <task>` reads the task title and four progress fields.
- `update-progress <task> --expected-token <token> --progress '<json>'` publishes a material MAIN-authored update.
- `progress-list` discovers tasks eligible for supervision.

The task title remains the goal. The block contains only `acceptance`, `current_state`, `remaining_gap`, and `next_step`, plus its format marker. There is no per-task lifecycle JSON, mirrored task record, evidence ledger, goal scheduler, assessment state machine, or model-maintained coordination record.

The read result carries an opaque `record_token`. An update must return that token, so a changed title, body, task state, authenticated intent, executor generation, hold, or dependency block invalidates the stale write. Identical updates do not write. MAIN is the only writer and updates the block only after a material change.

The token is a stale-read guard, not semantic evidence or an atomic compare-and-swap guarantee. The configured task backend cannot combine comparison and publication, so an unrelated body writer racing between the check and publication remains a known narrow limitation.

Historical rich lifecycle files may stay on disk unchanged. New work does not create them, ordinary historical-task progress does not read or update them, and notification acknowledgement does not require inspect, assess, or reconcile. Operation owners may read a historical file only to recover a concrete immutable fact such as an old merge receipt or terminal cleanup authority; they never enroll, migrate, or reactivate it.

## From a result to the next action

Consider an illustrative ship task whose goal is “remove the obsolete adapter,” with acceptance “behavioral regression passes and the complete diff is reviewed.” A worker returns after deleting the adapter and the focused test passes, but final review has not run.

MAIN records the implementation and test as `current_state`, keeps final review in `remaining_gap`, and names the existing review path in `next_step`. Supervision routes that action to the correct existing worker. The passing test did not erase the gap. If the worker exits, the session compacts, or the conversation changes topic, `progress-list` and `progress` recover the same goal from the original task.

After review and any corrections, MAIN compares the final artifacts with the acceptance method. Only MAIN may clear both `remaining_gap` and `next_step`. Delivery, merge authority, decisions, and cleanup can still prevent retirement even after semantic acceptance.

Healthy unchanged execution and deliberate external waits stay quiet. A material result with an authorized remaining gap continues through an existing worker or action owner. A genuine authority decision, unresolved blocker, or failed exact-effect readback remains visible. Continued pursuit has no finite retry quota, but it never broadens the original authority or replays an uncertain effect.

## Supervision and notification delivery

The Pi primary discovers eligible tasks through `progress-list`. A token-bound compact projection may admit one branch supervision turn for the exact task. The branch can read the projection and route an already-authorized next step through an existing owner, but it cannot edit progress or accept the goal.

The durable wake queue and branch outcome sequence remain delivery owners. Acknowledging a presented notification is sequence-bound and does not enroll or reconcile another goal record. Re-presenting unchanged work does not create a second goal wake. Topic switches and reloads recover from the backlog row rather than transcript history.

`fm_task_continuation` exposes only `read` and `update`.
The MAIN-only `fm_task_intent_update` path replaces the existing `## Captain's intent` body with explicitly supplied processed requirement text through [`fm-task-intent.py`](../bin/fm-task-intent.py).
Its `input` parameter is the complete final requirement itself, not a message selector or a claim that the prose is a verbatim quote.
The owner verifies the current MAIN and task boundary and atomically changes only `brief.md`; it creates no source mapping, receipt, intent history, progress, or lifecycle record.
Cross-task work returns to MAIN, which uses the existing durable handoff owner rather than a branch-side lifecycle patch.

## Existing owners remain authoritative

Compact progress describes the outcome gap; it does not grant effects. Each operational responsibility keeps its existing owner:

| Responsibility | Authoritative owner |
|---|---|
| Worker start, stop, interrupt, relaunch | `fm-control.sh` and executor generation metadata |
| Steering and cross-task delivery | task inbox receipts and `fm-task-handoff.sh` stable IDs |
| Local or remote execution identity | local `spawn_gen` or provider generation records |
| Provider submission and follow-up | provider adapter stable-action records and exact readback |
| Merge authority and candidate identity | merge guard plus generation-bound merge receipts |
| Explicit stop or archive | configured backlog task/history and captain authority |
| Endpoint and copy cleanup | cleanup receipt, exact endpoint identity, and preservation checks |

An attempted or uncertain operation is never replayed from compact progress. The operation owner must prove completion by exact readback or retain the uncertainty. This applies to provider submissions, merge effects, inbox delivery, and cleanup attempts.

Merge and cleanup receipts are operation-specific records, not replacement goal stores. A merge receipt binds the task generation, URL, and candidate head. A cleanup receipt binds the task generation, endpoint/copy identity, phase, and preservation result. Neither contains or updates the goal, acceptance method, current state, remaining gap, or next step.

## Acceptance, archive, and cleanup

Empty `remaining_gap` and `next_step` mean MAIN has semantically accepted the requested outcome. That does not itself authorize a merge, answer an open decision, or dispose of resources.

Explicit archive is a separate terminal business action. It does not imply remote cancellation or provider success. Viewer classification uses the configured backlog archive as the business authority and continues to warn when remote facts are unconfirmed.

[`fm-task-retire.sh`](../bin/fm-task-retire.sh) and [`fm-teardown.sh`](../bin/fm-teardown.sh) keep business completion separate from physical cleanup. They require current compact acceptance or explicit archive, then use delivery and cleanup owners for their own checks. A ship still needs the correct current-generation merge receipt; a scout still needs its report and decision gate.

Endpoint cleanup binds the exact task, executor generation, Herdr session, and pane. It refuses conflicting ownership and never closes a whole workspace. Copy disposal is independent: primary, shared, dirty, unintegrated, or unverified copies remain available with an explicit cleanup disposition. Only an exclusive clean copy proved integrated into the default branch can be returned or removed. A pending or uncertain disposal requires exact readback before any further effect.

Historical private files, reports, operation receipts, dirty copies, and unlanded work remain untouched. Removing the rich lifecycle subsystem does not authorize deleting or rewriting them.

## Executable evidence

[`tests/fm-task-progress.test.sh`](../tests/fm-task-progress.test.sh) covers original-row reuse, MAIN-only token updates, stale-token invalidation, local and remote generation changes, terminal safety, and absence of a second progress store.

The Pi branch and primary suites cover compact admission, MAIN-only acceptance, quiet unchanged work, reload recovery, and sequence-bound outcome delivery. Send, handoff, control, remote-agent, merge, retirement, viewer, and teardown suites cover their own authority, generation, readback, archive, and unsafe-copy boundaries.

The critical behavioral invariant is observable through public interfaces: after a material result, the original task still reports the authorized remaining gap; no rich lifecycle file is created or required; and the next action routes through the existing owner until MAIN clears the gap.
