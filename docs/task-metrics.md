# Task metrics

Firstmate emits one JSON object per completed ordinary task to the home-local, gitignored `data/task-metrics.jsonl` file.
Secondmate runtime records are excluded because they are persistent homes rather than backlog tasks.

The rows exist to answer one question: for a given class of work, which provider is faster, more correct, and more expensive.
The captain switches both the worker and firstmate itself between providers, so a row records the worker's runtime and the orchestrator's separately.

`bin/fm-teardown.sh` prepares the row only after every non-destructive refusal gate has passed.
The private `state/<id>.task-metrics-row` receipt preserves the prepared row while worktree and endpoint cleanup runs.
Teardown commits the row after that cleanup succeeds and before it retires task metadata and status.
If cleanup fails, the receipt remains but the JSONL row is not emitted.
If the append fails, teardown retains the receipt and task metadata for a safe retry.
The commit path validates the existing JSONL file, serializes appends with a home-local lock, and treats an existing row for the same task id as success.

## Detecting a missing row

`AGENTS.md` section 7 states the obligation: every completed ordinary task owes a row, whatever path completed it.
Emission itself runs inside guarded teardown, so a completion that takes any other path would otherwise produce silence indistinguishable from a fleet that ran no work.

`bin/fm-spawn.sh` therefore records every fresh ordinary dispatch in `data/task-metrics-dispatches.jsonl`, and `bin/fm-task-metrics.sh audit` reconciles that ledger against the emitted rows:

```bash
bin/fm-task-metrics.sh audit
```

It reports each dispatched task that is neither still under way nor represented by a row as a `gap:` line, a prepared-but-uncommitted receipt as a retryable `pending:` line, and always prints one summary line.

The ledger is the cheapest honest mechanism available, for three reasons.
Spawn is the single chokepoint every task passes through, so nothing else needs to cooperate for a dispatch to be counted.
One append per task is the smallest possible write, and the audit is a read of two small files with no network or forge call.
The ledger also outlives the evidence the alternatives would have to rely on: task metadata and status are retired by teardown, and backlog Done history is pruned to the configured retention, so reconciling against either would make an older gap undiscoverable exactly when it matters.
A dispatch record that fails to write never fails the launched task; spawn warns on stderr instead, and the audit's own dispatched-versus-row counts are what surface the shortfall.

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

### Orchestrator identity

`orchestrator` is the runtime firstmate itself was on when it dispatched the task, which is a different axis from the worker's `harness`.
`bin/fm-spawn.sh` captures it at spawn from `bin/fm-harness.sh`, the single detection owner, because that spawn process is a child of the dispatching orchestrator.
An undetectable orchestrator writes no metadata line at all, so the row reports null rather than a default that would read as a real provider.
Tasks dispatched before this capture existed also report null.

A relaunch never overwrites that original value.
When the relaunching orchestrator differs from the last known one, it is appended to `orchestrator_handoffs`, an ordered list of the runtimes that took the task over, so a provider handoff mid-task stays visible.
An undetectable relauncher becomes a null element in that list rather than disappearing from it.
The list is `[]` when the dispatching orchestrator is known and no handoff happened, and null when nothing about the task's orchestration is known.

### Completion time and wall clock

A crewmate reports completion by appending a plain `done:` or `failed:` line, which carries no time of its own, and nothing else in the fleet records when a task finished.
`bin/fm-classify-lib.sh` closes that gap: `status_terminal_capture` writes `state/<id>.terminal-at` the first time supervision observes a task's terminal event.
The watcher runs it every poll, in normal and away mode alike, and `bin/fm-wake-drain.sh` repeats it on every wake-handling and session-start turn as the backstop for a home whose watcher was down at the moment the task finished.
Teardown retires the record with the task's other durable state.

`done_at` is that observation, and `done_at_source` names its provenance as `supervision-observation` so the row states the precision it actually has: the value lags the crewmate's own append by at most one supervision poll.
File mtimes and conversation timestamps are never used.
`wall_clock_min` is the minutes between `dispatched_at` and `done_at`, to one decimal.
Both stay null when no terminal event was ever observed, and `wall_clock_min` alone drops if the recorded completion precedes the recorded dispatch, because that contradiction is not a duration.
A later unrelated status append never restamps a completion that was already observed; only a new terminal event takes a new timestamp.
`blocked_min` remains null: durable records do not carry the interval boundaries a blocked span needs.

### Token burn

`tokens_consumed` is the WORKER's token burn, read from the harness's own durable per-session records by `bin/fm-token-usage.sh`, whose header owns the per-harness store paths and field mappings.
A session counts toward a task when its recorded working directory is the task worktree or a path inside it, and its first record's timestamp falls inside the task's dispatch window.
Worktrees are isolated per task, so directory containment attributes a session to at most one task, and the window separates tasks that reuse a pooled worktree path.

`token_source` names the store the figure came from, and `token_sessions` how many sessions were attributed.
`token_input`, `token_cached_input`, and `token_output` carry uniform components - uncached input including cache writes, cache-read input, and all output including reasoning - so a comparison can normalize instead of trusting one vendor total; `tokens_consumed` is their sum.
`token_note` is null when a figure was found and otherwise states, precisely, why that provider produced none.

Coverage is deliberately partial rather than uniformly null (verified 2026-08-14):

| Harness | Durable per-session record | Result |
| --- | --- | --- |
| `claude` | `~/.claude/projects/<encoded-cwd>/<session>.jsonl`, per-message `message.usage` | attributed |
| `codex` | `~/.codex/sessions/<date>/rollout-*.jsonl`, `session_meta.cwd` plus cumulative `token_count` | attributed |
| `pi` | `~/.pi/agent/sessions/<encoded-cwd>/<session>.jsonl`, session `cwd` plus per-message `message.usage` | attributed |
| `cursor` | `~/.cursor/chats/<hash>/<uuid>/` records `cwd` and timestamps, but its store holds no token counts | null, no source exists to read |
| `opencode`, `grok`, `kimi`, `muse`, `pi-signed` | none verified | null until a durable per-session record with an attributable working directory is verified |

A figure also stays null, with the reason in `token_note`, when the task has no valid dispatch timestamp to bound the window, when the store is absent, when no session matches, or when the bounded read does not finish inside `FM_TASK_METRICS_TOKEN_TIMEOUT`.

The orchestrator's own token burn is deliberately absent from the row rather than present as a permanent null.
One orchestrator session supervises many tasks at once, so no per-task figure exists to attribute, and a field that could never be filled would only imply a gap where there is none.

## Fields that remain null

Judgment-only fields remain null because durable records do not distinguish correction from escalation or reliably attribute human and agent intervention.
This includes attribution, intervention counts, correction counts, self-corrections, validation nudges, agent deaths, rebases, and vacuous-test judgments.
`title` and free-form `notes` also remain null because the selected durable inputs do not own them.

## Manual use

Run the complete operation with:

```bash
bin/fm-task-metrics.sh emit <task-id>
```

The `prepare`, `commit`, and `dispatch` actions are lifecycle primitives for spawn, guarded teardown, and recovery.
Read the script header before invoking any of them separately.
