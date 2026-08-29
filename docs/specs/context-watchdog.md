# firstmate context watchdog — spec

Make "the firstmate session stays under 200k tokens and never enters the dumb
zone" machine-true, and give secondmate/crewmate sessions a ~50%-of-window
restart. Built as a daemon sibling of `fm-supervise-daemon.sh`, reusing its
plumbing (busy-guard via `fm-tmux-lib.sh`, portable mkdir lock via
`fm-wake-lib.sh`, `state/` sentinel files).

> **Status note (herdr cutover, 2026-08-28).** This spec still describes a tmux-only
> watchdog, and that is what is implemented. `fm-ctx-statusline.sh` can only stamp
> `managed:true` for a pane in firstmate's tmux session, and `fm-context-watch.sh`
> re-confirms the target through tmux at fire time, so no crewmate spawned into a herdr
> pane is ever selected for a checkpoint - it simply hits its context ceiling with no
> handoff written. Until the watchdog is re-sourced onto `bin/fm-herdr.sh`, context on a
> long-running crewmate is watched by hand (AGENTS.md, "herdr workspace hygiene").

## Components

1. **MEASURE** — `bin/fm-ctx-statusline.sh` (a Claude Code statusLine) reads the
   per-render stdin JSON and writes `state/ctx-<window>.json`:
   `{window, tmux_target, role, total_tokens, used_pct, exceeds_200k, ts}`.
   `total_tokens = current_usage.input_tokens + cache_creation_input_tokens +
   cache_read_input_tokens`. `current_usage == null` (right after `/compact`)
   writes `total_tokens: 0` — the numeric threshold never fires on an unknown
   size (fail-safe). Belt-and-suspenders: `bin/fm-ctx-stop-hook.sh` (a Stop hook)
   parses the transcript's last-assistant `usage` and writes the same sentinel,
   for panes without a statusLine.

2. **WATCH+FIRE** — `bin/fm-context-watch.sh`, a presence/busy-gated daemon, polls
   `state/ctx-*.json`. Thresholds (`fm-ctx-lib.sh`): CAPTAIN fires at
   `total_tokens >= 185000` (a margin UNDER the 200k floor — fire before, never
   at, 200k); CREW/SECONDMATE fire at `used_pct >= 50`. On threshold AND
   pane-not-busy: fm-send a checkpoint instruction → poll for the handoff file
   (bounded) → `tmux send-keys '/clear'`. Never fires on a busy pane (reuses
   `fm_pane_is_busy`). A cooldown marker stops a just-restarted pane re-firing on
   its stale sentinel.

3. **HANDOFF** — the target session writes `state/handoff-<window>.md` in the
   context-discipline leave-off format (Goal / Done-green / Frontier /
   Open-decisions / Pointers; references, not contents), well under the 10k cap.

4. **REHYDRATE** — `bin/fm-captain-bootstrap.sh` (a SessionStart hook), if a
   handoff for this pane's window exists, injects it as
   `hookSpecificOutput.additionalContext` (or a pointer if > 10k chars), then
   archives it. Without a handoff, behavior is unchanged.

## On-demand compaction (secondmate-invokable)

`bin/fm-compact-crewmate.sh <id> [--resume frontier|restart]` runs the SAME
fire-once cycle on demand against one crewmate, instead of waiting for the poll.
It sources `fm-context-watch.sh` and calls the daemon's `fm_ctx_fire_once`
(`fm_ctx_fire_once` is defined once; the command never forks it), resolves the
target via `fm_ctx_target_for`, guards an in-flight compact with a per-id mkdir
lock, and honors the existing cooldown (idempotent). `--resume frontier`
(default) resumes the leave-off Frontier; `--resume restart` writes a
`state/resume-<key>.directive` sentinel that the REHYDRATE path reads to instead
tell the crewmate to restart the task from the compacted brief — making the reset
deterministic. The bootstrap consumes the directive after one boot.

## Per-secondmate scoped watch

`fm-context-watch.sh --scope/--home <home>` re-points `FM_HOME`, so
`_ctx_state_root` (`${FM_STATE_OVERRIDE:-$FM_HOME/state}`) — and therefore the
poll set, cooldown markers, and the singleton lock — are all scoped to that one
home. No scope keeps the global daemon behavior unchanged. `fm-spawn.sh`
auto-starts such a scoped watch on every `kind=secondmate` launch as a
presence-gated background child that self-singletons on the home's lock (a
duplicate spawn or recovery respawn no-ops). It is idle-safe: it only watches its
own home's crewmates and fires the compact cycle for them. Opt out with
`FM_SECONDMATE_NO_WATCH=1`; the start is overridable via `FM_CTX_WATCH_START_CMD`
for tests.

For the scoped watch to actually SEE its crewmates, their sentinels must land in
its home's state dir. So `fm-spawn.sh` pins every launched session's `FM_HOME` to
the SPAWNING home: a secondmate's crew/scout sessions inherit the secondmate home
(their sentinels route there), while the main firstmate's crew keep landing in the
main state dir. Role is unaffected — `fm_ctx_role` is cwd-based and a crewmate's
cwd is its worktree, never the home, so it stays `role=crew`.

## Fresh-handoff guard

`fm_ctx_fire_once` baselines the existing `handoff-<key>.md` mtime before sending
the checkpoint and only accepts a handoff written AFTER it. A STALE handoff from a
prior cycle (e.g. one the rehydrate never archived) therefore never short-circuits
the wait loop into an immediate `/clear` that would wipe the crewmate's current
turn and rehydrate from the old doc. Only a fresh, post-checkpoint handoff
recycles the session. This protects both the daemon and `fm-compact-crewmate`.

## The window key

`<window>` is the sanitized tmux `session:window_name` (`fm_ctx_window_key`),
which persists across `/clear` — so the statusLine (pre-clear) and the bootstrap
(post-clear) compute the same key for the same pane and the handoff round-trips.
Role is captain iff cwd is `$HOME` or the firstmate home (same heuristic the
bootstrap already used), else crew.

## Gates

- **G1** threshold selection (captain>=185k, crew>=50%, sub-threshold excluded)
- **G2** busy-guard holds (over-threshold + busy pane does not fire)
- **G3** rehydrate injects+archives; no-handoff path unchanged (no regression)
- **G4** e2e on a disposable scratch pane: checkpoint → handoff → /clear → rehydrate
- **G5** inject path respects the 10k cap (pointer fallback when large)
- **G6** on-demand compact (`fm-compact-crewmate`) runs the shared fire-once
  cycle on a scratch pane, reuses the daemon's `fm_ctx_fire_once` (no
  duplication), and is idempotent under cooldown
- **G7** `--resume frontier` vs `--resume restart` inject different, mode-correct
  rehydrate directives; the directive is consumed once
- **G8** a per-secondmate scoped watch acts only on its own home's crewmates
  while a global watch still sees all (no regression); `fm-spawn` auto-starts the
  scoped watch on secondmate boot
- **G9** a STALE pre-existing handoff does NOT trigger `/clear`; only a fresh
  post-checkpoint handoff recycles the session
- crew launch routes its sentinel to the spawning home (so a secondmate's scoped
  watch sees its crewmates), asserted in the secondmate behavior suite
