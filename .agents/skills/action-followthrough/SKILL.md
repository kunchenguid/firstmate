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

Record each next action at intake with `fm-action.sh admit`, classifying it as one of three classes.
- `authorized`: name the exact grant in `--source` and the exact operation; set `--units` to the counted amount the grant allows.
- `human-decision` or `external-gate`: put the pending question in `--operation`, name the owner who must answer, and list the independent ready actions in `--ready-with` (or `none`).
Never write a generic word such as `yolo` or `auto` as a source, never invent a grant, and never answer or close a captain-held task from the ledger.
The `--inbox` field links a steering record, whose move to `handled/` counts as acknowledgement and nothing more.

## Evidence required

- `start` is recorded by the code that natively begins the action, never by the request that asked for it.
- `result` is `ok`, `refused` with a concrete reason, `failed` with a concrete reason, or `answered` for a gate.
- `accept` needs a native receipt for the exact task, head and run; stale or inaccessible evidence is unknown, not success.
- A legitimate wait is recorded with `hold` and a finite `--until`; there is no open-ended hold.

## Who acts

`fm-action.sh incidents <task>` is read-only and reports:
- `unacked-unstarted` and `acked-unexecuted`: the action's owner starts it or records a concrete refusal; firstmate follows up when the owner does not.
- `over-grant`: stop spending units and report the overrun; do not continue under the old grant.
- `gate-overdue`: surface the pending question to its owner while the independent ready actions keep running.
A started action is never interrupted to meet a timing target.

## Verify

Re-run `fm-action.sh show <task>` after acting and confirm the incident cleared because of a `start`, a `result`, or a bounded `hold`, not because of an acknowledgement.
`tests/fm-action-ledger.test.sh` exercises this loop end to end, including the negative controls for holds and healthy long runs.
