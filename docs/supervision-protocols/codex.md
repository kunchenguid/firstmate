Mode: Codex durable-wake supervision (`codex queue` doorbell first, marked terminal injection second, bounded foreground checkpoint last).

Codex does not start a turn when an asynchronous `Stop` hook finishes.
The present-mode daemon therefore owns the watcher and uses `codex queue` to ring the exact bound primary thread when an actionable wake is already durable.
The queued message is a fixed `FIRSTMATE_OP` drain instruction and never carries the wake payload.
`state/.wake-queue` remains the authority, and queue acceptance means only that Codex accepted a doorbell.
Before native submission, Firstmate resolves the exact UUID-bound append-only TUI transcript and requires unchanged terminal lifecycle evidence across a bounded post-completion quiet window.
Codex exposes no persisted presentation acknowledgement, so this boundary allows its asynchronous message consolidation and scrollback reflow to settle without claiming that rendered output is observable.
An active, changing, missing, ambiguous, or timed-out transcript defers native submission while the durable wake remains authoritative.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
   Handle every emitted wake, reconcile open decisions and unread status, and then run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
   Until that acknowledgement succeeds, wake rows and their recovery generation remain durable for idempotent re-handling.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Ensure the present-mode daemon is running with `bin/fm-present-launch.sh start`.
   It is idempotent, reconciles a leaked terminal before relaunching, and may use a detached tmux session only to host the watcher when the Codex primary itself is on an independent pty.
4. On a `FIRSTMATE_OP: v1 watcher:` message or a marked terminal fallback (`FM_INJECT_MARK` prefix), drain and handle the durable queue, run its acknowledgement, and re-run `bin/fm-present-launch.sh start` before ending the turn.
   Then give the captain a project-facing outcome, re-anchor to the preceding captain conversation, and resume or explicitly close any captain goal that remained active before the operational message; do not end on internal Watcher mechanics alone.
5. Never use shell `&`, Codex background tasks, or `bin/fm-watch-arm.sh` for routine Codex supervision.
   The daemon owns its separate terminal, and the PreToolUse seatbelt in `.codex/hooks.json` denies backgrounded, piped, or bundled arm commands.

The daemon validates an authoritative private primary-thread binding captured by `bin/fm-session-start.sh` from the Codex `SessionStart` payload when that hook fires, cross-checked against the `CODEX_THREAD_ID` that Codex injects into its own shell-tool environment.
That binding is accepted only while its home, session-lock generation, owner PID, and process identity still match.
Running the required bootstrap in a resumed or restarted primary replaces the binding; re-running it after compaction preserves the same native UUID.
The interactive TUI does not fire the tracked project `SessionStart` hook on verified 0.150.1, so its required bootstrap binds directly from that same native shell identity instead of inferring a session from transcripts or titles.
An in-process compaction leaves the validated process and native thread identity unchanged, but it does not provide an instruction-refresh channel.
Firstmate never chooses a thread from transcript recency, session title, or the general session list.

For one bound session and recovery generation, accepted, timed-out, or interrupted native submissions suppress another native submission through the highest wake sequence that doorbell covered.
This coalesces a burst behind one generic drain turn and makes ambiguous acceptance harmless.
Only the drain acknowledgement consumes wake rows, and it retires only a matching delivery record whose wake-sequence high-water mark is at or below the handled cutoff.
If a newer row survives the acknowledgement without a newer doorbell already covering it, the same queue-first delivery path immediately rings one successor doorbell, with the unchanged terminal and checkpoint fallbacks.
Duplicate turns can therefore observe an empty eligible queue but cannot duplicate a captain report, while a row arriving during handling cannot be stranded behind the acknowledgement for an earlier row.

Fallback order is exact:

1. Invoke bounded `codex queue --thread <validated UUID> --message <fixed drain prompt>` only after the exact thread's append-only lifecycle remains terminal and unchanged through the post-completion quiet window and when the installed command exposes `queue --thread` and `--message`.
2. On a missing or stale binding, unsupported command, timeout, rejection, or ambiguous submission, retain every wake and try the existing marked tmux/herdr injection.
   Its composer and target-ownership guards are unchanged: only an affirmatively empty composer receives the marked message.
3. If no safe injectable pane exists, retain every wake for `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.

`bin/fm-present-launch.sh start` returns exit code 3 when neither an injectable tmux/herdr target nor a detached host with both native queue capability and a currently validated binding is available.
Report that as durable notifications available but automatic Codex delivery unavailable, then use the bounded checkpoint.
If a checkpoint prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain and handle the queue before starting the next checkpoint.
If it prints `checkpoint:` or exits 124 without a wake, drain anyway, process any queued user message visible to Codex, and start the next checkpoint.
That clean timeout is an orderly watcher handoff and must not itself produce `check: rearm-resurface`; genuine watcher death remains recoverable from the durable queue and stale-lock evidence.

The synchronous `Stop` guard remains a boundary backstop.
`stop_hook_active=true` prevents a queue-triggered turn from recursively forcing another continuation.
Do not describe Codex's asynchronous `Stop` hook as Claude-style rewake: the native `codex queue` ingress is the enabling primitive.

Do not run the present daemon and a foreground checkpoint together because the watcher singleton permits only one live watcher.
Do not run `bin/fm-watch.sh` directly.
