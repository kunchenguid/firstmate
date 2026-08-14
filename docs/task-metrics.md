# Task metrics

Firstmate emits one JSON object per completed ordinary task to the home-local, gitignored `data/task-metrics.jsonl` file.
Secondmate runtime records are excluded because they are persistent homes rather than backlog tasks.

`bin/fm-teardown.sh` prepares the row only after every non-destructive refusal gate has passed.
The private `state/<id>.task-metrics-row` receipt preserves the prepared row while worktree and endpoint cleanup runs.
Teardown commits the row after that cleanup succeeds and before it retires task metadata and status.
If cleanup fails, the receipt remains but the JSONL row is not emitted.
If the append fails, teardown retains the receipt and task metadata for a safe retry.
The commit path validates the existing JSONL file, serializes appends with a home-local lock, and treats an existing row for the same task id as success.

## Derivation rules

The helper populates identity and routing fields directly from `state/<id>.meta`.
Fresh spawns record `dispatched_at` once in UTC, and relaunches preserve that original value.
`date` is derived only from a valid recorded dispatch timestamp.

The mechanically derived counters and outcomes are:

- `pipeline_runs` counts no-mistakes runs whose durable repository path and branch match the task exactly.
- `fix_rounds` counts durable no-mistakes `auto_fix` rounds for review and test steps only.
- `decisions_raised` counts status events classified as `needs-decision` or `blocked` by `bin/fm-classify-lib.sh`.
- `ci_green_first_push` remains null because current durable no-mistakes records retain only each run's latest pushed SHA, not the first pushed SHA or a complete workflow-run history for it.
- `merged` and `outcome` use the recorded PR's current forge state, or the last durable `done` or `failed` status when no PR is recorded.

Tasks outside no-mistakes mode have zero no-mistakes pipeline runs and fix rounds by definition.
When no-mistakes records or forge observations are unavailable, affected fields remain null instead of becoming zero or false.

## Fields that remain null

Judgment-only fields remain null because durable records do not distinguish correction from escalation or reliably attribute human and agent intervention.
This includes attribution, intervention counts, correction counts, self-corrections, validation nudges, agent deaths, rebases, vacuous-test judgments, and blocked duration.
`title` and free-form `notes` also remain null because the selected durable inputs do not own them.

`tokens_consumed` is always null and `token_note` explains that per-task durable records cannot attribute shared-session token use.
No process total, conversation estimate, or concurrent-lane aggregate is assigned to one task.

`done_at`, `wall_clock_min`, and `blocked_min` remain null until status events carry durable timestamps with lifecycle semantics sufficient for mechanical derivation.
File mtimes and conversation timestamps are not substitutes for that dependency.

## Manual use

Run the complete operation with:

```bash
bin/fm-task-metrics.sh emit <task-id>
```

The `prepare` and `commit` actions are lifecycle primitives for guarded teardown and recovery.
Read the script header before invoking either phase separately.
