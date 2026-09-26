---
name: afk
description: >-
  Enter the away posture when the captain invokes /afk, says they are going afk, `state/.afk-contract` or `state/.afk` exists, an incoming message starts with `FM_INJECT_MARK`, or any `state/.subsuper-*` marker is involved.
  It writes the durable away-posture record with the captain's away words verbatim as the whole mandate in the same turn as /afk, before any other work and without waiting for a further go, reads the words back in plain sentences after entry, announces hold-for-return only at entry, keeps the one supervision session running in the away posture (on Pi the supervision branch acts on the words by its own judgment and takes every safe actionable wake with main parked, as the supervision host does on a non-Pi home that opted into it; the daemon still delivers batched digests elsewhere for now), and on the first unmarked message renders the return brief from durable records before ordinary work resumes.
user-invocable: true
metadata:
  internal: true
---

# afk

Away mode is a POSTURE of the one supervision session, not a second architecture.
Being away changes exactly two things: how the captain is informed, and what happens at a captain-owned decision point (hold for return, or the answer the captain's away words already gave).
It never changes the authority set.
The posture is a file, `state/.afk-contract`, written only by `bin/fm-afk-contract.sh` in the same turn as `/afk`; nothing infers the posture from chat.
Typing `/afk` is itself the go: the captain may not look at the screen again, so entry never waits for a further human response, and no read-back gates it or asks for a go.
Hold-for-return is the default and the only reach profile this release records: there is no phone channel, and the entry announcement says so aloud every time.

## Entering: `/afk [words]`

1. **Write the record first, in this same turn.**
   Before any other work, run `bin/fm-afk-launch.sh enter --words-file <path> [--expected-return <UTC ISO 8601>] [--spend <n>]` (or `--words <text>`).
   It writes `state/.afk-contract` at once, with no separate confirmation step, then prints the entry announcement and the record's read-back.
   The words are the whole mandate: `bin/fm-afk-contract.sh` records them exactly as given, with no clause fields, verbs, ids, or merge-grant list, and by the captain's mandate no parser, tokenizer, classifier, or grammar reads them anywhere.
   Read `bin/fm-afk-contract.sh --help` for the flags rather than memorizing them.
   Plain `/afk` with no words is a valid entry with no mandate; the announcement says no instructions were recorded.
   Re-invoking `/afk` while already away with no new words is a refresh and leaves the standing record untouched; new words replace the mandate at once, preserve the original session entry, and archive the superseded words for the return brief.
2. **Per harness, after the record exists:**
   - **Pi and pi-signed**: nothing to launch; go on to the announcement.
     The away daemon is no longer launched on Pi; the ordinary supervision session (`docs/pi-supervision-branch.md`) keeps running with the record present, and `bin/fm-afk-launch.sh start` refuses on these harnesses.
     With the record present main is parked: the supervision branch takes every safe actionable wake, captain outcomes accumulate for the return brief, and main's standing authority relocates to the branch through the guarded scripts (`docs/pi-supervision-branch.md` "Postures"); only a wake the branch declines (including a broken branch or unsafe scan) or a watcher failure wakes main.
     `/quiet` needs nothing extra on Pi: the attended branch already keeps routine wakes out of this conversation, so quiet-while-present is the attended posture's own shape there.
   - **Claude, Cursor, OpenCode, omp, Grok, or Codex with `config/supervision-host`**: nothing to launch for `/afk`; go on to the announcement.
     The supervision host (`docs/supervision-host.md`) is the away session there: it runs the branch's contract on a headless engine under the record while main is parked, and `bin/fm-afk-launch.sh start` and `start-native` refuse the away daemon on that home.
     If `enter` printed a `Supervision host: no engine ...` line, every away wake reaches this conversation instead; say so in the announcement.
     `/quiet` is unchanged there and still launches the daemon below.
   - **Harness WITH a native in-pane tracked-background tool** (claude's and grok's, without the supervision host): run `bin/fm-afk-launch.sh start-native`, then run `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` through that native tool.
     This is a deliberate no-separate-terminal exception because the harness-hosted job creates no terminal or layout mutation, and a shell launcher cannot invoke a harness-native background tool.
     If the native launch fails, run `bin/fm-afk-launch.sh stop` to roll back the prepared lifecycle.
     Do not wrap it in `nohup ... &` (Codex/herdr can reap fire-and-forget shell children after a tool call returns).
   - **Every other harness** (codex, opencode, omp, and cursor without the supervision host, and kimi): run `bin/fm-afk-launch.sh start`.
     It is the single owner of the daemon terminal: it creates a NON-VISIBLE tracked terminal for the current backend and passes the captain pane in as `FM_SUPERVISOR_TARGET` so the daemon injects into the captain, not its own new pane (docs/herdr-backend.md "Away-mode supervisor support").
   Both daemon paths require the record `enter` wrote and share `bin/fm-afk-start.sh` as the daemon entry.
   The daemon is **presence-gated**: it injects escalations only while `state/.afk` exists, and stays quiet otherwise.
3. **Announce, then read back after entry.**
   Relay the announcement in spirit: hold-for-return only, no phone channel, your instructions are recorded and the away session will carry them out where it can, anything it is unsure of, or that needs you, waits for your return, and destructive, irreversible, and security-sensitive actions are never pre-authorizable whatever the words say.
   Then give your own plain-sentence restatement of the words in `AGENTS.md` section 9 language - what you read them as asking for, sentence by sentence, never a numbered field list - beside the expected return, the spend cap, and the one-sentence reach announcement.
   Say plainly which sentence, if any, you could not act on while away (a red merge, a discard, anything on the never-set, local-only landing); it waits for their return.
   This read-back is informational: the record already stands, so never ask for a go or wait for a reply; a captain who wants a different reading sends `/afk` again with new words.
4. **Do not separately arm `fm-watch.sh` where the daemon runs.** The daemon manages the watcher as its child; the singleton lock no-ops a stray arm harmlessly.
   On Pi nothing changes about arming: the supervision session's own cycle continues.

## While away

- The record exists, so the watcher never rechecks an item held for the captain, in either supervision shape; the return brief lists it instead.
  Declared external waits keep their condition-aware, hours-long recheck cadence (`bin/fm-watch.sh`, `bin/fm-classify-lib.sh`).
- The away session acts on the captain's words.
  It reads them at the tail of every wake, decides by its own judgment whether the event in front of it is the moment they name, acts on them only through the guarded scripts under standing authority, never by analogy, holds with verdict captain on doubt, and opens every outcome summary for an action taken under the words with "per your away instructions:" (`bin/fm-branch-prompt.sh` "Postures" owns the execution rules).
  Destructive, irreversible, and security-sensitive actions are never pre-authorizable whatever the words say, and ask-user findings keep the `ask-user-authority` policy unless the words pre-answer the exact decision; anything else that needs the captain holds for their return.
- On Pi, main is parked and the supervision branch handles every safe actionable wake under main's standing authority, through the same guarded scripts main would use: any pull request green at its live head may merge (which one the words meant is the branch's reading), queued work whose blockers cleared - already queued, or filed by the branch because the words explicitly call for it - dispatches within the spend cap, and a decision is answered with the captain's own pre-stated answer or under `ask-user-authority`.
  Anything else holds for the return, a red merge never proceeds while away, local-only landing always waits for the captain, and only a wake the branch declines (including a broken branch or unsafe scan) or a watcher failure wakes main (`docs/pi-supervision-branch.md` "Postures").
