---
name: afk
description: Enter away-mode supervision. Use when the user invokes /afk (e.g. "/afk", "/afk back in an hour", "going afk"). Sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate only captain-relevant events as one batched digest, cutting supervision token cost during walk-away stretches. Exit is automatic; any real (unmarked) message returns to full per-wake responsiveness.
user-invocable: true
---

# afk

Away-mode supervision. When invoked, `/afk` makes the daemon's token-saving
tradeoff **consented** and **explicit**: the captain is stepping away, so the
sub-supervisor may triage routine wakes in bash instead of waking firstmate's
LLM for each one. Escalations still reach the captain — but as one pre-read,
batched digest rather than per-wake injections.

## What it does

1. **Set the durable away-mode flag:**
   ```sh
   date '+%s' > state/.afk
   ```
   This file survives a firstmate restart: recovery (§5) re-enters afk if the
   flag is present.

2. **Ensure the sub-supervisor daemon is running.** Check the pid file; start
   the daemon only if it is dead or absent:
   ```sh
   if [ -f state/.supervise-daemon.pid ] && kill -0 "$(cat state/.supervise-daemon.pid)" 2>/dev/null; then
     : # daemon already alive — it picks up the flag on its next cycle
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
  → the captain is back. Clear `state/.afk`, stop the daemon, flush one
  distilled "while you were out" catch-up (drain `state/.wake-queue`, summarize
  any pending escalations from `state/.subsuper-escalations`), and resume full
  per-wake responsiveness (arm `bin/fm-watch.sh`).
- A message **with** the sentinel marker (`FM_INJECT_MARK`, ASCII 0x1f) → it
  is a daemon escalation; stay afk and process it.
- Re-invoking `/afk` while already away → stay afk (refresh the flag); this
  does **not** trigger an exit.

Bias ambiguous cases toward exit: a present captain beats token savings, and
a false exit is self-correcting (the captain re-runs `/afk`).

## Orthogonal to approval authority

afk changes how aggressively firstmate surfaces things, **not who approves
what**. "Away" never means "approves more." A PR ready for merge, a
needs-decision finding, or anything destructive still waits for the captain's
explicit word — the daemon just batches the notification.

## Sentinel marker contract

The daemon prefixes every injection with `FM_INJECT_MARK` (ASCII unit
separator, 0x1f) — invisible and untypable. This is how firstmate tells a
daemon escalation apart from a real message in the same pane. The marker
travels with the message text; it does not rely on harness-level
typed-vs-injected detection (which is not portable across claude, codex,
opencode, and pi).

## Busy-guard and composer guard

The daemon never injects into an in-use pane. Two checks run before every
injection:

- **`pane_is_busy`** — the harness shows a busy footer (agent mid-turn).
- **`pane_input_pending`** — the cursor line has non-empty content (a human's
  half-typed line, or a previous injection whose Enter was swallowed).

Either condition defers the injection; the buffered escalation survives in
`state/.subsuper-escalations` and is retried on the next housekeeping tick. In
afk mode the composer guard is belt-and-suspenders (no human is typing), but it
protects against the race window between the captain returning and their
message landing, and against the daemon's own previous injection sitting unsent.

## Submit model

The daemon types the digest **once** via `send-keys -l`, then submits with
Enter. If the composer still has text after Enter (swallowed Enter), it retries
**Enter only** (never retypes the digest), preventing concatenation of two
sentinel-prefixed digests into one corrupted turn.
