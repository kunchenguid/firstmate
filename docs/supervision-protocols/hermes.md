Mode: Hermes managed background-process notification.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: call Hermes's `terminal` tool once with `command="bin/fm-watch-arm.sh"` and `terminal(background=true, notify_on_complete=true)`, using the Firstmate root as `workdir`.
4. Never bundle the arm command with another command.
5. Never use shell `&` for watcher supervision.
   The project-local `firstmate-primary` plugin maps Hermes `pre_tool_call` to `bin/fm-arm-pretool-check.sh`, so unsafe arm shapes are blocked before execution.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one tracked live cycle exists.
7. End the turn after a successful start or attach.
   Hermes keeps the background process in its managed registry and queues completion output into this same persistent CLI session.
8. Ordinary wake: the `[IMPORTANT: Background process ...]` completion starts a new turn in the same CLI session.
   Drain queued wakes first, handle the emitted records, run their exact acknowledgement, then start exactly one fresh managed background process when supervision is still needed.
9. Do not invent a wake from an attach-status line alone.
   Drain and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line in the completion notification.
10. Failure or missing cycle only: treat a nonzero completion or `watcher: FAILED ...` as an alarm, drain first, inspect the failure, and repair with one fresh managed background arm.
11. Recovery only: if a forced restart is genuinely needed, use the same managed terminal mechanism with `command="bin/fm-watch-arm.sh --restart"`.
12. Do not send idle progress while the tracked process is parked.

The tracked `.hermes/plugins/firstmate-primary` plugin uses Hermes `post_llm_call` plus `ctx.inject_message()` as the final turn-end backstop.
When the shared predicate reports a blind turn end, it injects one bounded Hermes turn-end recovery retry and suppresses recursion for that injected retry.
The plugin is loaded only through `bin/fm-hermes-primary.sh`, which forces the verified classic persistent CLI and enables project-plugin discovery without changing provider credentials.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
