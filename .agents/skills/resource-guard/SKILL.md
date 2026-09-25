---
name: resource-guard
description: >-
  Agent-only operator procedure for Firstmate's central per-task resource guard.
  Use before dispatching a resource-intensive task, when a task's resource process-event reports a pause or error, before resuming a resource-paused task, and when supervising bounded creator/critic/correction review loops.
  Owns intake classification, truthful attribution declarations, safe-boundary steering, captain-authority binding, and review-loop operation; bin/fm-resource-guard.sh owns numeric policy and record mechanics.
user-invocable: false
metadata:
  internal: true
---

# resource-guard

Use this procedure for a lane that can consume substantial metered model capacity or repeat expensive review.
This skill owns operator decisions and sequencing.
[`bin/fm-resource-guard.sh`](../../../bin/fm-resource-guard.sh) owns thresholds, window evaluation, schemas, storage, idempotence, retention, and exact commands; read its complete header before first use.
Do not reproduce its arithmetic in a prompt, another script, or a harness adapter.

## Decide whether the lane needs a guard

Guard the lane before dispatch when any of these is true:

- the captain explicitly asks for a budget, burn cap, reserve, or bounded review loop;
- the plan calls for three or more simultaneous provider-consuming lanes;
- the lane includes repeated broad creator/reviewer/tester cycles, a large benchmark or evaluation sweep, or another workload reasonably capable of spending 15 quota points;
- current applicable headroom is at or below the default reserve plus the declared next tranche;
- uncertainty about the workload could plausibly cross one of those conditions.

Do not guard ordinary short edits solely because a model is involved.
When uncertain about the amount of work, prefer one guarded lane over speculative parallel lanes.
The guard is task-bound, not a machine-wide provider policy and not a substitute for dispatch selection.

## Establish the budget before spawn

Resolve the task id, concrete provider, account when quota telemetry has multiple rows, model, and applicable scopes from the same authoritative catalog and quota evidence used at dispatch.
Never infer provider, account, credential, or quota scope from a harness or model name.
Read `quota-axi --json` through the guard's default path rather than copying its payload into a brief or chat.

Declare a bounded tranche: the most quota points the next approved unit of work could consume before another checkpoint.
The default is the guard's 15-point task limit.
Use a smaller tranche when the next unit is genuinely smaller; do not lower it to make an unsafe reserve calculation pass.

Declare attribution truthfully:

- `exact` only when this task is the sole consumer of every selected provider/account window;
- `dominant` only when other use exists but reliable evidence establishes this task as the dominant consumer;
- `shared` when named concurrent tasks or outside activity share a selected window;
- `unknown` when exclusivity and dominance are unproved.

Name every known concurrent task with `--concurrent-task`.
A shared or unknown measurement remains a provider-window delta, not claimed task burn.
Do not turn uncertainty into zero spend or an exact estimate.

Run `start` after the task record and instructions exist but before `fm-spawn`.
A healthy start registers the monitor, and `fm-spawn` injects the harness-independent safe-boundary overlay when the budget record exists.
A pause result at start means do not dispatch; `fm-spawn` also refuses any budget that is not active.
Finalize that pause, or any pause raised before `fm-spawn` recorded the dispatch, with `fm-resource-guard.sh pause <task-id> --pre-dispatch`, then resume only through the near-reset proof or captain authority below.
An unavailable or ambiguous provider/account/scope result is a real blocker to unguarded dispatch; correct the selection or escalate the uncertainty rather than inventing a value.

## Handle a resource notification

On a `procevent resource ...` notification, load `process-event-sources` first and read the captured result through its contract.
Then inspect `fm-resource-guard.sh status <task-id>`.
The result is already a deterministic policy decision; do not manually reinterpret percentages to overrule it.

For `pause-required`:

