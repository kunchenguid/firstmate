<!-- fm:supervision-protocol:v3 harness=agy-acp -->
Mode: Antigravity ACP background-notify supervision.

Antigravity ACP awaits `.agents/hooks.json` `Stop` hooks before completing a prompt turn, so synchronous Stop-hook parking blocks incoming user messages and is disabled under `antigravity acp`.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with Antigravity ACP's asynchronous `run_command` tool, as its own call (`WaitMsBeforeAsync: 500`, `IsDaemon: false`), NOT by ending the turn on the Stop hook:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec __FM_AGY_ACP_ARM__`
4. Trust only the arm's one-line status (`watcher: started ...` or `watcher: attached ...` means a live cycle exists; `watcher: FAILED ...` means supervision is down, so fix and re-arm).
5. After starting or attaching the background arm task, end your turn with no extra tool calls so the prompt turn completes cleanly and the captain keeps full input responsiveness while the background arm runs.
6. Waiting is silent: do not poll the background arm task or send idle progress while it waits.
7. Never use shell `&`, truncating pipes, or command bundling for watcher supervision.
   Those patterns are denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh --agy`) registered in `.agents/hooks.json`.

When the background `run_command` arm finishes with an actionable wake (`signal:`, `stale:`, `check:`, or `heartbeat`):
1. Run `bin/fm-wake-drain.sh` first.
2. Handle all emitted wakes, open decisions, and unread status lines, then run the exact `WAKE_ACK_REQUIRED --ack-through` command.
3. Ordinary wake: re-arm one fresh background `__FM_AGY_ACP_ARM__` call (`WaitMsBeforeAsync: 500`, `IsDaemon: false`) whenever `bin/fm-supervision-lib.sh` still reports supervision needed, then end the turn cleanly.
4. Do not invent a wake from an attach-status line alone.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain (see [`watcher-continuity.md`](../watcher-continuity.md)).

On an ACP host that does not wake an idle session when a background task completes, queued wakes stay durable in `state/.wake-queue` and are drained with `bin/fm-wake-drain.sh` at the start of the next turn.

The primary project `Stop` hook runs `bin/fm-turnend-guard-agy.sh`, which detects `antigravity acp` and delegates immediately to the non-parking bounded backstop (`bin/fm-turnend-guard.sh --agy`, 3-block repair nag before failing open with `{}`) instead of parking for the hook timeout.
