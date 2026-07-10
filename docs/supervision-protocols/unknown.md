Mode: Unknown harness fallback.

This primary harness does not have a verified watcher wake adapter.
Follow the generic supervision contract in `AGENTS.md`.
Drain queued wakes first, then choose a supervision wait that the harness can actually wake from.
Use `bin/fm-watch-arm.sh` only when the harness has a tracked background mechanism that survives the tool call and notifies the model on process exit.
Use a bounded foreground wait over `bin/fm-watch.sh` when that wake mechanism is not verified.
Never use shell `&` for watcher supervision.

Record new verification evidence before promoting an unknown harness to a named snippet.
