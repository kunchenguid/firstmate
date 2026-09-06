Mode: Unknown harness fallback.

This primary harness does not have a verified watcher wake adapter.
Follow the generic supervision contract in `AGENTS.md`.
First cycle: drain queued wakes, then choose a supervision wait that the harness can actually wake from.
Ordinary wake: drain, handle all emitted wakes, reconcile open decisions and unread status lines, and run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`, then repeat that verified wait while supervision is still required.
Before that acknowledgement, interruption leaves the work durable for idempotent re-handling.
Use `bin/fm-watch-arm.sh` only when the harness has a tracked background mechanism that survives the tool call and notifies the model on process exit.
Use `bin/fm-watch-checkpoint.sh` as a bounded foreground wait when that wake mechanism is not verified; its help owns the deadline and exit-status contract.
After a quiet `checkpoint: no actionable wake` deadline, drain queued wakes and process newly visible user input before continuing; any other `checkpoint: FAILED` or already-running line is a failed wait, not a quiet deadline.
Never use shell `&` for watcher supervision.
Failure or missing cycle only: drain queued wakes, inspect the failure and current watcher ownership, then restore the same verified wait shape.

Record new verification evidence before promoting an unknown harness to a named snippet.
