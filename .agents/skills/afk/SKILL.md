---
name: afk
description: Enter away-mode supervision. Use when the user invokes /afk (e.g. "/afk", "/afk back in an hour", "going afk"). Sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate captain-relevant events plus bounded declared-external-wait rechecks as batched digests, cutting supervision token cost during walk-away stretches. Exit is automatic; any real (unmarked) message returns to full per-wake responsiveness.
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

2. **Ensure the sub-supervisor daemon is running.** Start the helper as its own
   tracked background terminal/session:
   ```sh
   bin/fm-afk-start.sh
   ```
   The helper sets or refreshes `state/.afk`, exits immediately if the identity-backed daemon lock already names a live process, and otherwise execs `bin/fm-supervise-daemon.sh` in the foreground.
   Do not wrap this in `nohup ... &`.
   Codex/herdr can reap fire-and-forget shell children after a tool call
   returns; a tracked background terminal/session keeps the daemon attached to
   the harness lifecycle and survived the real incident reproduction.
   The daemon is **presence-gated**: it injects escalations only while
   `state/.afk` exists, and stays quiet otherwise.

3. **Do not separately arm `fm-watch.sh`.** The daemon manages the watcher as
   its child; the singleton lock no-ops a stray arm harmlessly.

4. **Acknowledge** to the captain that away-mode is active.
   The daemon will self-handle routine wakes, escalate captain-relevant events and bounded declared-external-wait rechecks, and let the captain exit by sending any real message.

## How to exit afk

No `/back` is needed. The first genuine message is the return signal:

- A message **without** the sentinel marker and **not** starting with `/afk` -> the captain is back.
  Clear `state/.afk`, stop the daemon, flush one distilled "while you were out" catch-up (drain `state/.wake-queue`, summarize any pending escalations from `state/.subsuper-escalations` and any `state/.subsuper-inject-wedged` marker), and resume full per-wake responsiveness through the emitted primary-harness supervision protocol from session start.
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
- **Composer-state guard** - `inject_msg` reads the full `empty`/`pending`/`unknown` verdict from `fm_backend_composer_state` and injects only when it is affirmatively `empty`.
  `pending` means real unsubmitted text, while `unknown` includes an unreadable pane and a bare shell prompt left after the agent exits, so both defer.
  The shared `bin/fm-composer-lib.sh` owns the content decision after each backend captures and structurally identifies its own composer row.
  It preserves idle bordered composers such as claude's `│ > … │` and bare agent glyphs as empty, but a bare shell glyph is unknown unless inside a genuine bordered composer box; see `docs/herdr-backend.md` "Composer-emptiness safety" for the complete contract.
  `pane_input_pending` remains the tested predicate for callers that only need to know whether real unsubmitted text is present, but it is insufficient for an injection-safety decision because it cannot distinguish `empty` from `unknown`.

Either condition, or any composer verdict other than `empty`, defers the injection; the buffered escalation survives in `state/.subsuper-escalations` and is retried on the next housekeeping tick.
In afk mode the composer guard is belt-and-suspenders (no human is typing), but it protects against the race window between the captain returning and their message landing, a dead shell, and the daemon's own previous injection sitting unsent.

**Max-defer escape (the daemon must never silently wedge).**
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon
attempts one normal flush, which still requires an idle pane and an affirmatively empty composer.
If that submit cannot be confirmed, it raises a loud, rate-limited wedge alarm:
an ERROR in the daemon log, a durable
`state/.subsuper-inject-wedged` marker (surface it on the "while you were out"
catch-up if present), and a flash on the supervisor client's status line.
So a guard false-positive becomes a visible stall, never an unbounded silent no-op.

## Submit model

The digest is typed **once** (`send-keys -l` on tmux, `pane send-text` on
herdr - both literal, non-submitting sends), then submitted with Enter and
**verified** through the selected backend's submit primitive.
Enter is retried (Enter only, never a retype) until the backend confirms the
submit landed.
For tmux that confirmation is a cleared composer, using the same corrected,
border-aware detector as the composer guard.
For herdr, normal idle-baseline submits are confirmed by native agent-state showing a real turn started; the ANSI-aware composer classifier remains the affirmative-empty pre-injection guard and conservative fallback for non-idle or unreadable baselines.
A bordered-empty or ghost-only composer is recognized as empty where that backend uses composer confirmation, rather than mistaken for a swallowed Enter.
`fm-send.sh` uses the same primitive and exits non-zero
when a steer's Enter is positively swallowed, so firstmate learns an instruction
did not land instead of leaving it unsubmitted.

