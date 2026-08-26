---
name: afk
description: >-
  Enter away-mode supervision when the captain invokes /afk, says they are going afk, `state/.afk` exists, an incoming message starts with `FM_INJECT_MARK`, or any `state/.subsuper-*` marker is involved.
  It sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate captain-relevant events plus bounded declared-external-wait rechecks as batched digests during walk-away stretches, then exits automatically when any real unmarked message returns firstmate to full per-wake responsiveness.
user-invocable: true
metadata:
  internal: true
---

# afk

Away-mode supervision.
`/afk` makes the daemon's token-saving tradeoff consented and explicit: the captain is stepping away, so the sub-supervisor may triage routine wakes in bash instead of waking firstmate's LLM for each one.
Escalations still reach the captain, but as one pre-read, batched digest rather than per-wake injections.

## Entering

1. **Enter through `bin/fm-afk-launch.sh`**, which owns the durable state write, session-scoped stale-artifact clearing, terminal record, and rollback.
   The flag survives a firstmate restart, so recovery re-enters afk whenever it is present.
2. **Get the daemon running as a tracked background process.** Its hosting differs by harness:
   - **Harness with a native in-pane tracked-background tool** (claude's background bash, grok's background tool): run `bin/fm-afk-launch.sh start-native`, then run `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` through that native tool.
     This is a deliberate no-separate-terminal exception, because a harness-hosted job creates no terminal or layout mutation and a shell launcher cannot invoke a harness-native background tool.
     Do not wrap it in `nohup ... &` (Codex and herdr can reap fire-and-forget shell children after a tool call returns), and roll back with `bin/fm-afk-launch.sh stop` if the native launch fails.
   - **Harness without one** (pi): run `bin/fm-afk-launch.sh start`, the single owner of the daemon terminal.
     It creates a NON-VISIBLE tracked terminal for the current backend, records its exact id, and passes the captain pane in as `FM_SUPERVISOR_TARGET` so the daemon injects into the captain rather than its own new pane.
     **Never manufacture a terminal by splitting the captain's active pane**: a split co-tenants the tab and visibly shrinks the captain's pane (`docs/herdr-backend.md` "Away-mode supervisor support").

   Both paths share `bin/fm-afk-start.sh` as the daemon entry; it exits immediately if the identity-backed lock already names a live process, otherwise it execs `bin/fm-supervise-daemon.sh` in the foreground.
   The daemon is presence-gated: it injects only while `state/.afk` exists.
3. **Do not separately arm `fm-watch.sh`.** The daemon manages the watcher as its child; the singleton lock no-ops a stray arm harmlessly.
4. **Tell the captain, in your own words**, that away mode is on and what it changes: routine updates get batched, and only decisions, failures, credentials, or review-ready work surface until he is back.
   The prescribed verbatim acknowledgement sentence was abolished on 2026-08-26 (`regeln/ABGESCHAFFT.md`, `woertliche-quittungssaetze`); say it plainly instead of reciting it.

## Exiting

No `/back` is needed - the first genuine message is the return signal:

