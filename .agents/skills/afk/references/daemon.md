# The daemon, where it still runs

Load this with the `afk` skill, or with the `quiet` skill that shares this machinery, when launching, operating, or diagnosing the daemon.

On the harness and backend combinations that still launch the daemon, the mechanics below are unchanged.
Pi, pi-signed, a home that runs the supervision host, and the T3 Code limits in [the launch reference](launch.md) remain outside this section.

# Operational prefix contract

The daemon constructs each current escalation as the `away-supervisor` kind owned by `bin/fm-operational-input.sh`; its envelope begins with `FM_OPERATIONAL_PREFIX`: `FM_INJECT_MARK` (U+2063 INVISIBLE SEPARATOR) followed by the stable `FIRSTMATE_OP: ` label.
The bare `FM_INJECT_MARK` form remains accepted for legacy daemon escalations during rollout.
U+2063 has no normal keyboard keystroke and survives terminal transport as UTF-8 text, but Claude Code (verified on 2.1.280) removes it, with every other invisible character, from each submitted prompt, whether typed, pasted, or passed as the launch prompt.
For a primary harness the owner lists as stripping the marker (Claude Code), the daemon instead writes the envelope as a record in this home's `state/operational-inbox` and types only the owner's plain doorbell naming it.
That doorbell is Firstmate's only when `open` verifies the record in this home, so the doorbell shape alone never counts; a verbatim copy of a live doorbell line, pasted back while its record still exists, is treated as Firstmate's, because the carrier does not track consumption.
This is how firstmate tells a daemon escalation apart from a real message in the same pane.
For other harnesses, the operational prefix travels with the message text; neither carrier relies on harness-level typed-vs-injected detection.

# Busy-guard and composer guard

