Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. On a manual recovery or handling turn with neither an attached packet nor an attached fallback presentation, run `bin/fm-wake-drain.sh` only when the adapter emitted its single manual-drain instruction.
   An attached complete fallback presentation has already been drained, so handle it directly without draining again.
   A published packet or fallback receipt remains the sole transaction through opt-out and later wakes; no manual drain may replace it before its exact acknowledgement.
   After handling the presented wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, handle an attached `fm-wake-context.v1` packet without draining or rebuilding the same context, then run the packet's exact acknowledgement command and start the next checkpoint.
   When no packet is attached and the checkpoint prints the manual-drain instruction, use `bin/fm-wake-drain.sh` once before starting the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, replay and handle any published transaction first; otherwise drain queued wakes, process any queued user message now visible to Codex, then start the next checkpoint.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