- A message **without** the current operational prefix or a legacy bare marker, and not starting with `/afk` -> the captain is back.
  Run `bin/fm-afk-return.sh` **before** acting on the message that brought him back.
  That script owns correct-ordered daemon shutdown, durable wake presentation and post-handling acknowledgement, escalation and wedge evidence, and the return catch-up gate.
  If it reports a firstmate-actionable `blocked:` event, remediate it immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/fm-afk-return.sh check`.
  Once the daemon stops, resume full per-wake responsiveness through the emitted supervision protocol while blocker handling proceeds, so the gate never creates a blind wait.
  Do not answer a Bearings request or do any other ordinary captain work until the check exits successfully.
- A message **with** the current operational prefix (`FM_OPERATIONAL_PREFIX`: U+2063 INVISIBLE SEPARATOR followed by `FIRSTMATE_OP: `), or a legacy bare `FM_INJECT_MARK` escalation -> stay afk and process it.
- Re-invoking `/afk` while away -> stay afk and refresh the flag; this is not an exit.

Bias ambiguous cases toward exit: a present captain beats token savings, and a false exit is self-correcting because the captain simply re-runs `/afk`.

## Orthogonal to authority

afk changes how aggressively firstmate surfaces things, never who approves what.
"Away" means neither approves-more nor approves-less: landing still passes the acceptance gate and the mandate list, a finding still follows `ask-user-authority`, and anything that needs the captain still waits for his word.
The daemon only batches the notification.

## The machinery, and why each part exists

**Operational prefix.**
The daemon builds every injection as the `away-supervisor` kind owned by `bin/fm-operational-input.sh`, beginning with U+2063 plus the stable `FIRSTMATE_OP: ` label; the bare legacy marker stays accepted during rollout.
U+2063 has no normal keystroke and survives terminal transport as UTF-8, so it is how firstmate tells a daemon escalation apart from a real message in the same pane.
The prefix travels with the message text and does not rely on harness-level typed-vs-injected detection, which is not portable.

**Busy and composer guards.**
The daemon never injects into an in-use pane.
`pane_is_busy` trusts Herdr native `busy` when available and otherwise matches rendered output against only the detected primary harness's signature - never a global union of vendor patterns, and never a recorded worker task.
A busy verdict alone no longer holds an escalation, because a finished turn leaves busy-looking residue; when the composer is affirmatively `empty`, two captures across `FM_INJECT_STABLE_SECS` must also be byte-identical, since a working agent redraws and byte-equality is positive evidence no turn is running.
`inject_msg` injects only on an affirmative `empty` verdict from `fm_backend_composer_state`; every other value defers, including an unreadable pane, ambiguous geometry, a blank unidentified row, and a bare shell prompt left after the agent exits.
Each adapter contributes only capture and capability facts; `bin/fm-composer-lib.sh` owns every shape and verdict, including ghost and dark-truecolor placeholder stripping and the opencode busy-queued-Enter exception (`fm_composer_queued_enter_verdict`).
Deferred escalations survive in `state/.subsuper-escalations` and retry on the next housekeeping tick.

**Transport capacity.**
The digest is one command, and a transport that refuses an oversize command types nothing at all, so an over-budget digest is a lost delivery rather than a partial one.
`escalate_flush` fills each digest from the head of the buffer only while it still fits the backend's one-send ceiling, and a confirmed delivery drops exactly the items that went out, so a backlog drains across several digests instead of growing into one nothing can carry.

**Type-once submit model.**
The digest is typed once with a literal, non-submitting send, then submitted with Enter and verified through the backend's submit primitive; Enter is retried, Enter only and never a retype, until that primitive reports success.
On tmux that normally means a proven cleared composer, or a baseline-gated idle-to-busy transition when a working harness hides its composer; on herdr's idle-baseline path it means native agent state saw a turn start, the classifier proved the composer cleared, or the shared queued-Enter verdict proved delivery while busy.
Embedded newlines are collapsed to a literal separator first, so submission is unambiguous across harnesses, and `strip_injection_marker` removes the prefix before classification or relay.

**Max-defer escape - the daemon must never silently wedge.**
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon attempts one normal flush, still requiring an affirmatively empty composer and a pane that is not redrawing.
If that submit cannot be confirmed it raises a loud, rate-limited wedge alarm: an ERROR in the daemon log, a durable `state/.subsuper-inject-wedged` marker, a tmux status-line flash where applicable, and a configurable backend-independent alert (`docs/wedge-alarm.md`).
So a guard false-positive becomes a visible stall, never an unbounded silent no-op.

**Self-healing restart, the last resort.**
A session can be alive, idle, and still unreachable - on 2026-08-21/22 the composer read `unknown` for two hours on a live, provably idle primary and no guard could say why.
So when escalations stay undelivered past `FM_AWAY_SELFHEAL_SECS` (default 1200) AND the screen has been byte-identical for that whole window AND the composer is affirmatively `empty`, the daemon asks the agent to exit through its own exit command, verifies the stop, and types the home's configured relaunch command.
It is off unless the home configures that command, runs only in away mode, runs at most once per `FM_AWAY_SELFHEAL_COOLDOWN_SECS` (default 3600), never acts over a `pending` or `unknown` composer, and never force-kills; it replaces the session shell only (`docs/configuration.md` "Away-mode session self-healing").

**Supervisor pane resolution.**
The daemon resolves its own backend and target independently, mirroring `bin/fm-backend.sh`'s auto-detection, and logs both resolution sources at startup so a wrong-but-resolving fallback is detectable.
Backends other than tmux and herdr are not supported as supervisor backends; the daemon refuses loudly at startup rather than misapplying tmux primitives to a pane that is not one.

## Classification policy

The daemon wraps `fm-watch.sh`, runs the watcher as a child, presents every durable wake after each actionable watcher close, classifies each presented record in bash, and acknowledges the presented generation only after routing completes.
The predicates live in the shared `bin/fm-classify-lib.sh` - the same library the always-on watcher uses when afk is off - so the two modes apply one identical policy and never triage at the same time.

- `signal` with a terminal captain verb (`done:`, `needs-decision:`, `blocked:`, `failed:`) -> escalate. A nonterminal progress verb stays nonterminal even when its prose carries a legacy free-text token; only a bare legacy line with such a token escalates. Other signals -> self-handle.
- `signal` or `stale` for an external wait - a declared `paused:` line, a pane-derived pause, or a verified `captain-held` transfer -> self-handle and track the pause rather than a wedge. Past `FM_PAUSE_RESURFACE_SECS` (default 3600) housekeeping sends one recheck naming which human the wait is on, and resets the window.
- `check` -> always escalate; check scripts print only when firstmate should wake.
- `stale` with a terminal status or bare legacy captain-relevant line -> escalate. Nonterminal progress records a marker and self-handles; past `FM_STALE_ESCALATE_SECS` (default 240) housekeeping escalates it as a possible wedge, unless that crew's own validation run has advanced since the last check, which restarts the window. This bounds wedge-detection latency to a delay, never a loss.
- `heartbeat` -> self-handle; the daemon runs its own cheap bash fleet scan every `FM_HEARTBEAT_SCAN_SECS` (default 300) as the catch-all.
- Unknown reason, or any uncertainty -> escalate fail-safe.

Escalations buffer up to `FM_ESCALATE_BATCH_SECS` (default 90; 0 = immediate) and flush as one prefixed single-line digest carrying pre-read status summaries and a recommended action.
Deduplication across the signal, stale, and scan paths uses the seen-status marker, which never suppresses possible-wedge aging for a nonterminal line.
`FM_INJECT_SKIP` (default `heartbeat`) force-self-handles matching kinds, overriding classification; use it sparingly.

## Properties that must hold

- Nothing is lost after queue publication: every presented wake stays durable until routing and post-handling acknowledgement succeed, so interruption replays the same work.
- Wedge detection is bounded-latency, not lossy.
- Declared external waits are rechecked on their own bounded cadence rather than mislabeled as wedges.
- The catch-all scan backs up the keyword classifier.
- The daemon keeps a single-instance portable lock (`fm-wake-lib.sh`, not `flock`, which is absent on macOS), crash-loop backoff, a pane-gone guard, and a signal-trapped shutdown that flushes buffered escalations before exit.

Treat `state/.subsuper-escalations`, its `.since` sidecar, and `state/.subsuper-inject-wedged` as session-scoped delivery artifacts, never the durable work record: always enter through `bin/fm-afk-launch.sh` (which clears prior-session artifacts on a fresh entry and preserves the current buffer on refresh) and always exit through `bin/fm-afk-launch.sh stop` (which keeps `state/.afk` present through the shutdown flush and clears it last).
