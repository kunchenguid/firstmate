---
name: gate-attribution
audience: swarm-plugin
description: Per-task gate dispatch protocol for reviewer/test_engineer set-dispatch attribution. Activates when dispatch_lanes returns set-dispatch verdict rows that must be attributed to plan tasks. Documents single-task attribution plus parseable set-dispatch reviewer/test_engineer rows.
---

# Gate Attribution

## The rule
The gate tracker attributes reviewer/test_engineer dispatches PER TASK. A
single-task prompt still attributes by `task_id` / `taskId` / unambiguous prompt
task ID. A set-dispatch can also count per-task when the reviewer/test_engineer
output includes parseable per-task rows:

```
[REVIEWED] | task-2.1 | APPROVED | ...
[TESTED] | 2.1 | PASS | ...
```

`[REVIEWED]` verdicts are `APPROVED | REJECTED | CONCERNS`; `[TESTED]` verdicts
are `PASS | FAIL | SKIPPED`. Rows with `task-X.Y` are normalized to `X.Y`;
unsafe or non-plan IDs are ignored.
Each parseable per-task verdict row creates gate evidence (regardless of verdict
value); the gate's pass/fail decision is made elsewhere from the accumulated
evidence. If no rows are parseable, attribution falls back to the single-task
rule.

## Protocol
1. **For unrelated or high-risk tasks:** Dispatch separate reviewer and/or test_engineer lanes with exactly ONE taskId.
2. **For a true set-dispatch:** Require one `[REVIEWED] | task-id | verdict | ...` (or `[TESTED] | ...`) row per task in the returned output. Each parseable row creates gate evidence; the gate decision is made from the accumulated evidence.
3. **Minimize overhead via parallel dispatch when set-dispatch is not appropriate:**
   ```
   dispatch_lanes_async with:
   - common_prompt: shared verification context
   - lanes: one lane per task, each with a single taskId
   - max_concurrent: up to 3
   ```
   This protocol applies only in sessions whose actual tool list includes the
   swarm controller's dispatch tools; on hosts without the controller it is not
   applicable — do not fabricate set-dispatch rows.
4. **Collect + attribute:** Single-task lanes auto-attribute to their taskId; set-dispatch rows auto-attribute per parsed row.
5. **Do NOT rely on prose summaries:** A batched dispatch without parseable rows is ambiguous and does not count per-task.

Gate evidence is persisted independently as `.swarm/evidence/{taskId}.json` for each task. Each parseable set-dispatch row causes the hook to write one task-scoped evidence file for that task (regardless of verdict value); a single multi-task evidence file cannot satisfy any task.

## Optimization for trivial tasks
For pure ceremony gates (1-line doc fix):
```
TASK: Verify task X.Y. Run skill-mirrors.test.ts. PASS/FAIL.
taskId: X.Y
```

## Why this exists
The gate tracker (the delegation-gate runtime) keys delegation chains by
`sessionID`. Ambiguous multi-task prompts still fail closed, but parseable
`[REVIEWED] | task-id | ...` rows provide explicit per-task attribution for
set-dispatches. Tracked in issue #1746 item 6.
