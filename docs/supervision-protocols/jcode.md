Mode: jcode background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with jcode's tracked background task, as its own `bash` tool call, with these three fields set EXPLICITLY:

   `bash` with `run_in_background: true`, `wake: true`, `notify: true`, and `stall_wake_seconds: 900` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. `wake: true` is LOAD-BEARING and must be written every time.
   jcode's `wake` field declares only "Wake on completion" and carries no default. Verified 2026-09-10 on v0.84.0: a session told in prose to arm with wake enabled recorded `wake=false` on the resulting task and no wake ever fired, while the identical command with an explicit `wake: true` recorded `wake=true` and woke the session the moment the task exited. An arm without it is a silent supervision outage, not a slow one.
5. Trust only the arm's one-line status.
6. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
7. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
8. After a successful start or attach status, end the turn.
   The background task remains the live wait until it returns an actionable wake or failure.
9. Waiting is silent.
10. Never use shell `&` for firstmate supervision, and never bundle the arm onto another command.
    jcode tracks the task it starts; a backgrounded child of a foreground command is not that task, so its completion wakes nothing.

jcode wakes the session itself when a tracked background task completes.
When you are woken for the arm task:
1. Run `bin/fm-wake-drain.sh` first.
2. Optionally read the arm's reason line with the `bg` tool, `action: output` on that task id.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same background `bin/fm-watch-arm.sh` call if the home still needs supervision, as `bin/fm-supervision-lib.sh` defines it.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

`stall_wake_seconds` is the hang backstop, not the wake path.
It wakes the session after that many seconds with no output or progress and resets on activity, so a watcher cycle that dies without exiting still surfaces. Treat such a wake as `check`: drain, confirm whether a live cycle still exists, and re-arm if it does not.

jcode exposes no lifecycle hook or extension of the kind claude's Stop hook and Pi's extension are built on, so there is no turn-end guard and no extension-owned continuity here. The tracked background task IS the continuity, which is why an arm that loses its `wake: true` leaves nothing behind to notice.

Interactive TUI primary sessions are the supported supervision host.
`jcode run` is headless single-shot and exits, and a message injected through the debug socket does not render in the TUI: verified on v0.84.0, a debug-injected turn ran server-side and its background task never woke the client. Do not run the primary firstmate as a one-shot headless process or drive it through the debug socket.
