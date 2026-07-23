Mode: Codex durable-wake supervision (present-mode daemon primary, foreground checkpoint backstop).

Codex cannot reason while a foreground tool call is running and has no background-task completion wake, so a bare watcher exit cannot start a fresh turn by itself.
The present-mode supervision daemon closes that gap: it runs in a separate non-visible terminal, owns the watcher, and injects a marked supervision nudge into this pane on each actionable wake, starting the turn that drains the queue.
This is the durable wake path; the bounded foreground checkpoint remains only as the degraded backstop.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Ensure the present-mode daemon is running with `bin/fm-present-launch.sh start`.
   It is idempotent: it no-ops when the daemon is already live and reconciles a leaked terminal from a prior crash before relaunching.
   The daemon is now this session's live supervision cycle - it owns the watcher and touches the same beacon the turn-end guard checks, so the turn may end without a blocking foreground checkpoint.
4. When a marked supervision nudge arrives, or any wake, drain queued wakes with `bin/fm-wake-drain.sh`, handle the wake per this protocol, then re-run `bin/fm-present-launch.sh start` to confirm the daemon is still live before ending the turn.
5. Never use shell `&` or Codex background tasks for firstmate watcher supervision; the daemon owns its own separate terminal.

A marked supervision nudge (`FM_INJECT_MARK` prefix) while away mode is inactive is the present daemon waking this pane.
It is not an away-mode escalation and does not load `/afk`; just drain and handle it per this protocol.

Degraded backstop (honest, not silent):
When `bin/fm-present-launch.sh start` fails - the supervisor backend is neither herdr nor tmux, or the daemon will not launch - report the degraded state plainly and fall back to the bounded foreground checkpoint:
1. Run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
2. If it prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
3. If it prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.

Do not run both the present daemon and a foreground checkpoint at once: the watcher singleton lock lets only one live watcher exist, so the second one no-ops.
Do not run `bin/fm-watch.sh` directly and do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
If either is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
