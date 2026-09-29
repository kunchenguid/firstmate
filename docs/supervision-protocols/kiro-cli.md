Mode: kiro-cli doorbell owner, foreground checkpoint fallback.

kiro-cli's `Stop` hook fires at every turn end but it CANNOT keep this session supervised: exit 2 and a `followup_message` are no-ops on `Stop`, and the one continuation it honors (a `{"decision":"block"}` reply on kiro-cli 2.24.1) fires once and ends with no further `Stop` ([verification](../verification/supervision.md#kiro-cli-2241-hook-surface-and-process-tree-2026-09-29)).
The structural wake path is therefore external, built from the existing durable queue, doorbell, and watcher: `bin/fm-kiro-primary.sh` launches this V3 session with the tracked project hooks; the `SessionStart` hook runs the session-start digest into context and publishes this pane as `state/.primary-endpoint`; the `UserPromptSubmit` and `Stop` hooks re-check that record every turn for the lock-owning session and republish it when it is missing or names another pid or pane, because Kiro fires `SessionStart` only for a conversation's first prompt; the hooks keep one doorbell owner running (`bin/fm-primary-doorbell.sh`), which owns every watcher cycle and types one constant doorbell line into this pane after each actionable close; and the `UserPromptSubmit` hook attaches the drained queue as context for that turn.
The session-start digest names the live path: `KIRO_PRIMARY_ENDPOINT: structural wake doorbell published` selects the doorbell protocol, while `KIRO_PRIMARY_ENDPOINT: structural wake doorbell unavailable (...)` selects the foreground checkpoint fallback.
A later turn's `UserPromptSubmit` context that carries `KIRO_PRIMARY_ENDPOINT: structural wake doorbell published` means the every-turn check published it then, and selects the doorbell protocol from that turn on.

Doorbell protocol, when this session owns supervision, away mode is not active, and the doorbell is published:
1. Drain first with `bin/fm-wake-drain.sh` when this turn started without attached wake context; a doorbell turn already carries the drained context from the `UserPromptSubmit` hook.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm, re-arm, and the doorbell ring are owned by the doorbell owner, never by you: never run `bin/fm-watch-arm.sh`, `--restart`, or a foreground checkpoint on this path, because each one kills or shadows the owner's cycle; the `PreToolUse` hook blocks them while the owner can run.
3. Ordinary wake: the doorbell line `: Firstmate wake waiting: ...` started this turn and its context is already attached; handle it, acknowledge as in step 1, then end the turn.
4. A wake that arrives while this pane is busy or its composer is non-empty stays queued and is rung once the composer is empty, unless this turn already drained and acknowledged it; a doorbell whose drain then shows nothing still gets its printed acknowledgement.
5. A doorbell line `: Firstmate watcher continuity FAILED: ...` means the owner stopped after repeated failed watcher starts: read the two records it names, then run `bin/fm-primary-doorbell.sh ensure` once; it refuses while the failure is still cooling down, and the next `Stop` retries after that.
6. Never use shell `&` for firstmate watcher supervision.

Foreground checkpoint fallback, when the digest reported the doorbell unavailable:
7. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, sourcing `__FM_X_MODE_ENV__` first when Relay is active.
8. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
9. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued captain message now visible in the pane, then start the next checkpoint.
10. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.
11. Without a published endpoint no doorbell owner runs, so the `Stop` hook's plain `bin/fm-watch-arm.sh` re-arm is only a backstop that keeps the durable queue fed.

kiro-cli cannot reason while a foreground tool call is running, which is why the doorbell path is preferred: it returns control at every turn end, so captain messages and queued wakes are handled without holding the pane inside a checkpoint.

Control nuance for interrupting and exiting this session (verified live, kiro-cli 2.22.1; the docs' single "Ctrl+C" is wrong for the current TUI):
- Press `Esc` to CANCEL the current streaming turn - it leaves the session alive.
- Press `Ctrl+C` TWICE (or `Ctrl+D` twice) to QUIT the process; a single `Ctrl+C` only shows "Press Ctrl+C or Ctrl+D again to exit".
- `/quit` or `/exit` also ends the session, auto-saving the conversation.
- Resume a prior session with `kiro-cli --resume` (most recent in this directory) or `kiro-cli --resume-id <SESSION_ID>`; enumerate sessions with `kiro-cli chat --list-sessions --format json`.
