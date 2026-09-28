Mode: kiro-cli structural doorbell, foreground checkpoint fallback.

kiro-cli's `Stop` hook fires at every turn end (verified live, kiro-cli 2.22.1) but it CANNOT wake this turn: exit 2 is a no-op on `Stop`, and neither its stdout nor a `followup_message` is consumed as a continuation.
The structural wake path is therefore external, built from the existing durable queue, doorbell, and watcher: `bin/fm-kiro-primary.sh` launches this V3 session with the tracked project hooks; the `SessionStart` hook runs the session-start digest into context and publishes this pane as `state/.primary-endpoint`; the `UserPromptSubmit` and `Stop` hooks re-check that record every turn for the lock-owning session and republish it when it is missing or names another pid or pane, because Kiro fires `SessionStart` only for a conversation's first prompt; the background watcher appends every actionable wake to the durable wake queue and then rings one constant doorbell line into this pane; the `UserPromptSubmit` hook attaches the drained queue as context for that turn; and the `Stop` hook re-arms the next watcher cycle whenever work is under way and no cycle is alive (`bin/fm-primary-endpoint-lib.sh`, `bin/fm-kiro-turnend-hook.sh`).
The session-start digest names the live path: `KIRO_PRIMARY_ENDPOINT: structural wake doorbell published` selects the doorbell protocol, while `KIRO_PRIMARY_ENDPOINT: structural wake doorbell unavailable (...)` selects the foreground checkpoint fallback.
A later turn's `UserPromptSubmit` context that carries `KIRO_PRIMARY_ENDPOINT: structural wake doorbell published` means the every-turn check published it then, and selects the doorbell protocol from that turn on.

Doorbell protocol, when this session owns supervision, away mode is not active, and the digest reported the doorbell published:
1. Drain first with `bin/fm-wake-drain.sh` when this turn started without attached wake context; a doorbell turn already carries the drained context from the `UserPromptSubmit` hook.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm exactly one background watcher with `bin/fm-watch-arm.sh`; the `Stop` hook re-arms it after any later turn that would otherwise end blind.
4. Ordinary wake: the doorbell line `: Firstmate wake waiting: ...` started this turn and its context is already attached; handle it and acknowledge as in step 1, then end the turn.
   Never run a foreground checkpoint on this path: a checkpoint suppresses the ring, and a busy pane cannot be rung.
5. A wake that arrives while this pane is busy or its composer is non-empty is refused quietly and stays queued; the next turn's `UserPromptSubmit` hook attaches it, and the watcher's poll loop rings once more for the newest unrung row as soon as the composer is empty (the re-ring ladder in `bin/fm-primary-endpoint-lib.sh`, one ring per row, recorded in `state/.primary-doorbell-rung`).
6. Never use shell `&` for firstmate watcher supervision.
7. Failure or missing cycle only: drain queued wakes, inspect the failure, then arm one fresh cycle with `bin/fm-watch-arm.sh`.

Foreground checkpoint fallback, when the digest reported the doorbell unavailable:
8. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
9. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
10. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued captain message now visible in the pane, then start the next checkpoint.
11. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.
12. Do not rely on `bin/fm-watch-arm.sh` on this fallback path: without a published endpoint the background watcher cannot deliver its wake into this pane, and the `Stop` hook re-arm is only a backstop that keeps the durable queue fed.

kiro-cli cannot reason while a foreground tool call is running, which is why the doorbell path is preferred: it returns control at every turn end, so captain messages and queued wakes are handled without holding the pane inside a checkpoint.

Control nuance for interrupting and exiting this session (verified live, kiro-cli 2.22.1; the docs' single "Ctrl+C" is wrong for the current TUI):
- Press `Esc` to CANCEL the current streaming turn - it leaves the session alive.
- Press `Ctrl+C` TWICE (or `Ctrl+D` twice) to QUIT the process; a single `Ctrl+C` only shows "Press Ctrl+C or Ctrl+D again to exit".
- `/quit` or `/exit` also ends the session, auto-saving the conversation.
- Resume a prior session with `kiro-cli --resume` (most recent in this directory) or `kiro-cli --resume-id <SESSION_ID>`; enumerate sessions with `kiro-cli chat --list-sessions --format json`.
