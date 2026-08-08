Mode: GitHub Copilot CLI background notification.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Start `bin/fm-watch-arm.sh` as one standalone asynchronous Bash tool call.
4. Never use shell `&`, a pipe, or a bundled command for watcher supervision.
5. Trust only the arm's one-line `watcher: started`, `watcher: attached`, or `watcher: FAILED` status.
6. After a successful start or attach, end the turn while the asynchronous command remains the live wait.
7. Copilot emits a system notification when that command completes.
8. On that notification, drain queued wakes before reading further output, then handle the actionable reason and start the next asynchronous cycle when supervision is still needed.
9. Waiting on a healthy cycle is silent.

The repository `agentStop` hook is the backstop.
It blocks a blind turn ending and asks Copilot to restore the same asynchronous supervision path.
