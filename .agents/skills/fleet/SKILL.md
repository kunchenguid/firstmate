---
name: fleet
description: >-
  Open or operate Firstmate's always-on local fleet Kanban board.
  Use when the captain invokes /fleet, asks to open the task board, wants a visual backlog or fleet status view, or asks to stop or inspect the board application.
user-invocable: true
metadata:
  internal: true
---

# Fleet board

Use `bin/fm-fleet-board.sh` as the only application lifecycle entrypoint.
The script header owns the exact commands, runtime identity, port selection, paths, and environment controls.

For plain `/fleet`, run `bin/fm-fleet-board.sh open` and give the captain the URL it prints.
If opening the default browser is unavailable, the printed loopback URL is still the complete result.
For `/fleet status`, `/fleet url`, or `/fleet stop`, pass the matching subcommand and relay its result without inventing state from process listings.

The board is a projection over `bin/fm-fleet-snapshot.sh` and never owns task state.
Its lanes are Backlog, In Progress, Verification, Needs You, Waiting, and Done.
Cards move only when canonical Firstmate state changes, so do not manually reconcile a card or promise that an action moved it immediately.

An answer or request for more detail is queued through `bin/fm-inbox.sh` as a durable captain instruction.
When that note appears in the ordinary inbox drain, route it through the named task and home's existing authority, act on the instruction, and update canonical state through the normal task lifecycle.
Never treat the browser payload as authority to release, close, steer, merge, or mutate a task directly.

The application is local-only.
Never expose it through a public bind address, tunnel, reverse proxy, or shared hosting surface.
