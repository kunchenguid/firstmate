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

Away-mode supervision. When invoked, `/afk` makes the daemon's token-saving
tradeoff **consented** and **explicit**: the captain is stepping away, so the
sub-supervisor may triage routine wakes in bash instead of waking firstmate's
LLM for each one. Escalations still reach the captain, but as one pre-read,
batched digest rather than per-wake injections.

## What it does

1. **Enter the lifecycle through `bin/fm-afk-launch.sh`.**
   This owns the durable state write, session-scoped stale-artifact clearing,
   terminal record, and rollback.
   The flag survives a firstmate restart, so recovery re-enters afk when it is present.

2. **Ensure the sub-supervisor daemon is running as a tracked background process.**
   Its hosting differs by harness.
   Pick the right path:
   - **Harness WITH a native in-pane tracked-background tool** (e.g. claude's
     background bash, grok's background tool): first run
     `bin/fm-afk-launch.sh start-native`, then run
     `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` through that native tool.
     This is a deliberate no-separate-terminal exception because the harness-hosted job creates no terminal or layout mutation, and a shell launcher cannot invoke a harness-native background tool.
     The launcher still owns lifecycle state and records the no-terminal mode, while the daemon inherits and auto-discovers the captain pane.
     If the native launch fails, run `bin/fm-afk-launch.sh stop` to roll back the prepared lifecycle.
     Do not wrap it in `nohup ... &` (Codex/herdr can reap fire-and-forget shell children after a tool call returns).
   - **Harness WITHOUT one** (e.g. pi): run `bin/fm-afk-launch.sh start`. It is
     the single owner of the daemon terminal: it creates a NON-VISIBLE tracked
     terminal for the current backend (a herdr dedicated `--no-focus` workspace,
     a detached tmux session), records its exact id, and passes the captain pane
     in as `FM_SUPERVISOR_TARGET` so the daemon injects into the captain, not its
     own new pane. **Never manufacture a terminal by splitting the captain's
     active pane** (`herdr pane split`): a split co-tenants the tab and visibly
     shrinks the captain's pane (docs/herdr-backend.md "Away-mode daemon terminal
     launch").
   Both paths share `bin/fm-afk-start.sh` as the daemon entry.
   The native path tells it that the launcher already prepared lifecycle state; the terminal-backed path lets the entry perform its existing state setup inside the new terminal.
   It exits immediately if the identity-backed daemon lock already names a live process, otherwise it execs `bin/fm-supervise-daemon.sh` in the foreground.
   The daemon is **presence-gated**: it injects escalations only while
   `state/.afk` exists, and stays quiet otherwise.

3. **Do not separately arm `fm-watch.sh`.** The daemon manages the watcher as
   its child; the singleton lock no-ops a stray arm harmlessly.

4. **Acknowledge** in `AGENTS.md` section 9 language: "Captain, away mode is active; I will batch routine updates and surface only decisions, failures, credentials, or review-ready work until you return."

## How to exit afk

No `/back` is needed. The first genuine message is the return signal:

- A message **without** the sentinel marker and **not** starting with `/afk` -> the captain is back.
  Run `bin/fm-afk-return.sh` before acting on the message that brought the captain back.
  That script owns correct-ordered daemon shutdown, durable wake draining, escalation and wedge evidence, and the return-catch-up gate.
  If it reports a firstmate-actionable `blocked:` event, remediate it immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/fm-afk-return.sh check`.
  Once the daemon stops, resume full per-wake responsiveness through the emitted primary-harness supervision protocol while blocker handling proceeds, so the gate never creates a blind wait.
  Do not answer a Bearings request or perform any other ordinary captain work until the check exits successfully.
- A message **with** the sentinel marker (`FM_INJECT_MARK`, U+2063 INVISIBLE SEPARATOR) -> it is a daemon escalation; stay afk and process it.
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

The daemon prefixes every injection with `FM_INJECT_MARK` (U+2063 INVISIBLE SEPARATOR), which has no normal keyboard keystroke and survives terminal transport as UTF-8 text.
This is how firstmate tells a daemon escalation apart from a real message in the same pane.
The marker travels with the message text; it does not rely on harness-level typed-vs-injected detection, which is not portable across claude, codex, opencode, pi, and grok.

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
The alarm is defense in depth rather than a substitute for keeping every genuinely idle supported composer injectable.
If that submit cannot be confirmed, it raises a loud, rate-limited wedge alarm:
an ERROR in the daemon log, a durable
`state/.subsuper-inject-wedged` marker (surface it on the "while you were out"
catch-up if present), a tmux status-line flash when applicable, and a configurable backend-independent active alert.
`docs/wedge-alarm.md` owns the alert channel setup and verification record.
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

**Busy-queued Enter exception (tmux backend, opencode 1.18.4).** While opencode
is mid-turn, Enter is accepted and queued for after the current turn but the
composer keeps showing the typed text the whole time, so the cleared-composer
check alone false-positives on a swallowed Enter for every steer sent to a
busy opencode pane. The shared `fm_tmux_submit_enter_core` falls back to
`fm_pane_is_busy` once the Enter-retry budget is spent: a busy pane means the
Enter was accepted and queued (reported as `empty` so the caller does not
re-send), while an idle pane keeps `pending` as a genuine swallow. The
strict-buffer-clears-only-on-`empty` policy above still holds for the daemon
and the lenient-`pending`-fails-for-`fm-send` policy still holds for steer
verification - this exception is a busy-queue is treated as a delivered
Enter, not a swallowed one. The herdr adapter observes the same opencode
behavior but needs a separate fix; the gap is recorded in
`docs/herdr-backend.md` rather than papered over here.

## Classification policy

The daemon wraps `fm-watch.sh`, runs the watcher as a child, classifies each
wake reason in bash, and self-handles the routine majority without consuming a
firstmate turn.
Captain-relevant events, plus a bounded recheck of a declared external wait that remains idle, escalate to firstmate's context as one pre-read, single-line, batched digest.
The classification predicates (the captain-relevant verb set, declared-pause vocabulary, signal/stale tests, and fleet-scan) live in the shared `bin/fm-classify-lib.sh`, the same library the always-on watcher uses for its own triage when afk is off, so the two modes apply one identical policy.
While `state/.afk` exists the daemon owns the watcher, so the watcher reverts to one-shot and lets the daemon do the triage - the two never run their triage at the same time.

Classify each wake this way:

- `signal` with a terminal captain verb (`done:`, `needs-decision:`, `blocked:`, or `failed:`) -> escalate.
  A nonterminal progress verb remains nonterminal even when its prose contains a legacy free-text token such as `PR ready`, `checks green`, `ready in branch`, or `merged`; only a bare legacy line with such a token escalates.
  Other signals with no captain-relevant status -> self-handle.
- `signal` or `stale` for a declared `paused:` external wait -> self-handle and track the pause rather than a wedge.
  If it remains declared and idle past `FM_PAUSE_RESURFACE_SECS` (default 3600s), housekeeping sends one awaiting-external recheck and resets the pause window.
- `check` -> always escalate. Check scripts print only when firstmate should wake.
- `stale` with a terminal status or bare legacy captain-relevant line -> escalate.
  Nonterminal progress remains transient even when its prose contains a legacy free-text token or its seen-status marker already matches, so record a marker and self-handle.
  If the pane is still idle past `FM_STALE_ESCALATE_SECS` (default 240s), housekeeping escalates it as a possible wedge.
  This bounds wedge-detection latency to the threshold plus a tick: a delay, never a loss.
  Healthy crewmates are autonomous and do not wait on firstmate mid-task.
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
  tmux and herdr route their raw styled candidate rows through the shared `fm_composer_strip_ghost` extractor, which removes dim/faint and dark-TRUECOLOR ghost/placeholder text before classification.
  They read the composer shape from a separately ANSI-stripped plain row because a dark TRUECOLOR border can be stripped with ghost content.
  A ghost-only or idle bordered composer such as claude's `│ > ... │` therefore reads empty without allowing an unbordered shell prompt to do the same.
  `FM_COMPOSER_IDLE_RE` still overrides tmux empty-composer matching after shared ghost and border stripping, and `FM_BUSY_REGEX` overrides busy footers.
- **Max-defer escape** - the daemon must never silently wedge. If anything stays
  buffered past `FM_MAX_DEFER_SECS` (default 300s), the daemon attempts one
  normal flush, which still requires an idle pane and an affirmatively empty composer. If that
  cannot confirm a submit, it raises a loud, rate-limited wedge alarm: ERROR log,
  durable `state/.subsuper-inject-wedged` marker, a tmux status-line flash when
  applicable, and a backend-independent active alert. A
  composer false-positive surfaces as a visible stall, never an unbounded silent
  no-op.
- **Verified type-once submit model** - the digest is typed once (`send-keys -l`
  on tmux, `pane send-text` on herdr), then submitted with Enter and verified.
  Enter is retried, Enter only and never a retype, until the backend submit
  primitive reports `empty` as its caller-facing success verdict.
  For tmux that verdict means the shared-ghost-aware and border-aware composer
  cleared.
  For herdr's normal idle-baseline path it means native agent-state observed a real turn start; herdr uses the ANSI-aware structural classifier for the pre-injection composer guard and fallback paths.
  This lets ghost-only or bordered-empty composers count as empty where a composer read is the active confirmation signal.
- **Marker strip** - `strip_injection_marker` removes the sentinel prefix before
  classification or relay, so the digest text firstmate sees is clean.
- **Portable singleton lock** - the daemon uses the repo's portable lock helper
  (`fm-wake-lib.sh`) instead of `flock`, which is absent on macOS.
- **Dedupe across signal/stale/scan** - `classify_signal` and terminal `classify_stale` paths check the seen-status marker before escalating, so a captain-relevant status escalated by one path is not re-escalated by another in the same digest.
  The marker does not clear or suppress possible-wedge aging for a nonterminal progress line.
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

## Stale-artifact lifecycle

Treat `state/.subsuper-escalations`, its `.since` sidecar, and `state/.subsuper-inject-wedged` as session-scoped delivery artifacts, not as the durable work record.
Always enter through `bin/fm-afk-launch.sh`, which clears prior-session artifacts only for a fresh entry and preserves the current session's buffer on refresh.
Always exit through `bin/fm-afk-launch.sh stop`, which keeps `state/.afk` present through the daemon's shutdown flush and clears it last.
`docs/herdr-backend.md` "Stale-artifact lifecycle fix" owns the mechanism and verification evidence.

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