- On a non-Pi home with `config/supervision-host`, the host's engine is that branch under the same rules, and a wake it hands back reaches main through that harness's own wake path (`Stop hook feedback` on Claude, a `watcher` follow-up on Cursor, OpenCode, and omp, the arm's background-task-completed notification on Grok, the checkpoint's output on Codex) with a `supervision-host:` line: that is automatic supervision, never the captain's return, so handle it under the away posture ([supervision protocol](../../../docs/supervision-protocols/supervision-host.md)).
- The session-start digest reports the posture under its AFK subsection, so a restart re-enters the posture from the record, not from memory.

## How to exit: the return

No `/back` is needed. The first genuine message is the return signal:

- A message that is none of the internal forms below, and **not** starting with `/afk` -> the captain is back.
  Run `bin/fm-afk-return.sh` before acting on the message that brought the captain back.
  That script owns the correct-ordered daemon shutdown where a daemon ran, the archive of the posture record, durable wake presentation and post-handling acknowledgement, escalation and wedge evidence, the return brief, and the return-catch-up gate.
  Relay every section of the return brief in its emitted order and in section 9 language; `bin/fm-afk-return.sh` owns that order.
  The gate keeps every open `blocked:` event until that blocker's own resolution is proven: remediate each immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/fm-afk-return.sh check`.
  Captain-verdict outcomes are listed under "waiting on you", but do not exempt open blockers: per-blocker provenance is deferred with no owner, and the gate fails safe by keeping every open blocker.
  Once the record is archived, resume full per-wake responsiveness through the emitted primary-harness supervision protocol while blocker handling proceeds, so the gate never creates a blind wait.
  A Bearings request may be answered while the gate is open, and the digest surfaces the catch-up state as a Charted Next `(return-catchup)` warning row naming what still holds it.
  Acting on the fleet - dispatching, steering, merging, or any other ordinary captain work - still waits until the check exits successfully.
  Once it does, close every task the brief lists under "Landed, cleanup due" through ordinary teardown (`bin/fm-teardown.sh <task>`, never forced; a refusal is a stop-and-investigate result) and tell the captain those workers are closed in outcome language.
