---
name: afk
description: Enter away-mode supervision. Use when the user invokes /afk (e.g. "/afk", "/afk back in an hour", "going afk"). Sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate only captain-relevant events as one batched digest, cutting supervision token cost during walk-away stretches. Exit is automatic; any real (unmarked) message returns to full per-wake responsiveness.
user-invocable: true
metadata:
  internal: true
---

# afk

Away-mode supervision. When invoked, `/afk` makes the daemon's token-saving
tradeoff **consented** and **explicit**: the captain is stepping away, so the
sub-supervisor may triage routine wakes in bash instead of waking firstmate's
LLM for each one. Escalations still reach the captain, but as one pre-read,
batched digest rather than per-wake injections.

## What it does

1. **Set the durable away-mode flag:**
   ```sh
   date '+%s' > state/.afk
   ```
   This file survives a firstmate restart: recovery re-enters afk if the
   flag is present.

2. **Ensure the sub-supervisor daemon is running.** Check the pid file; start
   the daemon only if it is dead or absent:
   ```sh
   if [ -f state/.supervise-daemon.pid ] && kill -0 "$(cat state/.supervise-daemon.pid)" 2>/dev/null; then
     : # daemon already alive - it picks up the flag on its next cycle
   else
     nohup bin/fm-supervise-daemon.sh >/dev/null 2>&1 &
   fi
   ```
   The daemon is **presence-gated**: it injects escalations only while
   `state/.afk` exists, and stays quiet otherwise.

3. **Do not separately arm `fm-watch.sh`.** The daemon manages the watcher as
   its child; the singleton lock no-ops a stray arm harmlessly.

4. **Acknowledge** to the captain that away-mode is active: the daemon will
   self-handle routine wakes, escalate only captain-relevant events, and the
   captain can exit by sending any real message.

## How to exit afk

No `/back` is needed. The first genuine message is the return signal:

- A message **without** the sentinel marker and **not** starting with `/afk`
  -> the captain is back. Clear `state/.afk`, stop the daemon, flush one
  distilled "while you were out" catch-up (drain `state/.wake-queue`, summarize
  any pending escalations from `state/.subsuper-escalations` and any
  `state/.subsuper-inject-wedged` marker), and resume full per-wake
  responsiveness (arm `bin/fm-watch-arm.sh`).
- A message **with** the sentinel marker (`FM_INJECT_MARK`, ASCII 0x1f) -> it
  is a daemon escalation; stay afk and process it.
- Re-invoking `/afk` while already away -> stay afk (refresh the flag); this
  does **not** trigger an exit.

Bias ambiguous cases toward exit: a present captain beats token savings, and
a false exit is self-correcting (the captain re-runs `/afk`).

## Orthogonal to approval authority

afk changes how aggressively firstmate surfaces things, **not who approves
what**. "Away" never means "approves more." A PR ready for merge, a
needs-decision finding, or anything destructive still waits for the captain's
explicit word - the daemon just batches the notification.

## Sentinel marker contract

The daemon prefixes every injection with `FM_INJECT_MARK` (ASCII unit
separator, 0x1f), invisible and untypable. This is how firstmate tells a
daemon escalation apart from a real message in the same pane. The marker
travels with the message text; it does not rely on harness-level
typed-vs-injected detection (which is not portable across claude, codex,
opencode, pi, and grok).

## Busy-guard and composer guard

The daemon never injects into an in-use pane. Two checks run before every
injection, dispatched through `bin/fm-backend.sh` for the supervisor's own
backend (tmux or herdr; see "Auto-discovered supervisor pane" below):

