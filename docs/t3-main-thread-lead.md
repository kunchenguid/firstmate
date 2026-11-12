# T3 main-thread Firstmate lead

Firstmate can run as the lead inside an active T3 Code main thread while keeping ordinary terminal-backed fleet behavior everywhere else.
Delegated workers appear in T3 Lineage; this home stores the binding to Firstmate backlog and task records.

This document is the operator and maintainer guide.
`bin/fm-t3-delegation-lib.sh` owns record schema and transitions.
`bin/fm-t3-delegation.sh` owns CLI entry points.
[`.agents/skills/t3-main-thread-lead/SKILL.md`](../.agents/skills/t3-main-thread-lead/SKILL.md) owns the load-triggered workflow for the lead agent.
[`verification/t3-main-thread-lead.md`](verification/t3-main-thread-lead.md) records behavioral test evidence.

## What this is not

- Not a selectable `config/backend` value and not a shell bridge to Codex Desktop host tools ([`codex-app-backend.md`](codex-app-backend.md)).
- Not a polling daemon or socket export of T3 credentials.
- Not automatic PR merge; merge authority stays with the captain unless standing yolo applies to an already-green PR.

## Activation

Create `config/t3-main-thread-lead` in the Firstmate home used by the T3 main thread, or set `FM_T3_MAIN_THREAD_LEAD=on` for that session.
Confirm with `bin/fm-t3-delegation.sh enabled`.

Repository defaults in `AGENTS.md` still describe fm-spawn supervision.
The captain opts into this mode explicitly; nothing here weakens hard rules about merge authority, unlanded work, or project edits from the firstmate primary checkout.

## Durable records

Each delegation round is keyed by `clientRequestId` under `state/t3-delegations/<clientRequestId>.json`.
Records bind:

- Firstmate `taskId` and backlog posture (`mode`, `yolo`, `kind`)
- T3 `parentThreadId`, `t3TaskId`, and `childThreadId` after dispatch
- Provider and model selection when present in tool JSON
- Project path, source worktree, optional isolated worktree, and branch fields
- Phase, outcome kind, and idempotent import digest

Records never store credentials, tokens, or full environment blobs.

## Lead responsibilities

The lead agent inside T3 calls MCP tools directly.
Shell helpers only validate and persist tool JSON the lead writes to temp files.

Typical sequence:

1. `record-intent` before `delegate_task`
2. `bind-dispatch` with the tool response
3. `import-status --notify` after `task_status` on notifications or heartbeat recovery
4. `recover` after restart to list outstanding rounds

Same-task steers use `t3_thread_send` with `mode=steer` and their own stable `clientRequestId`; record steer intent when supervision must correlate them.
New review rounds require a new `delegate_task` and new `taskId`.

## Isolated copies for implementation

Shared parent worktrees are acceptable for research.
Coding workers must use `t3_thread_launch` worktree strategy (or an existing bound worktree) before editing tracked files.
`assert-isolated` and `record-isolated-worktree` enforce and persist the isolated path.

## Supervision and notifications

T3 delivers app-native notifications to the main thread.
Import maps tool state into normal Firstmate status lines and enqueues a `signal` wake for the task when `--notify` is used.
A completed assistant turn with nested live children maps to `waiting_for_children`, not completion.
Duplicate imports with the same status digest are no-ops.

## Limits

- Helpers cannot call T3 MCP tools; a lead running outside T3 cannot complete dispatch without the app tools.
- Recovery never claims threads not recorded for this home's `parentThreadId`.
- Lineage presentation is app-owned; this home stores authoritative fleet records only.