## Classification policy

The daemon wraps `fm-watch.sh`, runs the watcher as a child, classifies each
wake reason in bash, and self-handles the routine majority without consuming a
firstmate turn.
Captain-relevant events, plus a bounded recheck of a declared external wait that remains idle, escalate to firstmate's context as one pre-read, single-line, batched digest.
The classification predicates (the captain-relevant verb set, declared-pause vocabulary, signal/stale tests, and fleet-scan) live in the shared `bin/fm-classify-lib.sh`, the same library the always-on watcher uses for its own triage when afk is off, so the two modes apply one identical policy.
While `state/.afk` exists the daemon owns the watcher, so the watcher reverts to one-shot and lets the daemon do the triage - the two never run their triage at the same time.

Classify each wake this way:

- `signal` whose status content has no captain-relevant verb
  (`done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged`)
  -> self-handle. Captain-relevant verb -> escalate.
- `signal` or `stale` for a declared `paused:` external wait -> self-handle and track the pause rather than a wedge.
  If it remains declared and idle past `FM_PAUSE_RESURFACE_SECS` (default 3600s), housekeeping sends one awaiting-external recheck and resets the pause window.
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

- **Single-line digest** - embedded newlines are collapsed to a literal
  separator before injection, so submission is unambiguous regardless of
  harness.
- **Composer guard on the supervisor pane** - before injecting, the daemon checks `pane_is_busy` (harness busy footer means agent mid-turn) and reads `fm_backend_composer_state` directly.
  Only `empty` permits injection; `pending` protects half-typed or swallowed input, and `unknown` protects unreadable panes and bare dead-shell prompts.
  Every other result preserves the buffer for retry, so the daemon never merges its digest into the captain's half-typed line or types it into a shell.
- The shared composer classifier receives a candidate row only after the active backend performs its own capture and structural row recognition.
  tmux removes dim/faint ghost text and borders before delegation, while herdr retains its ANSI faint-tail override after the shared verdict.
  A ghost-only or idle bordered composer such as claude's `│ > ... │` therefore reads empty without allowing an unbordered shell prompt to do the same.
  `FM_COMPOSER_IDLE_RE` still overrides tmux empty-composer matching after dim-ghost and border stripping, and `FM_BUSY_REGEX` overrides busy footers.
- **Max-defer escape** - the daemon must never silently wedge. If anything stays
  buffered past `FM_MAX_DEFER_SECS` (default 300s), the daemon attempts one
  normal flush, which still requires an idle pane and an affirmatively empty composer. If that
  cannot confirm a submit, it raises a loud, rate-limited wedge alarm: ERROR log,
  durable `state/.subsuper-inject-wedged` marker, and a status-line flash. A
  composer false-positive surfaces as a visible stall, never an unbounded silent
  no-op.
- **Verified type-once submit model** - the digest is typed once (`send-keys -l`
  on tmux, `pane send-text` on herdr), then submitted with Enter and verified.
  Enter is retried, Enter only and never a retype, until the backend submit
  primitive reports `empty` as its caller-facing success verdict.
  For tmux that verdict means the dim-ghost-aware and border-aware composer
  cleared.
  For herdr's normal idle-baseline path it means native agent-state observed a real turn start; herdr uses the ANSI-aware structural classifier for the pre-injection composer guard and fallback paths.
  This lets ghost-only or bordered-empty composers count as empty where a composer read is the active confirmation signal.
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
- Declared external waits are rechecked on a separate, bounded cadence rather than being mislabeled as wedges.
- The catch-all scan backs up the keyword classifier.
- The daemon preserves a single-instance portable lock, crash-loop backoff,
  a pane-gone guard, and a signal-trapped shutdown that flushes buffered
  escalations before exit.

`FM_INJECT_SKIP` (default `heartbeat`) force-self-handles matching kinds,
overriding classification.
Use it sparingly.