The daemon never injects into an in-use pane. T3 Code has no composer and uses
the native status and turn transport owned by
[`docs/t3code-backend.md`](../../../../docs/t3code-backend.md#away-mode). Two
checks run before every pane injection, dispatched through `bin/fm-backend.sh`
for the supervisor's own backend (see [supervisor backend configuration](../../../../docs/configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target)):

- **Primary-pane busy guard** - `pane_is_busy` trusts the backend's native `busy` when available, otherwise matches rendered output against only the detected primary harness's signature.
  This narrow delivery guard never classifies a recorded worker task and never uses a global union of vendor patterns.
- **Composer-state guard** - `inject_msg` reads the full `empty`/`pending`/`pending-unproven`/`unknown` verdict from `fm_backend_composer_state` and injects only when it is affirmatively `empty`.
  Every other or future verdict defers, including an unreadable pane, ambiguous geometry, a blank unidentified row, and a bare shell prompt left after the agent exits.
  Each adapter contributes only capture and capability facts to the fleet-wide screen classifier in `bin/fm-composer-lib.sh`, which owns every shape and verdict.
  It preserves proven idle composers as empty but requires a genuine container around shell glyphs; see `docs/herdr-backend.md` "Composer and injection safety" for the operator contract.
  `pane_input_pending` is the tested fail-closed predicate for callers that need to know whether the composer is unsafe: it treats every result except exact `empty` as pending.

A busy primary pane, or any composer verdict other than `empty`, defers the injection; the buffered escalation survives in `state/.subsuper-escalations` and is retried on the next housekeeping tick.
In afk mode the composer guard is belt-and-suspenders (no human is typing), but it protects against the race window between the captain returning and their message landing, a dead shell, and the daemon's own previous injection sitting unsent.

**Max-defer escape (the daemon must never silently wedge).**
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon attempts one normal flush, which still requires an idle endpoint and, on pane backends, an affirmatively empty composer.
The alarm is defense in depth rather than a substitute for keeping every genuinely idle supported composer injectable.
If that submit cannot be confirmed, it raises a loud, rate-limited wedge alarm:
an ERROR in the daemon log naming the last delivery failure, a durable
`state/.subsuper-inject-wedged` marker (the return brief's health line carries it), a tmux status-line flash when applicable, and a configurable backend-independent active alert.
`docs/wedge-alarm.md` owns the alert channel setup, and `docs/verification/supervision.md` "Wedge-alarm channels" owns active evidence.
So a guard false-positive becomes a visible stall, never an unbounded silent no-op.

# Submit model

On tmux and Herdr, the digest is typed **once** with a literal, non-submitting send (`send-keys -l` on tmux, `pane send-text` on Herdr).
Enter submits it, and the selected backend's submit primitive verifies delivery.
Enter is retried (Enter only, never a retype) until the backend confirms the
submit landed.
A failed delivery is logged with its stage (initial send or Enter delivery, where no confirmation retry ran and the text may already be typed on backends such as herdr whose Enter could not be sent, or Enter confirmation), the payload's byte count, and the transport's own error output.
For tmux that confirmation is normally a proven cleared composer from the shared classifier; an idle baseline transitioning to busy across this submit's own Enter also confirms that the turn started when a working harness hides its composer.
Without that baseline, busy state never converts an `unknown` composer into confirmation.
For herdr, idle-baseline submits first seek native agent-state showing a real turn started, then use the shared classifier when native state remains idle: a cleared composer confirms delivery, while pending text retries Enter and reaches the shared busy-queue verdict only after the retry budget.
A bordered-empty or ghost-only composer is recognized as empty where that backend uses composer confirmation, rather than mistaken for a swallowed Enter.
`fm-send.sh` uses the same primitive only on its typed plane and exits non-zero when that plane's Enter is positively swallowed; ordinary local text steers use the durable inbox and do not treat doorbell submission as delivery proof.

**Busy-queued Enter exception (opencode).** OpenCode keeps queued text visible while it is mid-turn, so the supported supervisor adapters delegate the final delivery decision to `fm_composer_queued_enter_verdict` in `bin/fm-composer-lib.sh` rather than treating visible text alone as a swallowed Enter.
The daemon still clears its buffer only on the backend's `empty` success verdict; [`docs/tmux-backend.md`](../../../../docs/tmux-backend.md), [`docs/herdr-backend.md`](../../../../docs/herdr-backend.md), [`docs/rex-backend.md`](../../../../docs/rex-backend.md#current-operation-and-safety), and [`docs/t3code-backend.md`](../../../../docs/t3code-backend.md#away-mode) own the backend-specific confirmation signals.

# Classification policy

The daemon wraps `fm-watch.sh`, runs the watcher as a child, presents every durable wake after each actionable watcher close, classifies each presented record in bash, and acknowledges the presented generation only after routing completes.
It self-handles the routine majority without consuming a firstmate turn.
Events selected by the routing below escalate to firstmate's context as one pre-read, single-line, batched digest.
The digest is byte-bounded so every transport can carry it; when it cuts an event or omits events past its budget, it names a `state/.subsuper-digests/` file that holds every buffered event verbatim, so read that file before acting on a cut event.
The captain-relevant verb set, declared-wait vocabulary, status-span classifier, and presentation-marker contract live in shared `bin/fm-classify-lib.sh`, while each supervisor owns its routing and fleet scan as a consumer of that policy.
While `state/.afk` exists the daemon owns the watcher, so the watcher reverts to one-shot and lets the daemon do the triage - the two never run their triage at the same time.

Classify each wake this way, applying the steering-inbox exception before status-based routing:

- `stale` whose detail begins `unread firstmate instruction: stuck-busy ` or `steering-inbox busy bookkeeping unwritable: ` -> buffer the explicit inbox escalation for supervision in away and quiet mode, without consuming worker status or entering transient-stale recovery.
  [`bin/fm-task-inbox-lib.sh`](../../../../bin/fm-task-inbox-lib.sh) owns the busy budget and bookkeeping contract; `tests/fm-daemon.test.sh` covers this consumer boundary.
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
  For T3 native uncertainty, follow the [stale-alert retention contract](../../../../docs/t3code-backend.md#away-mode).
  This bounds wedge-detection latency to the threshold plus a tick: a delay, never a loss.
  A stale detail that ends with `blocked-on-prompt:` and a dialog name means the pane shows that dialog, so the worker cannot continue until someone answers it.
  An escalation this path already sends keeps that name, whether it comes from the status log or from housekeeping.
  A terminal status that was already reported still clears the persistence marker, the same as a stale with no dialog name.
  A declared wait keeps the pause cadence and does not carry the name.
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

# Injection hardening

- **Single-line digest** - embedded newlines are collapsed to a literal
  separator before injection, so submission is unambiguous regardless of
  harness.
- **Busy and composer guards on the supervisor endpoint** - before injecting, the daemon runs the backend's busy guard and reads `fm_backend_composer_state` directly.
  On pane backends, only `empty` permits injection; `pending` protects half-typed or swallowed input, and `unknown` protects unreadable panes and bare dead-shell prompts.
  For T3 Code, follow the [native injection contract](../../../../docs/t3code-backend.md#away-mode).
  Every other pane verdict preserves the buffer for retry, so the daemon never merges its digest into the captain's half-typed line or types it into a shell.
- Pane backends pass their capture plus declarative styled, cursor, identity, and row capabilities to the shared screen classifier; all structural recognition and verdict logic remains in `bin/fm-composer-lib.sh`.
  Styled captures let that owner remove dim/faint and dark-TRUECOLOR ghost or placeholder text while shape detection uses the ANSI-stripped screen, so a dark border is not lost with ghost content.
  A ghost-only or idle bordered composer such as claude's `│ > ... │` therefore reads empty without allowing an unbordered shell prompt to do the same.
  `FM_COMPOSER_IDLE_RE` overrides the shared idle-placeholder regex, but a match alone never bypasses the classifier's shape-specific position and ANSI de-emphasis safety gates.
  `FM_BUSY_REGEX` overrides the rendered delivery guards plus Grok's isolated task-state fallback.
  A blank or otherwise unidentified input row carries no positive container proof and defers injection, so a modal dialog or a mid-redraw pane is never an injection target.
- **Max-defer escape** - follow the [bounded flush and alarm contract above](#busy-guard-and-composer-guard) and the [alert setup guide](../../../../docs/wedge-alarm.md).
- **Verified submit model** - follow the [submit model](#submit-model) and its linked backend confirmation contracts.
- **Marker strip** - `strip_injection_marker` removes the current operational
  prefix or legacy bare marker before classification or relay, so the digest
  text firstmate sees is clean; `open` prints a record-backed doorbell's digest
  already stripped.
- **Portable singleton lock** - the daemon uses the repo's portable lock helper
  (`fm-wake-lib.sh`) instead of `flock`, which is absent on macOS.
- **Dedupe across signal/stale/scan** - all three paths use the shared status presentation markers defined by `bin/fm-classify-lib.sh`, so a successfully classified span is not re-escalated by another path in the same digest.
  Never treat a reported unreadable state as classified; the shared library header owns that marker contract, and the marker does not clear or suppress possible-wedge aging for a nonterminal progress line.
- **Auto-discovered supervisor pane** - [supervisor backend configuration](../../../../docs/configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns backend and target resolution and unsupported-transport refusals.
  Both resolution sources are logged at startup so a wrong-but-resolving fallback is detectable.

# Stale-artifact lifecycle

Treat `state/.subsuper-escalations`, its `.since` sidecar, `state/.subsuper-inject-wedged`, and `state/.subsuper-unknown-acked` as session-scoped delivery artifacts, not as the durable work record.
Always enter through `bin/fm-afk-launch.sh`, which clears prior-session artifacts only for a fresh entry and preserves the current session's buffer on refresh.
Always exit through `bin/fm-afk-launch.sh stop`, which keeps `state/.afk` present through the daemon's shutdown flush, clears it, and archives the posture record last.
`docs/herdr-backend.md` "Away-mode supervisor support" and `docs/t3code-backend.md` "Away mode" own the backend mechanisms, and `docs/verification/runtime-backends.md` "Away-mode transport" owns active evidence.

# Reliability properties

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