- **`pane_is_busy`** - the harness shows a busy footer (agent mid-turn) on tmux (shared with `fm-send.sh` via `bin/fm-tmux-lib.sh`); on herdr, tries the native `agent.get`-backed busy state first, trusts only `busy` outright, and corroborates every non-`busy` verdict with the same regex-over-capture reader.
- **`pane_input_pending`** - the composer holds real unsubmitted text (a
  human's half-typed line, or a previous injection whose Enter was swallowed).
  On tmux, the cursor-line detector (shared with `fm-send.sh` in
  `bin/fm-tmux-lib.sh`) first drops dim/faint ghost text, then **strips the
  harness's composer box borders**, so a ghost-only or idle *bordered* composer
  (claude draws `│ > … │`) is correctly read as empty, not pending. Without
  these filters, every idle claude pane looked like pending input and the
  daemon deferred 100% of escalations (incident afk-invx-i5).
  `FM_COMPOSER_IDLE_RE` still overrides empty-composer matching after
  dim-ghost and border stripping, and `FM_BUSY_REGEX` overrides busy footers.
  On herdr, the equivalent structural border-row classifier
  (`fm_backend_herdr_composer_state`, docs/herdr-backend.md) plays the same
  role.

Either condition defers the injection; the buffered escalation survives in
`state/.subsuper-escalations` and is retried on the next housekeeping tick. In
afk mode the composer guard is belt-and-suspenders (no human is typing), but it
protects against the race window between the captain returning and their
message landing, and against the daemon's own previous injection sitting unsent.

**Max-defer escape (the daemon must never silently wedge).**
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon
attempts one normal flush, which still requires an idle pane and empty composer.
If that submit cannot be confirmed, it raises a loud, rate-limited wedge alarm:
an ERROR in the daemon log, a durable
`state/.subsuper-inject-wedged` marker (surface it on the "while you were out"
catch-up if present), and a flash on the supervisor client's status line.
So a guard false-positive becomes a visible stall, never an unbounded silent no-op.

## Submit model

The digest is typed **once** (`send-keys -l` on tmux, `pane send-text` on
herdr - both literal, non-submitting sends), then submitted with Enter and
**verified**: Enter is retried (Enter only, never a retype) until the composer
clears.
A submit "landed" only when the composer is confirmed empty afterward, using
the same corrected, border-aware detector as the composer guard.
A bordered-empty claude composer is recognized as submitted rather than
mistaken for a swallowed Enter.
`fm-send.sh` uses the same primitive and exits non-zero
when a steer's Enter is positively swallowed, so firstmate learns an instruction
did not land instead of leaving it unsubmitted.

## Classification policy

The daemon wraps `fm-watch.sh`, runs the watcher as a child, classifies each
wake reason in bash, and self-handles the routine majority without consuming a
firstmate turn.
Only captain-relevant events escalate to firstmate's context, and even then as
one pre-read, single-line, batched digest.
The classification predicates (the captain-relevant verb set, the signal/stale
tests, and the fleet-scan) live in the shared `bin/fm-classify-lib.sh`, the same
library the always-on watcher uses for its own triage when afk is off, so the two
modes apply one identical policy. While `state/.afk` exists the daemon owns the
watcher, so the watcher reverts to one-shot and lets the daemon do the triage -
the two never run their triage at the same time.

Classify each wake this way:

- `signal` whose status content has no captain-relevant verb
  (`done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged`)
  -> self-handle. Captain-relevant verb -> escalate.
- `check` -> always escalate. Check scripts print only when firstmate should wake.
- `stale` with a terminal status -> escalate. Non-terminal stale is transient:
  record a marker and self-handle. If the pane is still idle past
  `FM_STALE_ESCALATE_SECS` (default 240s), housekeeping escalates it as a
  possible wedge. This bounds wedge-detection latency to the threshold plus a
  tick: a delay, never a loss. Healthy crewmates are autonomous and do not wait
  on firstmate mid-task.
- `heartbeat` -> self-handle. The daemon runs its own cheap bash fleet scan
  every `FM_HEARTBEAT_SCAN_SECS` (default 300s) as the catch-all for a
  captain-relevant status line the per-wake classifier might miss.
- Unknown reason, or any uncertainty -> escalate fail-safe.

Escalations are buffered up to `FM_ESCALATE_BATCH_SECS` (default 90s; 0 =
immediate) and flushed as one single-line digest prefixed with the sentinel
marker, carrying pre-read status summaries and a recommended action.
The single-line format makes the submission unambiguous across harnesses, and
the marker lets firstmate distinguish it from a real captain message.

## Injection hardening

The busy-guard, composer guard, max-defer escape, and verified type-once
submit model above are the core hardening; these round it out:

- **Single-line digest** - embedded newlines are collapsed to a literal
  separator before injection, so submission is unambiguous regardless of
  harness.
- **Marker strip** - `strip_injection_marker` removes the sentinel prefix before
  classification or relay, so the digest text firstmate sees is clean.
- **Portable singleton lock** - the daemon uses the repo's portable lock helper
  (`fm-wake-lib.sh`) instead of `flock`, which is absent on macOS.
- **Dedupe across signal/stale/scan** - `classify_signal` and `classify_stale`
  both check the seen-status marker before escalating, so a status escalated by
  one path is not re-escalated by another in the same digest.
- **Auto-discovered supervisor pane** - the daemon resolves its own BACKEND
  (tmux vs herdr) and TARGET independently, mirroring
  `bin/fm-backend.sh`'s own runtime auto-detection. Backend: `FM_SUPERVISOR_BACKEND`
  override, then `$TMUX_PANE` set (tmux), then `$HERDR_ENV=1` with
  `$HERDR_PANE_ID` present (herdr), then a tmux fallback. Target:
  `FM_SUPERVISOR_TARGET` override (a tmux target or a herdr
  `"<session>:<pane-id>"` target), then `$TMUX_PANE`, then
  `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then a
  `firstmate:0` fallback with a warning. Both resolution sources are logged at
  startup so a wrong-but-resolving fallback is detectable. Other runtime
  backends, including zellij, orca, and cmux, are not yet supported as
  supervisor backends; the daemon refuses loudly at startup instead of
  misapplying tmux primitives to a pane that isn't one
  (docs/herdr-backend.md "Away-mode daemon: herdr supervisor-pane support").

## Reliability properties

These properties must hold:

- Nothing is lost. The durable queue plus `fm-wake-drain.sh` recover any missed
  or crashed injection.
- Wedge detection is bounded-latency, not lossy.
- The catch-all scan backs up the keyword classifier.
- The daemon preserves a single-instance portable lock, crash-loop backoff,
  a pane-gone guard, and a signal-trapped shutdown that flushes buffered
  escalations before exit.

`FM_INJECT_SKIP` (default `heartbeat`) force-self-handles matching kinds,
overriding classification.
Use it sparingly.
