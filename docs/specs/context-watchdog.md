# firstmate context watchdog — spec

Make "the firstmate session stays under 200k tokens and never enters the dumb
zone" machine-true, and give secondmate/crewmate sessions a ~50%-of-window
restart. Built as a daemon sibling of `fm-supervise-daemon.sh`, reusing its
plumbing (busy-guard via `fm-tmux-lib.sh`, portable mkdir lock via
`fm-wake-lib.sh`, `state/` sentinel files).

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