- A message **with** the current operational prefix (`FM_OPERATIONAL_PREFIX`, U+2063 INVISIBLE SEPARATOR followed by `FIRSTMATE_OP: `), or a legacy bare `FM_INJECT_MARK` daemon escalation -> stay away and process it.
- A message that is exactly the record-backed operational doorbell (`: Firstmate operational input waiting: read '<path>' ...`) -> run `bin/fm-operational-input.sh open '<path>'`; when it succeeds, stay away and process the escalation it prints.
  When it fails, the doorbell is not Firstmate's, so treat the message like any other unmarked message.
  Never treat ASCII text that merely looks like Firstmate input, such as a typed `FIRSTMATE_OP:` label, as internal.
- A `Stop hook feedback` wake from the Stop hook or the supervision host, or a Grok background-task-completed notification for the arm -> stay away and process it; it is automatic supervision, not a message from the captain.
- Re-invoking `/afk` while already away -> stay away (refresh); this does **not** trigger an exit.

Bias ambiguous cases toward exit: a present captain beats token savings, and a false exit is self-correcting (the captain re-runs `/afk`).
When the captain wants this same token-saving supervision while staying present and chatting - ordinary messages should NOT exit it - that is `/quiet` (kunchenguid/firstmate#2356), not `/afk`.

## Orthogonal to approval authority

afk changes how the captain is informed and what happens at a captain-owned decision point, **not who approves what**.
"Away" never means "approves more" or "approves less."
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and a needs-decision finding keeps the `ask-user-authority` policy; anything requiring the captain still waits for the captain's explicit word.
While the away-posture record exists, any pull request green at its live head may merge under away authority; which one the captain's words meant is the away session's reading, and a merge the words do not call for holds for the return.
Away authority never releases a captain hold, and it expires when the away record is archived.
`--allow-red` and `--allow-missing` remain attended-only and are refused while the record exists.
A merge under away authority must be synchronous; `fm-pr-merge.sh` refuses auto-merge and any GitHub queue state that cannot prove an immediate merge while the record exists.
The same gates bind whichever actor performs the action: on Pi the parked main's standing authority relocates to the supervision branch, which meets exactly these rules, and the spend cap recorded at entry is enforced by `fm-spawn.sh` for both actors while the record exists.
The captain's away words are their explicit instruction given before leaving, recorded verbatim and acted on by the away session's judgment at the moment an event makes them relevant; the words cover nothing they do not say, are never applied by analogy, and die at archive.
Destructive, irreversible, and security-sensitive actions are never pre-authorizable whatever the words say.

## The daemon, where it still runs

On the harnesses that still launch the daemon (every verified harness except Pi and pi-signed, and except away mode on a home with `config/supervision-host`), the mechanics below are unchanged.

### Operational prefix contract

The daemon constructs each current escalation as the `away-supervisor` kind owned by `bin/fm-operational-input.sh`; its envelope begins with `FM_OPERATIONAL_PREFIX`: `FM_INJECT_MARK` (U+2063 INVISIBLE SEPARATOR) followed by the stable `FIRSTMATE_OP: ` label.
The bare `FM_INJECT_MARK` form remains accepted for legacy daemon escalations during rollout.
U+2063 has no normal keyboard keystroke and survives terminal transport as UTF-8 text, but Claude Code (verified on 2.1.280) removes it, with every other invisible character, from each submitted prompt, whether typed, pasted, or passed as the launch prompt.
For a primary harness the owner lists as stripping the marker (Claude Code), the daemon instead writes the envelope as a record in this home's `state/operational-inbox` and types only the owner's plain doorbell naming it.
That doorbell is Firstmate's only when `open` verifies the record in this home, so the doorbell shape alone never counts; a verbatim copy of a live doorbell line, pasted back while its record still exists, is treated as Firstmate's, because the carrier does not track consumption.
This is how firstmate tells a daemon escalation apart from a real message in the same pane.
For other harnesses, the operational prefix travels with the message text; neither carrier relies on harness-level typed-vs-injected detection.

### Busy-guard and composer guard

The daemon never injects into an in-use pane. Two checks run before every
injection, dispatched through `bin/fm-backend.sh` for the supervisor's own
backend (tmux or herdr; see "Auto-discovered supervisor pane" below):

- **Primary-pane busy guard** - `pane_is_busy` trusts Herdr native `busy` when available, otherwise matches rendered output against only the detected primary harness's signature.
  This narrow delivery guard never classifies a recorded worker task and never uses a global union of vendor patterns.
- **Composer-state guard** - `inject_msg` reads the full `empty`/`pending`/`pending-unproven`/`unknown` verdict from `fm_backend_composer_state` and injects only when it is affirmatively `empty`.
  Every other or future verdict defers, including an unreadable pane, ambiguous geometry, a blank unidentified row, and a bare shell prompt left after the agent exits.
  Each adapter contributes only capture and capability facts to the fleet-wide screen classifier in `bin/fm-composer-lib.sh`, which owns every shape and verdict.
  It preserves proven idle composers as empty but requires a genuine container around shell glyphs; see `docs/herdr-backend.md` "Composer and injection safety" for the operator contract.
  `pane_input_pending` is the tested fail-closed predicate for callers that need to know whether the composer is unsafe: it treats every result except exact `empty` as pending.

A busy primary pane, or any composer verdict other than `empty`, defers the injection; the buffered escalation survives in `state/.subsuper-escalations` and is retried on the next housekeeping tick.
In afk mode the composer guard is belt-and-suspenders (no human is typing), but it protects against the race window between the captain returning and their message landing, a dead shell, and the daemon's own previous injection sitting unsent.

**Max-defer escape (the daemon must never silently wedge).**
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon
attempts one normal flush, which still requires an idle pane and an affirmatively empty composer.
The alarm is defense in depth rather than a substitute for keeping every genuinely idle supported composer injectable.
If that submit cannot be confirmed, it raises a loud, rate-limited wedge alarm:
an ERROR in the daemon log naming the last delivery failure, a durable
`state/.subsuper-inject-wedged` marker (the return brief's health line carries it), a tmux status-line flash when applicable, and a configurable backend-independent active alert.
`docs/wedge-alarm.md` owns the alert channel setup, and `docs/verification/supervision.md` "Wedge-alarm channels" owns active evidence.
So a guard false-positive becomes a visible stall, never an unbounded silent no-op.

### Submit model

The digest is typed **once** (`send-keys -l` on tmux, `pane send-text` on
herdr - both literal, non-submitting sends), then submitted with Enter and
**verified** through the selected backend's submit primitive.
Enter is retried (Enter only, never a retype) until the backend confirms the
submit landed.
A failed delivery is logged with its stage (initial send or Enter delivery, where no confirmation retry ran and the text may already be typed on backends such as herdr whose Enter could not be sent, or Enter confirmation), the payload's byte count, and the transport's own error output.
For tmux that confirmation is normally a proven cleared composer from the shared classifier; an idle baseline transitioning to busy across this submit's own Enter also confirms that the turn started when a working harness hides its composer.
Without that baseline, busy state never converts an `unknown` composer into confirmation.
For herdr, idle-baseline submits first seek native agent-state showing a real turn started, then use the shared classifier when native state remains idle: a cleared composer confirms delivery, while pending text retries Enter and reaches the shared busy-queue verdict only after the retry budget.
A bordered-empty or ghost-only composer is recognized as empty where that backend uses composer confirmation, rather than mistaken for a swallowed Enter.
`fm-send.sh` uses the same primitive only on its typed plane and exits non-zero when that plane's Enter is positively swallowed; ordinary local text steers use the durable inbox and do not treat doorbell submission as delivery proof.

**Busy-queued Enter exception (opencode 1.18.4).** OpenCode keeps queued text visible while it is mid-turn, so tmux and herdr delegate the final delivery decision to `fm_composer_queued_enter_verdict` in `bin/fm-composer-lib.sh` rather than treating visible text alone as a swallowed Enter.
The daemon still clears its buffer only on the backend's `empty` success verdict; [`docs/tmux-backend.md`](../../../docs/tmux-backend.md) and [`docs/herdr-backend.md`](../../../docs/herdr-backend.md) own the backend-specific confirmation signals.

### Classification policy

The daemon wraps `fm-watch.sh`, runs the watcher as a child, presents every durable wake after each actionable watcher close, classifies each presented record in bash, and acknowledges the presented generation only after routing completes.
It self-handles the routine majority without consuming a firstmate turn.
Captain-relevant events, plus a bounded recheck of a declared external wait that is still declared, escalate to firstmate's context as one pre-read, single-line, batched digest.
The digest is byte-bounded so every transport can carry it; when it cuts an event or omits events past its budget, it names a `state/.subsuper-digests/` file that holds every buffered event verbatim, so read that file before acting on a cut event.
The captain-relevant verb set, declared-wait vocabulary, status-span classifier, and presentation-marker contract live in shared `bin/fm-classify-lib.sh`, while each supervisor owns its routing and fleet scan as a consumer of that policy.
While `state/.afk` exists the daemon owns the watcher, so the watcher reverts to one-shot and lets the daemon do the triage - the two never run their triage at the same time.

Classify each wake this way:

- `signal` whose newly classified status span contains captain-relevant events -> escalate every event in source order.
  A nonterminal progress verb remains nonterminal even when its prose contains a legacy free-text token such as `PR ready`, `checks green`, `ready in branch`, or `merged`; only a bare legacy line with such a token escalates.
  Other signals with no captain-relevant event in the span -> self-handle.
- `signal` or `stale` whose latest status declares a wait, either a `paused:` external wait or a verified `captain-held` transfer, tracks the pause rather than a wedge whether its pane reads idle or busy.
  An unreported captain-relevant event in the newly classified span still escalates immediately while the current declaration independently keeps the pause cadence.
  With no unreported actionable event, the wake self-handles, and the current declaration outranks an enriched possible-wedge reason so it never escalates on the `FM_STALE_ESCALATE_SECS` cadence.
  If a declared external wait is still declared past `FM_PAUSE_RESURFACE_SECS` (default four hours), housekeeping sends one recheck and resets the pause window; a captain-held transfer is never rechecked while the posture record exists.
  The window ages against the crew's own latest status line, so only a status append that stops declaring the wait ends this routing and restores wedge detection.
- `check` -> always escalate. Check scripts print only when firstmate should wake.
- `stale` with a terminal status, a bare legacy captain-relevant line, or an unrecognized status prefix such as `parked:` -> escalate.
  Nonterminal progress remains transient even when its prose contains a legacy free-text token or its seen-status marker already matches, so record a marker and self-handle.
  If the pane is still idle past `FM_STALE_ESCALATE_SECS` (default 240s), housekeeping escalates it as a possible wedge.
  This bounds wedge-detection latency to the threshold plus a tick: a delay, never a loss.
  Healthy crewmates are autonomous and do not wait on firstmate mid-task.
- `heartbeat` -> self-handle.
  The daemon runs its own cheap bash fleet scan every `FM_HEARTBEAT_SCAN_SECS` (default 300s) as the catch-all for captain-relevant events still unread by the per-wake classifier.
- An unknown wake reason escalates fail-safe.
  After that escalation is delivered, its exact distilled line is acknowledged and the same identity does not escalate again during that away session.
  A new away session starts with no acknowledgements, so a handled identity can present once more.
  An identity that was not delivered still escalates.
  Status-read uncertainty follows the shared one-report-without-position-advance contract referenced under Dedupe below.

Escalations are buffered up to `FM_ESCALATE_BATCH_SECS` (default 90s; 0 = immediate) and flushed as one single-line digest carrying pre-read status summaries and a recommended action.
The single-line format makes submission unambiguous across harnesses; the carrier described above distinguishes it from an ordinary captain message.

### Injection hardening

- **Single-line digest** - embedded newlines are collapsed to a literal
  separator before injection, so submission is unambiguous regardless of
  harness.
- **Busy and composer guards on the supervisor pane** - before injecting, the daemon runs the detected-primary-harness rendered busy guard and reads `fm_backend_composer_state` directly.
  Only `empty` permits injection; `pending` protects half-typed or swallowed input, and `unknown` protects unreadable panes and bare dead-shell prompts.
  Every other result preserves the buffer for retry, so the daemon never merges its digest into the captain's half-typed line or types it into a shell.
- The active backend passes its capture plus declarative styled, cursor, identity, and row capabilities to the shared screen classifier; all structural recognition and verdict logic remains in `bin/fm-composer-lib.sh`.
  Styled captures let that owner remove dim/faint and dark-TRUECOLOR ghost or placeholder text while shape detection uses the ANSI-stripped screen, so a dark border is not lost with ghost content.
  A ghost-only or idle bordered composer such as claude's `│ > ... │` therefore reads empty without allowing an unbordered shell prompt to do the same.
  `FM_COMPOSER_IDLE_RE` overrides the shared idle-placeholder regex, but a match alone never bypasses the classifier's shape-specific position and ANSI de-emphasis safety gates.
  `FM_BUSY_REGEX` overrides the rendered delivery guards plus Grok's isolated task-state fallback.
  A blank or otherwise unidentified input row carries no positive container proof and defers injection, so a modal dialog or a mid-redraw pane is never an injection target.
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
  For tmux that verdict normally means the shared classifier proved the composer cleared; a baseline-gated idle-to-busy transition may instead prove this Enter started the turn.
  For herdr's idle-baseline path it means native agent-state observed a turn start, the shared classifier proved the composer cleared, or the shared queued-Enter verdict proved delivery while busy.
  This lets ghost-only or bordered-empty composers count as empty where a composer read is the active confirmation signal.
- **Marker strip** - `strip_injection_marker` removes the current operational
  prefix or legacy bare marker before classification or relay, so the digest
  text firstmate sees is clean; `open` prints a record-backed doorbell's digest
  already stripped.
- **Portable singleton lock** - the daemon uses the repo's portable lock helper
  (`fm-wake-lib.sh`) instead of `flock`, which is absent on macOS.
- **Dedupe across signal/stale/scan** - all three paths use the shared status presentation markers defined by `bin/fm-classify-lib.sh`, so a successfully classified span is not re-escalated by another path in the same digest.
  Never treat a reported unreadable state as classified; the shared library header owns that marker contract, and the marker does not clear or suppress possible-wedge aging for a nonterminal progress line.
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
  (docs/herdr-backend.md "Away-mode supervisor support").

### Stale-artifact lifecycle

Treat `state/.subsuper-escalations`, its `.since` sidecar, `state/.subsuper-inject-wedged`, and `state/.subsuper-unknown-acked` as session-scoped delivery artifacts, not as the durable work record.
Always enter through `bin/fm-afk-launch.sh`, which clears prior-session artifacts only for a fresh entry and preserves the current session's buffer on refresh.
Always exit through `bin/fm-afk-launch.sh stop`, which keeps `state/.afk` present through the daemon's shutdown flush, clears it, and archives the posture record last.
`docs/herdr-backend.md` "Away-mode supervisor support" owns the current mechanism, and `docs/verification/runtime-backends.md` "Away-mode transport" owns active evidence.

### Reliability properties

These properties must hold:

- Nothing is lost after queue publication.
  The daemon leaves every presented wake durable until routing completes and post-handling acknowledgement succeeds, so interruption replays the same work to the daemon or its successor.
- Wedge detection is bounded-latency, not lossy.
- Declared external waits are rechecked on a separate, bounded, condition-aware cadence rather than being mislabeled as wedges; items held for the captain are not rechecked while the posture record exists.
- The catch-all scan backs up the keyword classifier.
- The daemon preserves a single-instance portable lock, crash-loop backoff,
  a pane-gone guard, and a signal-trapped shutdown that flushes buffered
  escalations before exit.

`FM_INJECT_SKIP` (default `heartbeat`) force-self-handles matching kinds,
overriding classification.
Use it sparingly.