1. Determine whether the worker currently owns a normal edit/test action or a branch-owning validation action.
2. Send one durable instruction to stop at the next safe ownership boundary and preserve every branch and file.
3. Do not interrupt, exit, stash, reset, switch branches, abort validation, or start a competing validation run merely to make the pause immediate.
4. During validation, let the current supported action reach a gate or let branch custody return under the validation owner's own protocol.
5. Reconcile current worker state until its newest task status says it is paused at the resource boundary.
6. Run `fm-resource-guard.sh pause <task-id>`; it refuses unless that worker evidence exists and is stamped no earlier than the pause request.
7. Acknowledge the process-event result only after the safe pause is durable.

For `resumed`, the proven near-reset floor reopened the budget; tell the worker it may resume.
For `awaiting-authority`, the lane stays paused until a captain decision, redesign, or re-scope.
A monitor-time unavailable or malformed quota read arrives as `pause-required` with reason `telemetry_unavailable`; handle it like any other pause.
For `error`, preserve the task and report the concrete telemetry or local-record failure; the monitor stays registered and retries.
For `retired`, the budget was retired and the source has ended.
Never continue on a cached, guessed, or manually entered percentage.
A malformed or reset-discontinuous window is unavailable evidence, not zero and not full capacity.

## Resume only through recorded authority

A reserve-floor pause can reopen automatically only when a later guard check proves the guard's near-reset exception for the remaining bounded tranche.
No other recovered telemetry, elapsed time, new session, restart, or operator judgment is resume authority.

For a captain-approved revised budget:

1. Create a distinct backlog task for the captain's call and hold it through `fm-captain-hold.sh hold`.
2. Bind that exact open lifecycle with `fm-resource-guard.sh bind-authority <task> <captain-call>`.
3. Ask for a decision whose answer file contains exactly one `resource_budget_points=<number>` line and, only when changing the next tranche, one `resource_tranche_points=<number>` line.
4. Record the captain's actual answer through `fm-captain-hold.sh answer --decision-file`.
5. Run `fm-resource-guard.sh resume` with the same authority task, same decision file, and a fresh quota snapshot.
6. Resume the worker only after the guard reports active.

The revised number changes the task burn allowance, never reserve floors.
When the pause is unavailable or reset-discontinuous telemetry, the same answer starts a fresh versioned baseline from the current snapshot; resume refuses if that snapshot is still unavailable.
The guard matches the answer digest and exact hold lifecycle without copying captain text into resource events.
A released, re-held, later, mismatched, or synthetic answer is not authority.

A repeated-review pause may instead reopen through a recorded `redesign` or `rescope` review action.
That is authority to start a materially new bounded review strategy, not authority to repeat the same loop under a new label.

## Operate bounded reviews

Record every guarded review phase against an exact immutable head.
Actor ids must identify fresh sessions without personal data.
Provider and model-family values must be privacy-safe canonical ids.

The allowed sequence is:

1. one creator pass on a frozen head;
2. one full critic pass from a different session;
3. at most one accepted correction pass owned by the creator;
4. one focused delta review of the corrected head;
5. one complete independent review of the exact final head.

Use a different provider or model family for critic, delta, and final review whenever it is available and appropriate.
When the same provider and family are genuinely necessary, record a concrete privacy-safe reason slug with `--same-family-reason`; absence of another login or unknown quota is evidence to report, not a family inference.

Record a failure only from the critic or latest delta reviewer that actually reviewed that exact head.
Use a stable privacy-safe theme slug for materially the same finding.
The second consecutive failure of that theme stops the lane, and so does any failure after the accepted correction.
Do not buy a third same-theme attempt with more review cycles; redesign, re-scope, or seek a captain-approved revised budget.
A changed theme does not erase an already spent correction pass.

## Milestones and completion

Emit a milestone at the meaningful task boundaries supported by the guard: checks green, report accepted, branch landed, or PR merged.
Do not emit token streams, prompts, diffs, file contents, credentials, or raw provider payloads.
The local event feed is a minimized operational record suitable for the private weekly review, not a billing ledger.

On landed task cleanup, `fm-teardown.sh` retires the monitor and emits the terminal event before removing live budget state.
Do not hand-delete a budget, pause, evaluation, event, lock, or process-event record.
If retirement refuses, preserve the task records and investigate the named corruption or ownership problem.
