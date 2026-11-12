---
name: t3-main-thread-lead
description: >-
  Load when the captain runs Firstmate as the lead inside an active T3 Code main thread
  and uses T3 MCP orchestration (delegate_task, task_status, t3_thread_send, task_cancel)
  instead of fm-spawn terminal backends for delegated children.
  Covers durable delegation records, recovery after lead restart, supervision import,
  isolated worktree enforcement for coding workers, and conditional replacement boundaries
  versus ordinary fm-spawn supervision.
user-invocable: true
metadata:
  internal: true
---

# T3 main-thread lead

Use this skill only when the captain explicitly keeps Firstmate in the main T3 thread and accepts delegated children in Lineage only.
Ordinary repository defaults still describe terminal-backed fm-spawn supervision; this mode is opt-in per home.

## Activation

Create the presence flag `config/t3-main-thread-lead` in the active Firstmate home, or export `FM_T3_MAIN_THREAD_LEAD=on` for the lead session.
Verify with `bin/fm-t3-delegation.sh enabled`.
Do not add `backend=t3` or change `config/backend`; T3 tools are invoked by the lead inside the app thread, not by shell backends.

## Replacement boundaries

When this mode is active for a home session:

- Dispatch coding and review children through T3 `delegate_task`, not `bin/fm-spawn.sh`.
- Same-task follow-ups use `t3_thread_send` with `mode=steer` and a stable `clientRequestId` per steer round.
- New review rounds call `delegate_task` again with a new `taskId`; never continue a review by messaging an old `childThreadId`.
- Recovery reads only this home's `state/t3-delegations/` records and reconciles them with bounded `task_status` and `t3_thread_read` on recorded ids; never scan unrelated top-level threads.
- Startup and supervision for this mode rely on T3 app notifications plus `bin/fm-t3-delegation.sh import-status --notify`; do not assume a terminal watcher is armed for delegated children.
- Terminal-backed ships, scouts, secondmates, and fm-spawn workflows elsewhere in the fleet stay unchanged.

## Per-task workflow

1. Resolve the Firstmate backlog task id, delivery mode, yolo posture, project path, and branches the same way as a normal ship or scout intake.
2. Choose a stable `clientRequestId` for this delegation round; reuse it only when retrying the same round, never for a new review round.
3. Record intent before calling T3 tools:

```bash
bin/fm-t3-delegation.sh record-intent \
  --client-request-id "<stable-id>" \
  --task-id "<fm-task-id>" \
  --parent-thread-id "<main-t3-thread-uuid>" \
  --kind ship \
  --mode no-mistakes \
  --yolo off \
  --project "<absolute-project-path>" \
  --base-branch main \
  --ship-branch "fm/<slug>" \
  --source-worktree "<caller-worktree-path>" \
  --isolation-required on
```

4. Call `delegate_task` from the main thread; write the JSON response to a temp file and bind it:

```bash
bin/fm-t3-delegation.sh bind-dispatch \
  --client-request-id "<stable-id>" \
  --parent-thread-id "<main-t3-thread-uuid>" \
  --json /path/to/delegate_task.json
```

5. On each T3 completion or failure notification, fetch `task_status`, then import and publish supervision:

```bash
bin/fm-t3-delegation.sh import-status \
  --client-request-id "<stable-id>" \
  --parent-thread-id "<main-t3-thread-uuid>" \
  --json /path/to/task_status.json \
  --notify
```

6. After lead restart or context loss, run `bin/fm-t3-delegation.sh recover --parent-thread-id "<uuid>"` and reconcile every listed `t3TaskId` before dispatching duplicates.

## Isolated worktree for coding workers

T3 `delegate_task` shares the parent's working copy by default.
Any child that will edit tracked project files must acquire its own worktree before editing.

Before delegating implementation, print or follow `bin/fm-t3-delegation.sh worktree-brief` and use `t3_thread_launch` with `workspaceStrategy.type=worktree` (or bind an existing worktree).
After the worktree exists:

```bash
bin/fm-t3-delegation.sh assert-isolated --project "<project>" --worktree "<absolute-worktree>"
bin/fm-t3-delegation.sh record-isolated-worktree \
  --client-request-id "<stable-id>" --project "<project>" --worktree "<absolute-worktree>"
```

Research-only scouts may set `--isolation-required off` and stay read-only on the shared copy.

## Cancellation and cleanup

- Stop delegated work with T3 `task_cancel`, confirm terminal state via `task_status`, then `bin/fm-t3-delegation.sh cancel-bind`.
- T3 stop or archive does not merge, land, or delete git work; use the normal merge authority and teardown paths for landed work.
- Never discard unlanded git work when cancelling a delegation.

## Outcome mapping

Imported status distinguishes scout reports, PR-ready implementation, branch-ready local-only work, and failures.
Records exclude credentials and full environment payloads.
Automatic merge remains forbidden; landing follows the task's recorded mode and captain merge authority.

## Authoritative references

- Operator guide: [`docs/t3-main-thread-lead.md`](../../../docs/t3-main-thread-lead.md)
- Record mechanics: `bin/fm-t3-delegation-lib.sh` header and `bin/fm-t3-delegation.sh --help`
- Configuration: [`docs/configuration.md`](../../../docs/configuration.md) "T3 main-thread lead"
- Codex Desktop backend boundary stays separate: [`docs/codex-app-backend.md`](../../../docs/codex-app-backend.md)
