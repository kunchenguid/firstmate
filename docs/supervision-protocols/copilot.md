Mode: GitHub Copilot CLI tracked asynchronous shell supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Start exactly one standalone watcher command with Copilot's shell tool in its native asynchronous mode.
   On macOS and Linux, run `bin/fm-watch-arm.sh`.
   On Windows, run `./bin/fm-watch-arm.ps1`.
   Never append a shell ampersand, use `nohup`, add a pipeline, or bundle another command into the same tool call.
3. The asynchronous tool call must return immediately.
   End the response after launch when there is nothing else to tell the captain, so captain prompts remain available while the watcher runs.
4. Copilot emits a `shell_completed` or `shell_detached_completed` notification when the watcher task ends.
   The tracked `notification` hook injects a typed handling turn only when supervision still needs attention and no healthy watcher remains.
5. On a watcher notification, read the completed shell task output when it is not already included, run `bin/fm-wake-drain.sh` first, handle the event, acknowledge it, and start the next asynchronous watcher task if supervision is still needed.
6. The `agentStop` hook is a short backstop only.
   It never runs or waits for the watcher.
   When a turn would end without a healthy watcher, it forces one bounded continuation instructing Firstmate to start the asynchronous task.
7. Copilot CLI overrides an eighth consecutive blocked stop.
   Firstmate stops at seven, using the last continuation to report the ceiling; queued events remain durable, and a real captain prompt resets the sequence.
8. Waiting on a healthy asynchronous watcher task is silent.

The watcher remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains its verified arm wrapper.
`bin/fm-watch-arm.ps1` is the Windows shell-tool bridge to that same wrapper.
The private bounded-continuation record is `state/.turnend-copilot-continuations`.
