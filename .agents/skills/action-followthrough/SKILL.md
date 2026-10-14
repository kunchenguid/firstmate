---
name: action-followthrough
description: Load when recording the next action of a task at intake, when an action incident (ready-but-unstarted, acknowledged-but-unexecuted, over-grant, overdue gate) is reported, and before treating a steered or dispatched action as done.
user-invocable: false
metadata:
  internal: true
---

# Action follow-through

Delivery, acknowledgement and registration are intermediate evidence.
An action is done only with a native result and, where the task requires it, a native acceptance receipt.
`bin/fm-action.sh` and `bin/fm-action-lib.sh` own the ledger, the fold and every incident definition; this skill only describes the loop around them.

## Trigger and record

Inbox writes from `fm-send.sh` admit ordinary steered actions automatically, including idempotent and remote inbox writes.
Internal fire-and-forget supervision nudges are excluded and need no execution tracking.
Launch submission and lifecycle control record their native start and result through the same library.
Other next actions use `fm-action.sh admit`, classifying them as one of three classes.
- `authorized`: name the exact grant in `--source` and the exact operation; set `--units` to the counted amount the grant allows.
- `human-decision` or `external-gate`: put the pending question in `--operation`, name the owner who must answer, and list the independent ready actions in `--ready-with` (or `none`).
Never write a generic word such as `yolo` or `auto` as a source, never invent a grant, and never answer or close a captain-held task from the ledger.
The `--inbox` field links a steering record, whose move to `handled/` counts as acknowledgement and nothing more.

## Evidence required

- `start` is recorded by the code that natively begins the action, never by the request that asked for it.
- `result` is `ok`, `refused` with a concrete reason, `failed` with a concrete reason, or `answered` for a gate.
- `accept` requires the canonical native receipt matching the task, action, head, run and attempt bound at admission, with the resulting generation recorded by a native relaunch transition.
  Native results retain the admitted head even if the worker commits while the operation finishes; acceptance checks current evidence freshness separately.
  The launch and control owners produce these receipts; an ordinary turn ending or a busy event cannot certify the requested operation.
  To execute a steered lifecycle operation through `fm-control.sh`, set `FM_ACTION_ID=steer-NNN` and `FM_ACTION_ATTEMPT=NNN.msg`; the admitted operation must equal the native verb.
  Other operations still need their native execution owner to record `start` and `result`; unsupported acceptance evidence remains unknown.
- Stale or inaccessible evidence is unknown, never absence and never success: `fm-action.sh probe <path>` prints `present`, `absent`, or `unknown` with the blocked directory and a read-only fallback route, and acceptance refuses on anything but `present`.
  A user-level search that hid a permission-denied read once produced a false absence claim; report the read as unknown and take the fallback instead.
- A legitimate wait is recorded with `hold` and a finite `--until`; there is no open-ended hold.

## Who acts

`fm-watch.sh` polls every task ledger alongside inbox loss detection, including tasks without a live endpoint and remote parent-route ledgers, and routes incidents into its existing durable check queue with per-incident deduplication.
For a parent-route incident, use its emitted ledger directory as `FM_STATE_OVERRIDE` when recording the response.
`fm-action.sh incidents <task>` is read-only and reports:
- `unacked-unstarted` and `acked-unexecuted`: the action's owner starts it or records a concrete refusal; firstmate follows up when the owner does not.
- `over-grant`: stop spending units and report the overrun; do not continue under the old grant.
- `result-unconsumed`: consume or report the returned validation call before doing further work.
- `gate-overdue`: surface the pending question to its owner while the independent ready actions keep running.
A started action is never interrupted to meet a timing target.
The existing teardown owner retires action ledgers, receipts, incident markers and queued incidents along with the task.

## Consume validation returns

Admit each issued `no-mistakes axi respond` or `no-mistakes axi run` call using the exact command as its operation and record its native start.
When the call returns, record `result` and consume its output or report the concrete return with `consume --reason` within `FM_ACTION_START_SECS` (default 300 seconds).
The existing ledger fold and watcher report `result-unconsumed` after that bound; acknowledging the instruction does not consume a return.
For a backgrounded drive, keep its tool session and output reference, wait for its completion and read its return, then record the result and consumption before leaving the action.
Never leave a backgrounded drive unconsumed or issue another response without reading the returned gate.
This check requires producer events from the execution owner; it does not intercept the external no-mistakes CLI or take over pipeline ownership.

## Verify

Re-run `fm-action.sh show <task>` after acting and confirm the incident cleared because of a `start`, a `result`, or a bounded `hold`, not because of an acknowledgement.
`tests/fm-action-ledger.test.sh` exercises this loop end to end, including the negative controls for holds and healthy long runs.

Branch wiring and live adoption are distinct.
Live adoption is PENDING on the scheduler correction in [PR #7234](https://github.com/kunchenguid/firstmate/pull/7234); this change adds no daemon, timer or process-event source.
