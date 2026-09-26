Mode: Hermes firstmate plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the Firstmate Hermes plugin is loaded: this block and the startup digest arriving as injected context, with no manual session-start command, is that proof.
   If `bin/fm-session-start.sh` reported the Hermes plugin as not loaded, run `bin/fm-hermes-plugin.sh status`, have the captain run `bin/fm-hermes-plugin.sh install` when it is not `ok`, and restart Hermes inside this home.
3. The plugin starts the watcher itself as soon as its startup digest holds the session lock, and re-arms every later cycle itself; no model call is needed.
   Call the `fm_watch_arm_hermes` tool only for a first cycle the plugin reports it could not start, and use `/fm-watch-arm-hermes` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` or `bin/fm-watch.sh` through the terminal tool, in the foreground or with `background=true`: that creates a second owner outside the plugin's successor and cleanup contract.
4. If the plugin says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_hermes`.
5. The plugin runs `bin/fm-watch-arm.sh --restart` as a child of this Hermes process and owns every successor launch; `/new` keeps the same home-scoped watcher.
6. After an actionable child close, the plugin rechecks session-lock ownership and verifies one successor before it delivers the wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
   A wake arrives as a `watcher` operational turn, injected only while this session is idle so it never interrupts a turn in progress.
   A wake still undelivered when Hermes exits is persisted and replayed by the next owning Hermes process.
7. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_hermes` again because continuity is plugin-owned rather than model-memory-owned.
8. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
9. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_hermes`, and restart Hermes inside this home if the plugin is not loaded.
   A redundant call while the plugin owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
10. Waiting is silent: end the turn once the fleet is handled; the plugin wakes you.
11. Never use shell `&` for watcher supervision.
    A manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the pre-tool seatbelt (`bin/fm-arm-pretool-check.sh`), which the plugin applies to every terminal command.

The turn-end guard is plugin-owned too.
Hermes has no hook that can veto an ordinary turn end, so at every turn end the plugin first lets the watcher owner re-arm, then asks `bin/fm-turnend-guard.sh`, and when supervision is still off it schedules exactly one `turn-end-guard` follow-up turn; follow that recovery instruction before ending the turn again.
On a turn that edited files, Hermes's `pre_verify` hook instead keeps the same turn going with the guard text.
An interrupted turn is not guarded; `bin/fm-control.sh` owns that postcondition.

While `state/.afk` exists on a home without `config/supervision-host`, the away-mode daemon owns supervision and the plugin stands its own watcher down until the flag clears.

The plugin implementation lives at `__FM_HERMES_PLUGIN__`; `.hermes/plugins/firstmate/` holds the loader Hermes discovers, and `bin/fm-hermes-plugin.sh` owns its install.
The supported primary surface is an interactive Hermes session, classic CLI (`hermes --cli`) or Ink TUI; a one-shot `hermes -z` or `chat -q --oneshot` exits before any wake can be delivered.
