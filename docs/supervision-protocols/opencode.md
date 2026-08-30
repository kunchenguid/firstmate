Mode: OpenCode TUI plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: let `.opencode/plugins/fm-primary-watch-arm.js` arm supervision after the OpenCode session goes idle.
3. The plugin listens for `session.idle`, spawns `bin/fm-watch-arm.sh --restart` without awaiting it in the idle handler, and owns every later successor launch.
4. After an actionable child close, the plugin rechecks session-lock ownership and verifies one singleton successor before it calls `client.session.promptAsync`; its bounded fallback is defined in `docs/watcher-continuity.md`.
5. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
6. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
7. Failure or missing cycle only: if the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
8. Every wake-delivery prompt - watcher wake, turn-end-guard follow-up, and the session-start nudge - goes through `.opencode/plugins/lib/fm-wake-delivery.js`: a small bounded retry with a per-attempt accept timeout, then a loud declaration through `bin/fm-wake-delivery-alarm.sh` (durable `state/.wake-delivery-failures` record plus the wedge-alarm notification channels).
   The nudge delivery doubles as the running-build self-check, so a stale OpenCode TUI whose client API drifted is caught at session open, and the next session start surfaces the `WAKE_DELIVERY` bootstrap diagnostic.
   On that diagnostic, restart the stale OpenCode TUI, then rerun `bin/fm-session-start.sh`; `.agents/skills/bootstrap-diagnostics/SKILL.md` owns the response.
9. Never use shell `&` for watcher supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/fm-primary-pretool-check.js`, `bin/fm-arm-pretool-check.sh`).
10. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.

OpenCode's persistent TUI plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and a secondmate's own home, and stays silent only in child crewmate and scout worktrees.
