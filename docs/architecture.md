# Architecture

How firstmate works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
firstmate's supervisor contract and routing index for conditional procedures is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Actionable wakes include captain-relevant status signals, no-verb signals without positive evidence that their crew is still executing, authenticated check output such as PR merge polling or a Relay mention, stale panes whose crew is not provably working whether their status log looks terminal or non-terminal, provably-working stale panes that persist past `FM_STALE_ESCALATE_SECS` without their own task worktree being written, declared external waits and verified captain-held transfers that remain declared past `FM_PAUSE_RESURFACE_SECS`, and heartbeat backstop hits.
Repeated provably-working stale escalations on the same unchanged pane add an escalation count to the wake reason and, at `FM_WEDGE_DEMAND_INSPECT_COUNT`, a `demand-deep-inspection` marker.
A pane holding a file newer than the start of its own quiet window, anywhere in the worktree recorded for that task, is deferred instead of escalated, because a crew writing source, then tests, then documentation behind a static pane is liveness that neither pane quietness nor the run step can show.
That deferral re-surfaces on the same `FM_PAUSE_RESURFACE_SECS` cadence as a declared wait, with a reason naming the write evidence rather than a wedge, and it is bounded to one pruned, depth-bounded, wall-clock-bounded walk (`FM_WORKTREE_WRITE_PRUNE`, `FM_WORKTREE_WRITE_MAXDEPTH`, `FM_WORKTREE_WRITE_TIMEOUT`) taken only in the branch that was about to escalate, never on every poll.
Every absence of write evidence, including a missing worktree record, a torn-down worktree, a walk that outlives its wall-clock bound on a hung mount, and a failed walk, leaves the existing escalation schedule untouched, so a crew that writes nothing still escalates exactly as before.
A secondmate's recorded worktree is never probed for write activity, because it is a provisioned firstmate home whose own supervision keeps writing inside it whether or not the mate produces anything, so its panes keep escalating on the unchanged schedule.
A busy pane is otherwise exempt from staleness, but only until its latest `state/<id>.turn-ended` marker reaches `FM_BUSY_TURN_MAX_SECS`, or its `state/<id>.meta` spawn record reaches that age before any turn completes; past that bound it is routed through the same wedge escalation, with the identical reason, escalation count, worktree-write deferral, and `demand-deep-inspection` marker, for inspection only - never an automatic interrupt, signal, or restart.
A crew that declared an external wait (`paused:`) or a verified captain-held transfer is the one exception to that bound: its busy verdict supplies liveness while identifying the long-running foreground call as the declared wait, so it takes the bounded `FM_PAUSE_RESURFACE_SECS` recheck instead of a wedge escalation.
Lifting the declaration restores the unchanged busy-pane wedge path, while a pane that is no longer busy returns to the existing idle declared-wait classification.
While away mode is active, a busy pane that crosses the bound under a declared wait is handed to the daemon as the plain wake identity instead of taking that recheck in the watcher, because the daemon owns triage there and a wake already decorated as a possible wedge would override the daemon's own declared-wait verdict; an undeclared busy pane past the bound still takes the wedge escalation in away mode.
That handoff is keyed on the declaration itself (the status log's signature) rather than on the pane capture, so a harness footer that ticks on every poll wakes the daemon once per declaration instead of once per poll, and it clears the wedge timer, escalation count, and worktree-write deferral exactly as the normal-mode absorber does, so an undeclared busy phase's timer does not resume when the declaration lifts.
Those actionable wakes are written to a durable local queue (`state/.wake-queue`) only after generation-bound recovery evidence is published, so an interrupted watcher or handling turn can be recovered without losing the queue record.
Agent endpoint liveness and queue-consumption liveness are separate: on each poll, the primary watcher reads the oldest valid row from every endpoint-recorded local secondmate home's durable wake queue without locking, consuming, or rewriting that foreign queue.
Once that row reaches `FM_SECONDMATE_WAKE_STALL_SECS`, the primary appends one keyed `check` wake naming the mate, row sequence, and observed age; parent receipts and queued-key deduplication suppress repeats for the same row across watcher and handling crashes, while empty and younger queues remain silent.
Endpointless registered mates remain outside this scan because startup secondmate-liveness owns dead or missing endpoint recovery, and remote homes retain their host-local supervision boundary.
`tests/fm-wake-queue.test.sh` pins the notification, idempotence, quiet-queue, and byte-for-byte foreign-row preservation guarantees.
When a canonical validated PR poll returns exactly `merged`, the watcher routes it through the shared merge-outcome emitter before retiring the poll.
[`bin/fm-merge-outcome-lib.sh`](../bin/fm-merge-outcome-lib.sh)'s header owns role routing, PR-specific wake identity, marker-locked normal deduplication, and the at-least-once ordering that prefers a rare duplicate over silence.
After successful outcome publication, the watcher immediately delivers the emitter's local actionable poll row and publishes a private retirement receipt bound to the poll's registration, bytes, file identities, metadata, provider, URL, and task ID.
The retirement receipt makes poll cleanup safely retryable across restarts: fixed-path recovery revalidates the same evidence, removes the runnable check first, removes its registration and data sidecars, removes the receipt last, and preserves task metadata including `pr=` and `pr_head=`.
A concurrent replacement remains armed, every non-merged or invalid observation remains unchanged, and retirement never performs task or persistent-secondmate cleanup.
`bin/fm-pr-lib.sh` owns the notification-marker and retirement-receipt formats plus their strict identity mechanics, [`bin/fm-merge-outcome-lib.sh`](../bin/fm-merge-outcome-lib.sh) owns role-routed publication, the local durable row, and marker ordering, and `bin/fm-watch.sh` owns immediate poll-result delivery and retirement.
No-verb wakes, such as `working:` notes and bare turn-ended signals, are benign only when every referenced task independently has positive evidence that its crew is still working: a currently attributed active no-mistakes step, or an exact busy verdict from the semantic busy-state contract, both read through `bin/fm-crew-state.sh`.
A home that creates `config/turnend-churn-absorb` lets each eligible bare turn-ended task that lacks either authoritative proof use a third form: pane content that changed since the previous poll, compared against the same `state/.hash-*` marker the staleness backbone records, which claims no harness semantics and needs no adapter cooperation.
That form stays opt-in because it infers execution from rendered bytes rather than from a verdict the harness vouches for, so with the flag absent triage behaves exactly as it did before ([`configuration.md`](configuration.md) "Turn-end pane-churn absorb").
That evidence clears the pane's prior stale classification and wedge-escalation count, then defers such a wake rather than swallowing it, since a crew that has stopped renders nothing further and its now-static pane surfaces through the staleness backbone within a poll or two, even if its final bytes match an earlier stale render.
A wake naming any status file remains governed solely by the strict authoritative proof, and the pane-churn fallback is unavailable to an entire batch that references a secondmate.
An unresolvable endpoint, an ambiguous marker key, a missing or malformed prior hash, a capture that fails or returns empty, an invalid deferral bound or deadline, or an unwritable deferral marker surfaces without clearing prior stale classification.
The deferral is bounded per endpoint by `FM_TURNEND_CHURN_ABSORB_SECS`, tracked in `state/.churn-since-*`, after which the turn-end surfaces and the window restarts.
That bound is load-bearing rather than cosmetic: churn and staleness read the same pane, so a pane that renders continuously - a clock, a spinner, a shell heartbeat, or a harness that leaves a background renderer alive after its agent yields - never reaches the staleness backbone's two-identical-hashes test either, and an unbounded churn absorb would leave a genuinely stopped worker behind such a renderer with no path left to surface it.
If two metadata records derive the same per-window marker key, including two records that name the same endpoint, that marker is not attributable churn evidence for either task, so the bare turn-ended wake surfaces without changing or migrating existing marker state.
A `kind=secondmate` task's status signal is the parent-directed reply stream and is never absorbed as provably working; its bare turn-ended signal is absorbed only by the ordinary authoritative working proof because an active secondmate does not enter the staleness backbone that would resurface deferred pane-churn evidence.
A crew that declares `paused:` for a known external wait, or carries a verified `captain-held` transfer, is separately absorbed while idle and re-surfaced only on the longer pause cadence, rather than being treated as a possible wedge.
For an ordinary crew that has stopped, the normal-mode watcher first surfaces one stale wake, then applies that same cadence to an unchanged `paused:` or durable `captain-held` endpoint; the pause classification itself is recovered only when the backend confidently reports its agent dead.
Live or inconclusive liveness remains fail-open at that initial surface, so a worker genuinely waiting on a decision is never silenced.
Its later sights are still held to that same bounded cadence rather than re-alarming on every pane-hash change, because the throttle is keyed to the declaration and not to the pane an idle parked worker keeps ticking.
A secondmate's endpoint liveness is still never read at all; a mate is admitted to that same cadence only to serve a declared wait's bounded re-surface, so a forgotten pause or captain hold on a mate cannot rot invisibly.
Its initial normal-mode status signal still surfaces through the no-verb path, while away mode self-handles that routine signal and owns the later recheck.
Fresh stale panes use the same current-state read before trusting the status log, so an active run or a proven busy worker outranks an old captain-relevant status-log line left behind before validation.
No-change heartbeats are also benign.
Separately from heartbeat backoff and wedge handling, the watcher poll runs `bin/fm-inactive-reconcile.sh` on its own bounded cadence, while locked session start sends the same bounded local scan through `bin/fm-startup-network.sh`'s deferred worker so current-state reads never block the digest.
In each home the scan considers only that home's long-inactive direct ordinary crewmates, excludes captain-held work, and accepts only `done` or `failed` from `bin/fm-crew-state.sh`.
A secondmate retains a durable receipt for its idempotent report through the established parent route, and main-home captain presentation retains a separate receipt; neither path performs a forge or PR check.
A secondmate home's terminal child ledger lines, PR registrations, captain holds, and merges are published on that same parent route by the scripts that record them, so no captain-facing outcome depends on the mate model appending it ([secondmate-parent-channel.md](secondmate-parent-channel.md)).
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
Each `fm-wake-drain.sh` presentation runs the same liveness guard as the supervision scripts, so a lapsed watcher chain surfaces even on a turn that only handles queued wakes.
Routine watcher polling, supervision no-ops, elapsed waiting time, and absorbed benign wakes stay silent.
A declared external wait or verified captain-held transfer trades that silence for one bounded recheck per pause window, naming which human the wait is on, so neither a forgotten pause nor a forgotten hold can remain invisible indefinitely.
Crew status files are append-only wake-event logs, not current-state fields.
Because of that, a per-wake read of only the latest line can bury an earlier still-open `needs-decision`/`blocked` under later unrelated appends; `fm-wake-drain.sh` prints a separate, fleet-wide OPEN DECISIONS section on every presentation (including the empty-queue path session-start relies on), built through `fm-classify-lib.sh`'s cursor-backed incremental scan using the authoritative `status_open_decisions` fold semantics so the buried decision keeps surfacing until it is explicitly resolved while each presentation folds only new status-log appends.
The drain coordinates that fold and its annotations through a locked fleet-wide snapshot whose `.status-presentation-cursor` manifest records each status file's identity plus independent annotation and outcome-backstop byte offsets.
[`pi-supervision-branch.md`](pi-supervision-branch.md#lost-wake-outcome-backstop) owns the bounded lost-wake backstop that uses the latter offset.
A queued signal annotation prints every status line still unread at that cursor, while the fleet-wide UNREAD STATUS section prints `note:` lines and reserved-key pending-reply resolutions once even on an empty-queue drain because those verbs never enter the OPEN DECISIONS fold.
A third bounded section, RECORD DIVERGENCE, prints on the same drains for the opposite failure: the status fold went quiet on a key that the durable captain-held task still shows as open, so the status side reads as complete while the two records contradict each other; `bin/fm-captain-hold.sh diverged` decides what counts and closes nothing, and `docs/captain-hold-lifecycle.md` owns the mechanism.
A failed read, output, or concurrent-replacement check prevents the snapshot cursor from advancing across uncertain bytes, and teardown retires a task's manifest row before that task ID can be reused.
The explicit resolution is written by the actor that answers, not the busy worker: `fm-send`'s `--resolve-key` appends the closing `resolved` line to this home's own copy of the ledger at answer time, which covers crewmates, local secondmates, and remote secondmates identically because a remote mate's escalations reach that local copy through the parent-replies ingest and only the answer message itself crosses the transport.
This home's answerer close, pending-reply escalation close, and captain-held transfer use the provenance-guarded append owned by `bin/fm-wake-lib.sh`, so they advance the watcher marker only across their own bytes when all earlier bytes were already announced; pending or interleaved foreign bytes fail toward an ordinary wake.
A turn-ended-only queue row omits its historical status annotation when that status file exactly matches the same seen marker.
Any direct or remaining historical annotation prints every status line unread at the presentation cursor instead of replaying only the latest line.
`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes an active or terminal no-mistakes run under the shared run-attribution contract, then keeps that run-step authoritative even if the pane has closed, except that a `blocked:` event reporting a refused or missing daemon socket outranks a potentially stale active run record.
For other daemon, timeout, or unreachability claims, a running or fixing run with recent pipeline-reported activity supersedes the event and names reattachment as the recovery instead of surfacing a false block.
[`bin/fm-nm-run-lib.sh`](../bin/fm-nm-run-lib.sh)'s header owns the exact branch, head, pipeline-custody, and newest-first attribution rules.
A run head the task copy cannot resolve locally is attributed only when the pipeline's own runs ledger proves it is an active continuation of the submitted head, so a pipeline fix round never reads as an older failed run.
During no-mistakes' `ci` monitor phase, it also reads the ci step log tail because `axi status` reports both "still waiting on checks" and "checks green, waiting on merge" as `ci,running`.
The most recent recognized ci log marker wins, so checks-green monitoring reports done while a later re-arm, failed-check, or issue marker returns the crew to working.
A terminal failed run whose only failure is the ci monitor step, after every substantive step completed and the same marker reads checks green, also reports done with the run's PR URL, because a monitor whose only remaining job is to observe a human merge decision must not convert the absence of that decision into a failure verdict.
In the coarse runs-ledger fallback, which has no steps table and no ci log, a terminal failed record whose daemon an explicit `daemon status` probe proves down reports unknown as unverified instead: an instrument failure must never read as work failure.
Only when no matching run exists does it consult semantic busy state; exact busy reports working, exact idle permits fallback to a status-log event whose verb maps to a recognized run-state, and unknown or a dead pane stays unknown instead of trusting a stale log.
Decision-only events such as `resolved` never become current state or leak their prose into the current-state detail.
In that status-log fallback, a declared external wait reports the distinct `paused` state with its reason.
The semantic branch reports working only on an exact busy verdict and names the source that produced it; an unknown verdict never becomes working, never permits the status-log fallback, and never becomes a silent idle.
For whole-fleet review, `bin/fm-fleet-snapshot.sh --json` emits schema `fm-fleet-snapshot.v1` from the backlog, task metadata, local current crew state, supervision-owned endpoint evidence, PR/report pointers, scout reports, bounded current summaries from registered secondmate homes, and secondmate return-channel guidance.
Each home atomically publishes that bounded home summary with freshness epoch metadata at `state/home-summary.json` after a locked session start, a watcher-observed status change, task spawn, task teardown, and on a recurring live-watcher cadence; `bin/fm-home-summary-refresh.sh` owns the publication mechanics.
The fleet snapshot and Bearings paths use the concurrent remote-ledger collection, cache, unreadable-home disclosure, and remote-liveness boundary owned by `bin/fm-fleet-snapshot.sh`'s header.
`bin/fm-fleet-view.sh` renders that snapshot as Markdown for humans, while `bin/fm-bearings-snapshot.sh` provides the bounded bearings projection, so both views consume one structured contract instead of reparsing raw fleet files.
The script header owns the exact JSON schema.

On a Pi primary, supervision is default-on: the watcher extension can hand eligible task-local rows from an ordinary actionable wake, plus selected fleet-wide heartbeat reviews, to a persistent in-process supervision conversation while main-only rows remain on the captain-facing path.
The branch handles those rows, stores the outcome durably, and merges it back into main.
A captain-facing outcome persists as one exact, sequence-keyed visible transcript entry and then opens one sequence-keyed processing turn on main, which only main's sequence-bound acknowledgement closes.
[docs/pi-supervision-branch.md](pi-supervision-branch.md) owns row eligibility, dispatch architecture, deterministic outcome delivery, and processing re-presentation, while the generated [Pi supervision protocol](supervision-protocols/pi.md) owns MAIN's merged-event handling and acknowledgement duty; every other harness keeps the wake-to-main path unchanged.

### Registered secondmate current state

A registered secondmate's validated home is the authority for bearings current state because it owns the child metadata inventory, each child's current-state result, endpoint observations, backlog holds and dependencies, keyed unresolved decisions, and recent Done baseline.
The original cross-home projection instead treated the secondmate agent as an ordinary parent task, so an idle secondmate's `fm-crew-state` fallback selected the latest append-only parent status event even when structured state in the registered home contradicted it.
The parent-status contract also required explicit keyed resolution for decisions and blockers but not for a material `working` phase, so a start event could remain unsuperseded after the corresponding home backlog had moved the work to Done.
Generated secondmate charters reject generic receipt or start acknowledgements, key only supervisor-actionable material phase reports, and close an opened phase with a same-key later state or `resolved` event, while the structured home remains authoritative even if that closure is missing.
Cross-home reads validate the seeded identity and operational-directory boundaries and classify unavailable, malformed, or inconsistent structured state as unknown rather than reviving a parent event as current work; `bin/fm-fleet-snapshot.sh`'s header owns collection, cache selection, and unreadable-home behavior.
When only an owned child's current classification is unavailable, the home classification stays unknown while independently trustworthy structured decisions, holds, queued and landed records, endpoint identities, counts, and provenance remain available; every other invalid path stays strict and exposes none of those child-derived surfaces.
A bounded direct-report terminal tail can help diagnose a mismatch by showing that historical parent wording is still visible, but it is untrusted supplemental evidence because scrollback, prompts, copied output, idle shells, and agent prose are not durable state.
The snapshot strips control sequences, retains only capture metadata and literal event-corroboration flags, and never lets terminal evidence override a valid structured classification.
Live GitHub enrichment exists only behind the bearings `--include-prs` opt-in.
Optional Relay integrates with the watcher only after explicit opt-in; [configuration.md](configuration.md#relay-env) owns its generated-artifact and dispatch mechanics.

At session start, `bin/fm-session-start.sh` emits exactly one primary-harness supervision block rendered by `bin/fm-supervision-instructions.sh` from `docs/supervision-protocols/`.
That block owns the live wait shape for the running primary harness: Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Cursor's stop hook parks on the watcher, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`bin/fm-watch-arm.sh` remains the verified arm wrapper for protocols that call it; it forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints an honest `started`, `attached`, or nonzero `FAILED` status.
[`watcher-continuity.md`](watcher-continuity.md#arm-layer-cycle-contract) owns the arm layer's successor, terminal-delivery, re-arm recovery, and typed clean-close failure contract.
The arm layer records one bounded lifecycle row per observed cycle in `state/.watch-cycle-exits.log`; `state/.watch-triage.log` remains exclusively the absorbed-wake debug log.
Pi and OpenCode verify session-lock ownership and launch one singleton successor from their child-close handlers before delivering an actionable wake prompt, with bounded exponential retry for failed restoration.
Claude's `bin/fm-claude-stop-autoarm.sh` hook fires on every Stop and, when the home is eligible and still needs supervision, claims one home-scoped cycle, foregrounds the arm wrapper, and translates actionable closes into exit-2 rewakes.
It suppresses failed-looking closes when the same identity-matched watcher is healthy, retries genuine failures within a bound, and coordinates exhausted failure episodes with the Claude turn-end guard as documented in [`turnend-guard.md`](turnend-guard.md).
[`watcher-continuity.md`](watcher-continuity.md) owns Claude's residual active-turn coverage and watcher-status command-gating boundary.
Cursor's `bin/fm-turnend-guard-cursor.sh` hook is the same between-turns shape in one synchronous step: it parks the awaited `stop` hook on the arm wrapper and translates an actionable close into one `followup_message`, with a generation baton that makes an older park still running after the next `stop` claim stand down instead of leaking a stale duplicate wake.
The existing turn-end guard remains the final backstop for every harness-engine protocol, with pi-signed sharing Pi's protocol, the `--claude` mode cooperating with the auto-arm claim, and Cursor's `--cursor` mode rendering a block as one bounded follow-up because its `stop` step cannot be blocked.
Its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if the primary checkout is tangled or if work, process-event sources, or Relay polling has an unhealthy model-aware supervision verdict; on main it also warns when queued wakes are waiting to be drained.
The drain script calls that guard after presenting the queue; records remain durable until the exact generation-bound acknowledgement printed by the drain succeeds after handling, and main may keep the queued-wakes warning visible until then.
The Pi supervision branch's deliberate queued-wake warning exception is owned by [`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners).
It leads with a prominent bordered tangle banner, while `bin/fm-guard.sh` owns the watcher-down banner and reminder policy so repeated guarded commands stay noisy without reprinting the full banner in the same episode.
On every verified primary harness, tracked hook integration gives the primary session a push-based backstop: when work, a process-event source, or Relay polling needs supervision and no supervision owner provably holds this home with a fresh beacon, blocking-capable Stop hooks block and nonblocking turn-end integrations force one bounded follow-up.
The guard covers the main primary and genuinely marked secondmate homes, exempts child crewmate/scout worktrees, is loop-safe per harness, and is documented in [turnend-guard.md](turnend-guard.md).

A presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) extends this for walk-away supervision: the `/afk` skill starts it through the tracked foreground helper `bin/fm-afk-start.sh`, after which the watcher reverts to daemon-managed one-shot mode and the daemon self-handles routine wakes in bash.
The watcher and daemon share `bin/fm-classify-lib.sh` for captain-relevant status verbs, declared-wait vocabulary (a `paused:` external wait and a verified `captain-held` transfer alike, through one combined predicate), and status-scan primitives.
Terminal verbs remain captain-relevant, while a nonterminal progress verb cannot become terminal merely because its prose contains a legacy free-text token such as `merged`; bare legacy free-text lines remain compatible.
Both supervisors classify the status bytes appended since they last classified that log, never its last line alone, and report every actionable event through the captured endpoint before committing that position.
The watcher's `.seen-*` and `.hb-surfaced-<task>` markers and the daemon's `.subsuper-seen-status-<task>` marker independently track reported file state and successfully classified position, so an unchanged unreadable state reports once without advancing past unread content, while a changed state retries and an unusable position re-reads the whole log.
A keyed `needs-decision` or `blocked` transition accepted by the whole-file decision fold is retired only when that fold proves the exact opening closed, while a reserved-key transition the fold rejects surfaces as a reconciliation signal without becoming an open decision.
The fold remains the sole owner of open/closed semantics, including same-key reopening and reserved-key handling, shared with the durable OPEN DECISIONS surface.
The always-on watcher also uses that library's absorb classification on no-verb signals and first-sighting stale panes before status-log terminality is trusted, while the daemon maintains distinct wedge and declared-wait recheck cadences.
The daemon's declared-wait window ages against the crew's own latest status line rather than against pane busy state, because a declared wait can legitimately hold a pane busy, and only a status append that stops declaring the wait ends that routing and restores wedge detection.
A wake already decorated as a possible wedge does not override the daemon's own declared-wait verdict either, so a declaration keeps its pane on the recheck cadence instead of the wedge cadence.
In away mode, seen-status dedupe does not clear possible-wedge aging for nonterminal progress, so housekeeping still re-escalates an unchanged idle pane at the configured bound.
Away-mode housekeeping has no worktree-write deferral of its own, so while `state/.afk` exists a quiet crew that is writing its own worktree still escalates as a possible wedge at that bound.
The daemon escalates captain-relevant events, plus a bounded recheck for a declared pause or a verified captain-held transfer that is still declared, naming which human that wait is on, as one batched, single-line digest using the canonical `away-supervisor` kind from `bin/fm-operational-input.sh` so firstmate can distinguish it structurally from real messages.
Its supervisor injection path supports tmux and herdr panes, with `FM_SUPERVISOR_BACKEND` and `FM_SUPERVISOR_TARGET` resolved independently from the task-spawn backend.
Pane existence, busy checks, composer checks, capture, and verified submit route through `bin/fm-backend.sh`: tmux keeps the same submit core used by the tmux send backend, while herdr uses native agent-state submit confirmation on idle baselines, a composer empty fallback when native stays idle, and a pre-Enter rendered-footer transition when that baseline is unavailable.
The retries-exhausted queued-Enter decision is owned by `fm_composer_queued_enter_verdict` in `bin/fm-composer-lib.sh`; tmux and herdr provide only their backend-specific busy signals.
Composer classification has one shared owner, `bin/fm-composer-lib.sh`: tmux, herdr, Zellij, Orca, and cmux contribute only a screen capture plus declarative styled, cursor, identity, and row capabilities, while the shared classifier owns every shape and the `empty`/`pending`/`pending-unproven`/`unknown` verdict.
`fm-spawn.sh` also routes Kimi launch readiness through that classifier instead of carrying another shape copy.
The daemon injects only into an affirmatively `empty` composer, so every other or future verdict defers; positive container proof is required, and a blank unidentified row or bare dead-shell prompt cannot receive an escalation.
The current operator boundary is in [Composer and injection safety](herdr-backend.md#composer-and-injection-safety).
Unsupported supervisor backends refuse at daemon startup.
Stalled escalation delivery writes `state/.subsuper-inject-wedged` and attempts a configured backend-independent active alert after `FM_MAX_DEFER_SECS` instead of silently deferring forever.
On an unmarked return, `bin/fm-afk-return.sh` owns ordered shutdown, durable catch-up evidence, and the fail-closed gate that keeps ordinary work behind every live firstmate-actionable blocker.
`fm-send.sh` delivers every remote text steer and ordinary local text steer as a durable steering-inbox record plus a best-effort constant doorbell line (`bin/fm-task-inbox-lib.sh`).
The doorbell line is a shell no-op and is never typed into an endpoint classified as dead or missing; that record surfaces once for recovery instead of walking the re-ring ladder (`bin/fm-task-inbox-lib.sh` header).
Its local-only typed plane - harness-native invocations and explicit backend targets - selects a pre-Enter popup-settle for slash commands and for codex `$...` skill invocations using metadata-routed target `harness=` values, then adds its own `FM_SEND_SETTLE` pause after successful typed sends so immediate peeks catch the receiving turn starting; the sub-supervisor uses only the shared submit core and does not pay that post-submit pause.

Text for a worker to read and commands that drive a worker's process are separate planes.
`fm-send.sh` is the data plane and always routing-marks a `kind=secondmate` target, which is right for a message and wrong for a lifecycle command, because a marked exit command arrives as chat the agent reasons about instead of executing.
`bin/fm-control.sh` is the control plane: an allowlisted `interrupt`, `exit`, and transactional `relaunch` addressed to an exact task id, with per-harness mechanics owned by `bin/fm-control-lib.sh`, a verified postcondition per verb, and no arbitrary-text or raw-key entry point.
[`docs/agent-control.md`](agent-control.md) owns the verb contract, the capability matrix, the relaunch transaction, and the fail-closed boundaries.

## Busy state is semantic, per adapter

`bin/fm-busy-lib.sh` is the single owner of what "this worker is busy" means, and `bin/fm-busy-event.sh` is the only writer of the per-task records it reads.
Every classification returns a verdict of busy, idle, unknown, or dead together with the source that produced it, so a consumer or a diagnostic can never confuse semantic state with a fallback.

Each converted adapter reports its own turn lifecycle through a machine-readable contract the vendor already exposes, rather than through rendered footer text: Pi and pi-signed through the Firstmate-owned extension's `agent_start` and `agent_settled` confirmed by `ctx.isIdle()`, OpenCode through its plugin's semantic `session.status`, Claude through owned `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd` hooks, Muse through its session log, and Cursor through its conversation transcript.
Kimi behind Pi inherits Pi's lifecycle.
Codex and standalone Kimi classify unknown behind explicit probes until a semantic source is live-verified for them, and Grok keeps one clearly isolated rendered-tail fallback that can only ever classify a Grok task.

Missing, malformed, stale, untrusted, or unverified semantic state is unknown, never idle, and unknown is never promoted to busy either.
Ordinary task-state consumers act only on an exact busy verdict, so an unreadable worker surfaces for a closer look instead of being absorbed as still-working or written off as finished.
Endpoint death is the only process-level override and yields dead; child processes, CPU, process sleep state, and marker modification times are not state signals.
`state/<id>.turn-ended` files remain wake notifications, not current state.

Each record is bound to an incarnation token minted when the task's wiring is armed, so an event from a superseded incarnation is rejected rather than applied, and a record left behind by one classifies unknown.
Three rendered-text checks deliberately remain outside this contract because they answer delivery questions: submit acknowledgement and the away-mode supervisor-pane busy guard consume the shared delivery-footer matcher owned by `bin/fm-composer-lib.sh`, while `bin/fm-pending-reply-lib.sh` owns the secondmate delivery-confirmation observation.
All are harness-scoped rather than a global pattern union, and none is a recorded worker state source.

## Runtime session backends

The runtime backend is the session-provider layer below firstmate's scripts.
It owns task endpoint creation, bounded capture, text/key sends, current-path reads for spawn-time worktree discovery when the backend does not create the worktree itself, live-window fallback lookup, agent-process liveness probes where verified, and endpoint teardown.
`bin/fm-backend.sh` centralizes backend selection, `state/<id>.meta` helpers, metadata-only cleanup identity validation, selector resolution, and operation dispatch; `bin/backends/tmux.sh` is the default reference adapter ([`docs/tmux-backend.md`](tmux-backend.md)), `bin/backends/herdr.sh` (P2) has its own required CI lane ([`docs/herdr-backend.md`](herdr-backend.md)), and `bin/backends/zellij.sh` (P3), `bin/backends/orca.sh` (P4), and `bin/backends/cmux.sh` (P5) remain experimental task-spawn adapters with no dedicated real-backend CI lane.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns new-spawn backend selection precedence and authorization.
Runtime auto-detection is innermost-first: `$TMUX` wins over `HERDR_ENV=1`, which wins over cmux's primary `CMUX_WORKSPACE_ID` marker and documented fallback signals; auto-detected herdr or cmux prints a one-time opt-out notice, auto-detected tmux stays silent, and zellij and orca are never auto-detected (only explicit selection).
Unknown backend names fail loudly.
For compatibility, default tmux tasks do not write `backend=tmux`; every reader treats a missing `backend=` field as `tmux`.
`fm-watch.sh` decides each window's busy state through the semantic contract above rather than by polling the backend for rendered text.
Herdr's native `agent.get` verdict still participates, but only as evidence of activity: a native `busy` is accepted when the task has no record of its own, while a native `idle` is not, because `agent.get` reports generation state and reads idle while a worker blocks on its own long-running foreground tool call.
tmux, zellij, orca, and cmux expose no native busy primitive at all, so a task on those backends is classified purely from its adapter's own lifecycle record.
That poll loop is still the default event source for backends with no native push events, so this stays an extraction of the abstraction rather than a watcher rewrite.
For capable Herdr sessions, the same watcher replaces its terminal sleep with a bounded native event wait that immediately surfaces `blocked`; [Push events and polling fallback](herdr-backend.md#push-events-and-polling-fallback) owns the current mechanism and capability gates, while [runtime backend verification](verification/runtime-backends.md#native-blocked-event) owns the active evidence.
The deeper session-start agent-process liveness probe is separate from that busy-state poll: tmux and Herdr have verified classifiers for secondmate recovery, Zellij remains unverified, and Orca and cmux do not support secondmate spawns.
Herdr can be selected explicitly or by runtime auto-detection: Treehouse remains its worktree provider, [`herdr-backend.md`](herdr-backend.md) owns current setup, CI coverage, and safety limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) owns active empirical evidence.
Herdr uses one tab per task; [Watching and task containers](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, and recovery scope.
Its default-on presentation projection may place one clean new task in a disposable workspace without changing endpoint authority or lifecycle ownership; [Presentation spaces](herdr-backend.md#presentation-spaces) owns that conditional design, the Herdr version floor its unconfigured default is gated behind, and its narrow home-local restored-shell cleanup at locked session start.
Zellij is experimental and selected only explicitly: Treehouse remains its worktree provider, [`zellij-backend.md`](zellij-backend.md) owns current setup and limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#zellij) owns active empirical evidence.
Zellij's container shape is simpler than herdr's: one shared `firstmate` session, one tab per task, with no per-home workspace split; visible tab titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path.
Orca is experimental and selected only explicitly: Orca owns both worktree and terminal lifecycle, records `orca_worktree_id=` and `terminal=`, and removes worktrees through `orca worktree rm` only after the usual firstmate teardown checks pass.
[`orca-backend.md`](orca-backend.md) owns current behavior and limitations, while [`verification/runtime-backends.md`](verification/runtime-backends.md#orca) owns active smoke evidence.
cmux is experimental, GUI-first, macOS-only, and can be selected explicitly or by runtime auto-detection from its primary `CMUX_WORKSPACE_ID` marker plus documented fallback signals: Treehouse remains its worktree provider, [`cmux-backend.md`](cmux-backend.md) owns current setup and limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#cmux) owns active source and live evidence.
cmux's container shape is one workspace per task with one surface, no per-home container split; workspace titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path, and `--secondmate` spawns are refused, mirroring Orca.
Codex App support is recorded in `docs/codex-app-backend.md`; it is not selectable as a runtime backend.

## Worktrees, not branches in your checkout

Crewmates never intentionally touch your project clone; [treehouse](https://github.com/kunchenguid/treehouse) pools clean worktrees for tmux, herdr, zellij, and cmux tasks, while Orca creates its own worktrees for `backend=orca`.
The [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns ship/scout worktree isolation and fresh-base refusal rules, including spawns from linked homes.
Portable regressions live in [`tests/fm-spawn-pool-base-freshen.test.sh`](../tests/fm-spawn-pool-base-freshen.test.sh) for spawn isolation and base freshness, and [`tests/fm-control-relaunch.test.sh`](../tests/fm-control-relaunch.test.sh) for preserving the recorded copy on relaunch.

The firstmate repo has one extra exposure because it can dispatch crewmates to work on itself.
Its operating checkout (`FM_ROOT`) and the disposable crewmate worktrees are all linked git worktrees of the same repository, so the valid discriminator is branch state, not whether the checkout is linked.
The primary checkout is healthy on its default branch, and linked worktrees or secondmate homes are healthy at detached HEAD.
Only a named non-default branch checked out in `FM_ROOT` is a worktree tangle.

`fm-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`fm-guard.sh` prints the repair command on the next mutable fleet action, while `bin/fm-session-start.sh` reports the same condition through bootstrap as a `TANGLE:` line at session start.
If another live session holds the fleet lock, both surfaces keep the alarm but switch to read-only wording with no repair command.
Ship briefs also tell the crewmate to verify `pwd -P` and `git rev-parse --show-toplevel` before creating `fm/<id>`, then stop with a blocked status if it landed in the primary checkout.

## No-mistakes gate authority boundary

Firstmate's own no-mistakes gate runs agents inside a checkout that also contains the fleet-captain identity in `AGENTS.md`, so gate execution needs an authority boundary separate from ordinary crewmate worktree isolation.
The tracked `.no-mistakes.yaml` sets `disable_project_settings: true`; no-mistakes honors that setting only from the trusted default-branch copy, so a pushed branch cannot enable its own project instructions during validation.
Independently, `fm-spawn.sh`, `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` source `bin/fm-gate-refuse-lib.sh` and exit with status 3 before fleet mutation when the gate environment marker is present or the current checkout matches the default no-mistakes gate-repository topology.
A normal primary checkout or crewmate worktree has neither signal and remains unaffected.
The helper's header owns the exact signal detection, relocated-home limitation, test-harness bypass, and relationship to no-mistakes' HEAD-continuity guard.

## Two task shapes

Ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks leave standalone investigation reports at `data/<id>/report.md` and never push.
The intake and authority contract in `AGENTS.md` owns when separate scout research is warranted.

## Dispatch profiles

Crewmate and scout dispatch can stay on the static crewmate harness resolved by `config/crew-harness`, or it can use local dispatch profiles in `config/crew-dispatch.json`.
The dispatch file is intentionally judgment-based: firstmate reads the natural-language rules at intake, chooses the best matching rule, resolves profile arrays itself from current quota output under the `AGENTS.md` section 4 intake boundary and the `quota-array-dispatch` selection procedure, and passes only concrete `--harness`, `--model`, and `--effort` axes to `fm-spawn.sh`.
The shell scripts validate the JSON shape and verified harness/effort combinations, but they do not parse task intent, match natural-language rules, or own array selection.
The session-start bootstrap step keeps valid dispatch configuration silent unless verbose facts are enabled and surfaces a concise invalid-config line when validation fails.
When the file exists, `fm-spawn.sh` refuses crewmate and scout launches without an explicit harness, so `config/crew-harness` is only automatic when no dispatch profile file is active.
Secondmate launches are exempt because they resolve the secondmate harness and any optional secondmate model or effort tokens instead.
Unsupported effort values are still recorded in task meta when passed to `fm-spawn.sh`, but the launch template omits any effort flag that the selected harness does not accept.
That keeps spawn launch compatible across claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, gemini, muse, and rovo while preserving the requested profile for later audit.

## Optional secondmates

`data/secondmates.md` records persistent secondmates with natural-language scopes, project clone lists, and home paths.
A local route points directly at its home, while a remote route adds an SSH alias and remote Firstmate code root so the entire home and all of its child work stay on that host.
Remote placement pins the remote second-mate agent to Herdr while leaving the remote home's worker backend selection independent, and every non-doctor primary-to-remote `fm-on` command runs through the remote account's Firstmate-owned job worker rather than its SSH process or a Herdr pane.
[`remote-secondmates.md`](remote-secondmates.md) owns current setup, supplied-origin provisioning, transport, relay, failure, and retirement behavior.
`fm-home-seed.sh` provisions a local isolated home, clones the listed PR-based projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and `fm-spawn.sh --secondmate` launches it through the same session-provider and status-file path as any direct report.
For a domain whose subject is the firstmate repo itself, a deliberate `--no-projects` seed creates a project-less home whose crews take pooled worktrees of that repo instead of separate clones.
The signal cannot be mixed with project names or omitted accidentally, and a populated home cannot be converted in place; the full seed contract is in [configuration.md](configuration.md#secondmate-routes-datasecondmatesmd).
Herdr secondmate and child placement follows the launcher-binding contract in [Watching and task containers](herdr-backend.md#watching-and-task-containers).
When seeded with `-`, the home is a durable treehouse lease under the secondmate id, so it survives with no live process and is not recycled by later `treehouse get` or pruning.
Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
If returning the lease fails during teardown, firstmate leaves the route and home intact instead of hiding a still-held lease.
Seeding is transactional: if validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
`local-only` projects stay with the main first mate because they merge into the main local checkout instead of a remote-backed PR path.
The same project may appear in multiple secondmate homes when their scopes differ, such as issue triage versus feature development.
Secondmates are idle by default: after startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
When called with `FM_HOME=<this-firstmate-home>` or when `FM_HOME` is already set to the active firstmate home, metadata-routed `fm-send.sh` requests to a live `kind=secondmate` use the live-charter-compatible `from-firstmate` carrier owned by `bin/fm-operational-input.sh`, so the secondmate returns terse answers through status lines and detailed answers through docs plus status pointers instead of replying only in its own chat.
The parent guards every reply-bearing marked request against a missing correlated report without reading the secondmate conversation; `bin/fm-pending-reply-lib.sh` owns the correlation, recovery, escalation, and retention contract, while `bin/fm-send.sh` owns the explicit fire-and-forget exception.
Explicit backend-target sends and direct human typing stay unmarked, so captain intervention in a secondmate pane remains conversational.
After seeding a secondmate, `fm-backlog-handoff.sh` validates the fleet-specific handoff, atomically delegates already-judged in-scope queued item moves to `tasks-axi mv`, and then sends a marked routed-work wake through the receiver's recorded endpoint.
A durable move with a missing, failed, or unresolved wake is reported as failure rather than success; rerunning the same handoff recovers known-undelivered wake intent without moving the item again, while an unresolved delivery is never blindly resent.
Remote routes move that dependency-closed set into a non-dispatchable backlog-format outbox before transfer, then use an idempotent remote receive under the destination backlog's own lock and retain the outbox until the receiver wake is confirmed.
The script header owns the wake correlation and recovery mechanics; `tests/fm-backlog-handoff.test.sh` and `tests/fm-remote-backlog-handoff.test.sh` pin the local and remote delivery boundaries.
An unreachable remote host is unknown rather than dead, preserves its route and durable work, and is never failed over or relaunched locally.
Idle secondmate panes are healthy; teardown is explicit and refuses while the secondmate home has in-flight work unless the captain has approved discard with `--force`.

Secondmate homes converge conservatively to the primary's version and declared inherited local material at launch and during locked session start.
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns the full guarded sync, propagation, nudge, and mid-session local-material push contract.

Secondmate agents can run on a different verified harness than crewmates.
`config/secondmate-harness` controls the primary's secondmate launch harness and may also carry optional model and effort tokens as `<harness> [<model>] [<effort>]` on the first non-empty, non-comment line.
A bare harness line remains harness-only, so existing `config/secondmate-harness` files keep their previous behavior.
When the harness token is unset or `default`, launch falls back to `config/crew-harness`, then to the primary's own harness, and the model and effort tokens are ignored.
Those optional tokens are re-read on every secondmate spawn or respawn and are overridden by explicit per-spawn `--model` or `--effort` flags.
For a local route, an explicit per-spawn harness or raw launch command does not inherit model or effort tokens from `config/secondmate-harness`.
Remote routes accept verified harness adapters only and reject raw launch commands.
`config/crew-harness` remains the crewmate harness and is inherited into secondmate homes.
`config/crew-dispatch.json` is inherited too; secondmates use the same natural-language dispatch profiles when spawning their own crewmates.
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns the inherited-local-material propagation contract and points to the implementation's item declaration.

The `data/secondmates.md` line contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), and the secondmate environment variables are documented in [configuration.md](configuration.md).

## Delivery modes are explicit per task

`no-mistakes` tasks run the full validation pipeline, `direct-PR` tasks open PRs without that pipeline, and `local-only` tasks stay local until firstmate performs an approved fast-forward merge.
Each task's mode and `yolo` merge posture are firstmate's decision at intake.
The mode is passed explicitly to `bin/fm-brief.sh`, and both values are passed explicitly to `bin/fm-spawn.sh` and `bin/fm-promote.sh`; each command refuses to guess the values it consumes.
A ship brief records its mode as a fixed machine-readable line and the spawn refuses to launch on a different one, so the worker's instructions and the recorded task delivery cannot diverge.
`bin/fm-dod-lib.sh` is the one owner of that mode's definition of done, rendered both into a generated ship brief and into the ship instructions a promoted scout receives, so a promoted worker cannot be handed a weaker contract than a briefed one.
It is also the one owner of the no-mistakes `--intent` contract those workers follow.
`data/projects.md` records each project's standing posture and optional `+yolo` merge flag as the captain's default and as context for that decision, including the conditional `no-mistakes-prod-only` policy; a ship spawn that drops below the registered rigor prints a deviation notice and continues.
`bin/fm-project-mode.sh` remains the one registry parser for the mechanical consumers that have no task in hand: fleet sync's `local-only` skip and home seeding's refusal and no-mistakes initialization.
When a selected delivery path calls for a diff, `bin/fm-review-diff.sh` refreshes the authoritative base and, when task meta records `pr=`, always fetches and compares against `refs/pull/<n>/head` by default (recorded `pr_head=` is only an offline fallback) before falling back to the local branch with a warning.
Where a no-mistakes pipeline stores evidence in the repo, it publishes that PR-viewable validation evidence to an orphan evidence branch that shares no history with code branches, so it never enters the crew branch or the default branch.
This repo uses that setting, and its own `.no-mistakes/` directory remains local state that stays gitignored and is rejected by CI if tracked; [`configuration.md`](configuration.md) owns the setting.
PR-based task merges go through `bin/fm-pr-merge.sh`, which records `pr=` and any available `pr_head=` through `bin/fm-pr-check.sh` before calling the forge CLI.
The helper requires a full canonical URL and rejects malformed URLs or repo override flags before recording merge state.
A `https://github.com/<owner>/<repo>/pull/<n>` URL invokes `gh-axi pr merge <n> --repo <owner>/<repo>`, defaults to `--squash`, and preserves explicit merge-method flags.
A `https://<host>/<path>/-/merge_requests/<n>` URL (see [docs/gitlab-merge-watch.md](gitlab-merge-watch.md)) invokes `glab mr merge <n> -R https://<host>/<path>`, so the instance comes from the URL, and adds no merge-method flag because the project's own merge method applies.
That path merges only after one live read of the merge request confirms it is open, mergeable, conflict-free, with blocking discussions resolved and a successful pipeline at the current head, and it binds the merge to that verified head; recorded metadata is never the authority for those conditions because a rebase leaves it stale.
After either forge command returns, the script confirms the PR or MR actually landed, and only a confirmed landing records a landed outcome; a queued or unconfirmed request records none and leaves its poll armed.
On GitLab an auto-merge-queued or unconfirmed request is reported without failing the run.
On GitHub an outcome that is neither merged nor queued is refused loudly and non-zero, naming the observed state, and a base branch that requires the merge queue is refused with the concrete retry flags its configured method requires rather than having a merge method chosen on the caller's behalf.
When the forge already accepted exactly those flags and the pull request still has not entered the queue, that refusal points at the queue state to re-check instead of echoing back the flags the caller just ran.
An auto-merge request is held to the same standard: `--auto` that leaves the pull request neither merged nor queued is refused rather than reported as success.
Every GitHub refusal states what it could not observe as plainly as what it did, so an unreadable branch-rule response, an unrecognised queue method, and a merge queue no available read can see are each named rather than left to look like a base branch with no queue at all.
A confirmed merge leaves a durable role-routed outcome instead of living only in the merging agent's memory, and [`bin/fm-merge-outcome-lib.sh`](../bin/fm-merge-outcome-lib.sh)'s header owns its destination, shape, identity, normal-case deduplication, and at-least-once recovery.
The same emitter handles a merge firstmate performed and one its poll detected, while the watcher immediately delivers the emitter's local actionable poll row.
Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
Before the worktree is returned, teardown concludes the task's own no-mistakes run when it is parked at a gate, including a run whose head the task copy cannot resolve - the shared runs-ledger continuation proof is the only recognition for that case, so cleanup never orphans a parked run the pipeline advanced past the submitted head.
[`bin/fm-teardown.sh`](../bin/fm-teardown.sh)'s header owns the landed-work proofs, PR-discovery fallback, pre-teardown run conclusion, and stale-lock recovery procedure.

## Optional Relay

Relay is opt-in presence for the shared `@myfirstmate` bot on both public surfaces it supports, X and Discord.
A user enables it by putting `FMX_PAIRING_TOKEN` in the firstmate home's gitignored `.env`; `FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`.
That token is standing authorization for firstmate to answer public mentions and act autonomously on normal reversible mention requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while its surrounding conversation context may still include other public accounts.
On the locked session-start bootstrap step, that token creates the local polling and watcher-cadence artifacts described in the [Relay configuration reference](configuration.md#relay-env).
Without the token, the locked session-start bootstrap step removes those artifacts on opt-out and otherwise stays silent, so non-Relay users see no behavior change.
Newly offered mentions are stored as `state/x-inbox/<request_id>.json` and wake firstmate once per retained request ID; the [Relay configuration reference](configuration.md#relay-env) owns the durable offer-marker and re-offer contract.
Attached media stays in that stashed payload as URLs the responding agent fetches and views with its own tools, so the polling path itself never downloads third-party content.
The `fmx-respond` agent-only skill drains that inbox, uses the preserved Relay conversation context for continuity under the wire contract owned by the [Relay configuration reference](configuration.md#relay-env), classifies each mention as an actionable request, question, or pure acknowledgment, and submits public-safe replies through `bin/fm-x-reply.sh`.
When a reply has a real visual artifact, `--image <path>` attaches one local PNG, JPEG, GIF, WebP, BMP, or TIFF to the relay's optional `{media_type,data_base64}` image object.
Actionable reversible requests run through firstmate's normal intake, backlog, dispatch, investigation, or ship lifecycle.
Work that completes in the answering turn gets one outcome reply.
Work that spawns a longer-running task gets an acknowledgement reply first; `bin/fm-x-link.sh` records `x_request=`, `x_request_ts=`, `x_followups=0`, and optional reply-platform context in that task's `state/<id>.meta`, while durable per-request context preserves the original platform and budget independently of task links and inbox cleanup.
That link therefore reaches only work whose task record lives in the answering home; work routed to a secondmate is bound instead by a typed promised-final commitment registered with `--work-home secondmate:<id>`, and `bin/fm-x-link.sh` refuses a non-local task with that path named rather than leaving the public promise unbound.
Later milestone wakes use `bin/fm-x-followup.sh` to post up to three public-safe follow-ups through the relay's `connector/followup` endpoint, ending with a `--final` one for ordinary Relay-linked work.
A typed promised-final commitment owns its terminal reply through `bin/fm-public-followup.sh`; after its receipt is validated, that owner asks the bound work home to remove any legacy link without posting another reply, routing a REMOTE secondmate clear through its SSH transport with the registration's Relay request identity as the mutation guard.
The [Relay configuration reference](configuration.md#relay-env) owns the exact context retention, platform-resolution, and fail-safe posting contract.
If recovery relinks the same relay request onto a successor task, `fm-x-link.sh --carry-count <n> --carry-ts <epoch> --carry-platform <x|discord> --carry-max <n>` preserves the consumed follow-up count, original 7-day window, and reply split budget instead of granting a fresh local budget or falling back to the wrong platform.
The follow-up helper forwards `--image <path>` to the same reply client when a follow-up needs an image.
Each follow-up is bounded by a local 7-day window and a 3-post cap; a successful non-final post increments the counter and keeps the link, while `--final`, reaching the cap, the window lapsing, or the relay itself rejecting an exhausted binding all clear it, and the helper is skipped for tasks that did not originate from a Relay mention.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh`, which calls the relay's `connector/dismiss` endpoint and posts no text, then the local inbox file is cleared.
Concise replies stay single unnumbered messages; genuinely long replies are split by the client into bounded, numbered threads using the target platform's reply budget, with `texts` carrying the ordered chunks for the relay.
Splitting preserves fenced-code, paragraph, line, and word boundaries when possible.
If an image is attached to a split reply, the relay puts it on the first/opener message only and leaves later chunks text-only.
For preview testing, `FMX_DRY_RUN` makes `fm-x-reply.sh` and `fm-x-dismiss.sh` skip the public post or dismiss call and record the would-be payload under `state/x-outbox/`, including `texts` when the reply would be a thread and an `endpoint` marker when the preview is a completion follow-up or dismiss, while the rest of the poll -> compose -> would-post loop still succeeds.
Attached images are recorded as compact `{media_type, bytes, source_path}` metadata in dry-run instead of base64 bytes.
Relay remains layered on top of the existing check mechanism without changing its request-handling behavior.

A promised *final* public reply is a stronger commitment than a milestone follow-up, because forgetting it is publicly visible.
It is therefore not carried in conversation memory at all: intake turns it into a typed `kind=public-followup` obligation owned by `tasks-axi public-followup`, and every later step reads that obligation from disk.
The mechanism boundary is deliberately narrow.
`tasks-axi` owns the obligation state machine and is the only thing that validates a terminal result's source home, work id, generation, schema, outcome, and deliverables.
`state/x-context/` remains the only owner of the private full request context.
`bin/fm-x-reply.sh` remains the only thing that posts.
`bin/fm-public-followup.sh` composes those three and adds the activation gate, a private terminal-event inbox, the idempotent delivery sequence, and retained-loop disposition: delivery stamps the registration delivered, `rechain` hands its thread binding to one follow-on obligation, and `retire` is the only close.
Work routed to another home reports a *typed* terminal result through `bin/fm-public-followup-emit.sh`; firstmate never recovers the source home, work id, outcome, or deliverables by parsing a free-form `done:` sentence, and the child never learns the thread.
When that home is a remote secondmate, no local path reaches the owning home, so the result is staged where the work runs and the owning home pulls it over the same SSH route with `bin/fm-public-followup-collect.sh`.
Because a terminal event's id is derived from its identity tuple rather than generated, duplicate reports and restart replay converge without coordination.
Reconciliation rides the existing relay poll and the session-start digest instead of a new watcher, daemon, or timer, and both are gated on the same `.env` activation contract so a home that never opted into the relay executes none of it.
The [Relay configuration reference](configuration.md#promised-public-replies-statepublic-followup) owns the operator-facing contract, and the `fmx-respond` skill owns the procedure.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a real `@AGENTS.md` import pointer.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
Each project `AGENTS.md` carries self-governance guidance; [`bin/fm-ensure-agents-md.sh`](../bin/fm-ensure-agents-md.sh) owns the canonical wording and idempotent insertion, while its header and help document the explicit mark for equivalent project-owned guidance.
It refuses a case-variant real memory file such as a lowercase `agents.md`, so the pointer's `@AGENTS.md` import resolves to a real `AGENTS.md` on a case-sensitive filesystem, and surfaces the mismatch for manual reconciliation.
The full ownership rule - what is project-intrinsic versus fleet-private, and how firstmate keeps the two apart without writing into project clones - is owned by [`AGENTS.md`](../AGENTS.md) (project and knowledge management).

## Operational memory routing

`/stow` sweeps the current session for durable knowledge that only exists in conversation and routes each finding to the most specific disk home.
Home-domain captain preferences go to `data/captain.md`, cross-domain shared captain preferences go to the primary home's `data/captain-shared.md`, fleet-local operational facts and gotchas go to home-local `data/learnings.md`, project-intrinsic knowledge goes through normal crewmate delivery into that project's committed `AGENTS.md`, and task-scoped notes or undone next steps go to the backlog.
Memory writes use inspect-then-update rather than blind append; the internal [`stow` skill](../.agents/skills/stow/SKILL.md) owns tier markers, decay, cold archival, and offload.
The same pass also persists open-work record state the session is holding - filing a thread that was never recorded and correcting one the session knows went stale - bounded to the open work that session is actually holding.
It is deliberately not a reconciliation of durable records against repository or PR reality: its input is the volatile context, so it can only preserve what the session still knows, and no reconciliation that outlives a session exists today.
Task-scoped notes use `tasks-axi show <id> --full` followed by `tasks-axi update <id> --body-file <path>`, adding `--archive-body` when the prior body should remain recoverable.
The stow pass never writes a skill, but a separately executed, captain-approved migration may move conditional knowledge into a user-owned local skill excluded from the Firstmate clone; changes to Firstmate's tracked skills remain deliberate repository work through the normal PR pipeline.
Invoked in a primary home, `/stow` then cascades the same sweep to every registered secondmate, enumerated through `bin/fm-stow-cascade.sh`: each home is accounted and curated against its own startup-memory allowance, a live secondmate sweeps its own session, and a slow or unreachable home is reported as an exception rather than blocking the primary.

## Local clones stay fresh

The locked session-start deferred network stage, PR-based teardown, and merged-PR wake handling refresh remote-backed project clones when the clone is safe to move.
Wake-time refreshes can target a single clone by project name, so the primary home also catches up when a secondmate reports a merge from its own home.
Clean default-branch clones fast-forward to `origin/<default>`, and a clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.
Dirty clones, non-default branches, detached HEADs with unique commits, diverged defaults, and default branches checked out in another worktree are reported as `STUCK:` with their behind count and left untouched.
Fetches blocked by an orphaned `.git/packed-refs.lock` use bounded retries and remove the lock only when the shared staleness proof can prove it abandoned; [configuration.md](configuration.md#toolchain) owns the recovery details and tuning knobs.
Local-only projects, clones without an origin remote, and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin` without touching project clones.
It restarts every live second mate whose home the pass left on the target commit through a persist-gated replacement, including a home that needed no advance, because a restart is also the only thing that re-resolves launch-time harness wiring; the re-read nudge is retained only as the fallback for live agents whose runtime cannot prove a restart.
For a remote route, the configured code root updates from its own origin on that host before the persistent home fast-forwards to the code-root commit.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
Local homes share the guarded fast-forward helper, while remote updates delegate the same safety decision to the configured host through the generic transport.
The procedure and outcome vocabulary are owned by the [`/updatefirstmate` skill](../.agents/skills/updatefirstmate/SKILL.md); the relevant script headers own the mechanics.

## Restart-proof

Fleet state lives in each task's session-provider backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected), no-mistakes run records, status event logs, local markdown under `data/` including `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, and persistent secondmate homes.
For herdr, respawning after a server-restored layout closes and replaces confirmed no-agent or dead task-tab husks instead of requiring manual tab cleanup.
At session start, confirmed-dead secondmate agent endpoints are closed and relaunched through the same secondmate spawn path, while ambiguous liveness reads are left untouched to avoid duplicate supervisors.
Use `/stow` before an intentional reset when the conversation may hold durable knowledge that has not yet been written to disk; after that, the next firstmate session can reconcile and carry on.

## Development notes

The current watcher reliability work combines always-on bash triage with a durable queue for actionable wakes, generation-bound post-handling acknowledgement, deterministic re-arm recovery after watcher downtime, a race-proof singleton lock, duplicate self-eviction, drain-time liveness assertion, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) provides walk-away supervision via the `/afk` skill while reusing the same shared wake classifier as the always-on watcher.
