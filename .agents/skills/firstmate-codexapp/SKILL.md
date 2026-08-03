---
name: firstmate-codexapp
description: >-
  Agent-only playbook for creating, steering, supervising, recovering, and retiring Codex Desktop-visible Firstmate workers through the codex-app backend.
user-invocable: false
metadata:
  internal: true
---

# firstmate-codexapp

Use this playbook before operating a Codex Desktop-visible Firstmate worker.
Read `docs/codex-app-backend.md` for the current setup and limits.
Load `harness-adapters` before spawn, recovery, steering, interruption, or teardown as usual.

## Dispatch

Resolve the normal task brief and project first.
Select `backend=codex-app` only with `harness=codex`.
It supports ship and scout tasks, not secondmates.
Do not substitute Desktop host-tool choreography for the backend when a durable Firstmate task is required.

Spawn through the normal entry point:

```sh
bin/fm-spawn.sh <task-id> <project> --harness codex --backend codex-app
```

The adapter leases an isolated worktree, creates a durable Codex thread, submits the marked brief, and records the thread id in task metadata.
The brief must retain the normal absolute `state/<id>.status` instructions.
Treat spawn as successful only after the adapter observes a new valid lifecycle line from that thread.

## Supervision

Use `fm-send.sh`, `fm-peek.sh`, and `fm-crew-state.sh`.
An active follow-up is steered into the current turn; an idle follow-up starts a new turn.
Busy and idle are exact app-server lifecycle states.
Treat a missing or unreadable thread as unknown or dead through the shared backend classifier, never as idle.

## Recovery and retirement

The per-home app-server restarts automatically on the next create, send, read, lifecycle, interruption, or archive operation.
The durable thread id remains the endpoint authority across that restart.
Never invent a replacement thread while recorded metadata still identifies a readable endpoint.

Retire through `fm-teardown.sh`.
It validates the exact metadata binding, interrupts an active turn, archives the thread, and then returns the worktree.
If archive fails, preserve the metadata and lease for recovery.
