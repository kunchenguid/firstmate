# Architecture

How firstmate works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
firstmate's always-loaded operating contract and routing index for conditional procedures is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Actionable wakes include captain-relevant status signals, no-verb signals whose crew is not provably working, authenticated check output such as PR merge polling or a Relay mention, stale panes whose crew is not provably working whether their status log looks terminal or non-terminal, provably-working stale panes that persist past `FM_STALE_ESCALATE_SECS`, declared external waits that remain paused past `FM_PAUSE_RESURFACE_SECS`, and heartbeat backstop hits.
Repeated provably-working stale escalations on the same unchanged pane add an escalation count to the wake reason and, at `FM_WEDGE_DEMAND_INSPECT_COUNT`, a `demand-deep-inspection` marker.
A busy pane is otherwise exempt from staleness, but only until its latest `state/<id>.turn-ended` marker reaches `FM_BUSY_TURN_MAX_SECS`, or its `state/<id>.meta` spawn record reaches that age before any turn completes; past that bound it is routed through the same wedge escalation, with the identical reason, escalation count, and `demand-deep-inspection` marker, for inspection only - never an automatic interrupt, signal, or restart.
Those actionable wakes are written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed process exit can be recovered by draining the queue.
When a canonical validated PR poll returns exactly `merged`, the watcher appends that durable notification before publishing a private receipt bound to the poll's registration, bytes, file identities, metadata, provider, URL, and task ID.
The receipt makes retirement safely retryable across restarts: fixed-path recovery revalidates the same evidence, removes the runnable check first, removes its registration and data sidecars, removes the receipt last, and preserves task metadata including `pr=` and `pr_head=`.
A concurrent replacement remains armed, every non-merged or invalid observation remains unchanged, and retirement never performs task or persistent-secondmate cleanup.
`bin/fm-pr-lib.sh` owns the receipt format and strict identity mechanics, while `bin/fm-watch.sh` owns queue-before-retirement ordering.
No-verb wakes, such as `working:` notes and bare turn-ended signals, are benign only when `bin/fm-crew-state.sh` reports positive evidence that the crew is still working: an actively running no-mistakes step attributed to that crew's current code, or an exact busy verdict from the semantic busy-state contract.
A crew that declares `paused:` for a known external wait is separately absorbed while idle and re-surfaced only on the longer pause cadence, rather than being treated as a possible wedge.
For an ordinary crew that has stopped, the normal-mode watcher first surfaces one stale wake, then applies that same cadence to an unchanged `paused:` or durable `captain-held` endpoint only when the backend confidently reports its agent dead.
Live or inconclusive liveness remains fail-open at that initial surface, and the secondmate idle-endpoint exemption is unchanged.
Its initial normal-mode status signal still surfaces through the no-verb path, while away mode self-handles that routine signal and owns the later recheck.
Fresh stale panes use the same current-state read before trusting the status log, so an active run or a proven busy worker outranks an old captain-relevant status-log line left behind before validation.
No-change heartbeats are also benign.
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
After each drain, `fm-wake-drain.sh` runs the same liveness guard as the supervision scripts, so a lapsed watcher chain surfaces even on a turn that only drains and handles queued wakes.
Routine watcher polling, supervision no-ops, elapsed waiting time, and absorbed benign wakes stay silent.
A declared external wait trades that silence for one bounded recheck per pause window, so a forgotten pause cannot remain invisible indefinitely.
Crew status files are append-only wake-event logs, not current-state fields.
Because of that, a per-wake read of only the latest line can bury an earlier still-open `needs-decision`/`blocked` under later unrelated appends; `fm-wake-drain.sh` prints a separate, fleet-wide OPEN DECISIONS section on every drain (including the empty-queue path session-start relies on), built through `fm-classify-lib.sh`'s cursor-backed incremental scan using the authoritative `status_open_decisions` fold semantics so the buried decision keeps surfacing until it is explicitly resolved while each drain reads only new status-log appends.
The explicit resolution is written by the actor that answers, not the busy worker: `fm-send`'s `--resolve-key` appends the closing `resolved` line to this home's own copy of the ledger at answer time, which covers crewmates, local secondmates, and remote secondmates identically because a remote mate's escalations reach that local copy through the parent-replies ingest and only the answer message itself crosses the transport.
`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes a no-mistakes run, active or terminal, only when it matches the crew's branch and current code identity, then keeps that run-step authoritative even if the pane has closed.
The script header owns the exact run-head ancestry rules.
During no-mistakes' `ci` monitor phase, it also reads the ci step log tail because `axi status` reports both "still waiting on checks" and "checks green, waiting on merge" as `ci,running`.
The most recent recognized ci log marker wins, so checks-green monitoring reports done while a later re-arm, failed-check, or issue marker returns the crew to working.
Only when no matching run exists does it consult semantic busy state; exact busy reports working, exact idle permits fallback to a status-log event whose verb maps to a recognized run-state, and unknown or a dead pane stays unknown instead of trusting a stale log.
Decision-only events such as `resolved` never become current state or leak their prose into the current-state detail.
In that status-log fallback, a declared external wait reports the distinct `paused` state with its reason.
The semantic branch reports working only on an exact busy verdict and names the source that produced it; an unknown verdict never becomes working, never permits the status-log fallback, and never becomes a silent idle.
For whole-fleet read-only review, `bin/fm-fleet-snapshot.sh --json` emits schema `fm-fleet-snapshot.v1` from the backlog, task metadata, current crew state, endpoint probes, PR/report pointers, scout reports, bounded current summaries from registered secondmate homes, and secondmate return-channel guidance.
`bin/fm-fleet-view.sh` renders that snapshot as Markdown for humans, while `bin/fm-bearings-snapshot.sh` provides the bounded bearings projection, so both views consume one structured contract instead of reparsing raw fleet files.
The script header owns the exact JSON schema.

### Registered secondmate current state

A registered secondmate's validated home is the authority for bearings current state because it owns the child metadata inventory, each child's current-state result, endpoint observations, backlog holds and dependencies, keyed unresolved decisions, and recent Done baseline.
The original cross-home projection instead treated the secondmate agent as an ordinary parent task, so an idle secondmate's `fm-crew-state` fallback selected the latest append-only parent status event even when structured state in the registered home contradicted it.
The parent-status contract also required explicit keyed resolution for decisions and blockers but not for a material `working` phase, so a start event could remain unsuperseded after the corresponding home backlog had moved the work to Done.
Generated secondmate charters reject generic receipt or start acknowledgements, key only supervisor-actionable material phase reports, and close an opened phase with a same-key later state or `resolved` event, while the structured home remains authoritative even if that closure is missing.
Cross-home reads validate the seeded identity and operational-directory boundaries, use per-home time and output bounds, and classify unavailable, malformed, or inconsistent structured state as unknown rather than reviving a parent event as current work.
When only an owned child's current classification is unavailable, the home classification stays unknown while independently trustworthy structured decisions, holds, queued and landed records, endpoint identities, counts, and provenance remain available; every other invalid path stays strict and exposes none of those child-derived surfaces.
A bounded direct-report terminal tail can help diagnose a mismatch by showing that historical parent wording is still visible, but it is untrusted supplemental evidence because scrollback, prompts, copied output, idle shells, and agent prose are not durable state.
The snapshot strips control sequences, retains only capture metadata and literal event-corroboration flags, and never lets terminal evidence override a valid structured classification.
The default path remains local-only; live GitHub enrichment exists only behind the bearings `--include-prs` opt-in.
Optional Relay integrates with the watcher only after explicit opt-in; [configuration.md](configuration.md#relay-env) owns its generated-artifact and dispatch mechanics.

At session start, `bin/fm-session-start.sh` emits exactly one primary-harness supervision block rendered by `bin/fm-supervision-instructions.sh` from `docs/supervision-protocols/`.
That block owns the live wait shape for the running primary harness: Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`bin/fm-watch-arm.sh` remains the verified arm wrapper for protocols that call it; it forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints an honest `started`, `attached`, or nonzero `FAILED` status.
[`watcher-continuity.md`](watcher-continuity.md#arm-layer-cycle-contract) owns the arm layer's successor, terminal-delivery, and typed clean-close failure contract.
The arm layer records one bounded lifecycle row per observed cycle in `state/.watch-cycle-exits.log`; `state/.watch-triage.log` remains exclusively the absorbed-wake debug log.
Pi and OpenCode verify session-lock ownership and launch one singleton successor from their child-close handlers before delivering an actionable wake prompt, with bounded exponential retry for failed restoration.
Claude's `bin/fm-claude-stop-autoarm.sh` hook fires on every Stop and, when the home is eligible and still needs supervision, claims one home-scoped cycle, foregrounds the arm wrapper, and translates actionable closes into exit-2 rewakes.
It suppresses failed-looking closes when the same identity-matched watcher is healthy, retries genuine failures within a bound, and coordinates exhausted failure episodes with the Claude turn-end guard as documented in [`turnend-guard.md`](turnend-guard.md).
[`watcher-continuity.md`](watcher-continuity.md) owns Claude's residual active-turn coverage and watcher-status command-gating boundary.
The existing turn-end guard remains the final backstop for all five harness-engine protocols, with pi-signed sharing Pi's protocol and the `--claude` mode cooperating with the auto-arm claim.
Its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if the primary checkout is tangled, if work, process-event sources, or Relay polling has an unhealthy model-aware supervision verdict, or if queued wakes are waiting to be drained.
The drain script calls that guard after emptying the queue, which avoids repeating the queued-wakes warning for records it just consumed while still warning on unhealthy supervision.
It leads with a prominent bordered tangle banner, while `bin/fm-guard.sh` owns the watcher-down banner and reminder policy so repeated guarded commands stay noisy without reprinting the full banner in the same episode.
On every verified primary harness, tracked hook integration gives the primary session a push-based backstop: when work, a process-event source, or Relay polling needs supervision and no identity-matched watcher lock with a fresh beacon is live, direct Stop hooks block and passive turn-end hooks force one bounded follow-up.
The guard covers the main primary and genuinely marked secondmate homes, exempts child crewmate/scout worktrees, is loop-safe per harness, and is documented in [turnend-guard.md](turnend-guard.md).

A presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) extends this for walk-away supervision: the `/afk` skill starts it through the tracked foreground helper `bin/fm-afk-start.sh`, after which the watcher reverts to daemon-managed one-shot mode and the daemon self-handles routine wakes in bash.
The watcher and daemon share `bin/fm-classify-lib.sh` for captain-relevant status verbs, declared-external-wait vocabulary, and status-scan primitives.
Terminal verbs remain captain-relevant, while a nonterminal progress verb cannot become terminal merely because its prose contains a legacy free-text token such as `merged`; bare legacy free-text lines remain compatible.
The always-on watcher also uses that library's absorb classification on no-verb signals and first-sighting stale panes before status-log terminality is trusted, while the daemon maintains distinct wedge and declared-pause recheck cadences.
In away mode, seen-status dedupe does not clear possible-wedge aging for nonterminal progress, so housekeeping still re-escalates an unchanged idle pane at the configured bound.
The daemon escalates captain-relevant events, plus a bounded recheck for a declared pause that remains idle, as one batched, single-line digest using the canonical `away-supervisor` kind from `bin/fm-operational-input.sh` so firstmate can distinguish it structurally from real messages.
Its supervisor injection path supports tmux and herdr panes, with `FM_SUPERVISOR_BACKEND` and `FM_SUPERVISOR_TARGET` resolved independently from the task-spawn backend.
Pane existence, busy checks, composer checks, capture, and verified submit route through `bin/fm-backend.sh`: tmux keeps the same submit core used by the tmux send backend, while herdr uses native busy state, native agent-state submit confirmation on idle baselines, and its ANSI-aware structural composer classifier for pending-input guards and submit fallback.
The tmux submit core (shared `fm_tmux_submit_enter_core`) treats a busy pane + retries-exhausted + composer-still-pending as a queued Enter (opencode 1.18.4 accepts Enter mid-turn and queues it for after the turn), reported as `empty` so the daemon and `fm-send` do not re-send; an idle pane keeps the `pending` verdict as a genuine swallow. The same opencode busy-queue case is a known gap on the herdr adapter and is recorded in `docs/herdr-backend.md` rather than patched here.
Composer-content classification has one shared owner, `bin/fm-composer-lib.sh`, used by tmux, herdr, Orca, and cmux after each adapter performs its own capture and composer-row recognition.
The daemon injects only into an affirmatively `empty` composer, so both `pending` and `unknown` defer and a bare dead-shell prompt cannot receive an escalation; the current boundary is in [Composer and injection safety](herdr-backend.md#composer-and-injection-safety).
Unsupported supervisor backends refuse at daemon startup.
Stalled escalation delivery writes `state/.subsuper-inject-wedged` and attempts a configured backend-independent active alert after `FM_MAX_DEFER_SECS` instead of silently deferring forever.
On an unmarked return, `bin/fm-afk-return.sh` owns ordered shutdown, durable catch-up evidence, and the fail-closed gate that keeps ordinary work behind every live firstmate-actionable blocker.
`fm-send.sh` selects a pre-Enter popup-settle for slash commands and for codex `$...` skill invocations using metadata-routed target `harness=` values, then adds its own `FM_SEND_SETTLE` pause after successful text sends so immediate peeks catch the receiving turn starting; the sub-supervisor uses only the shared submit core and does not pay that post-submit pause.

## Busy state is semantic, per adapter

`bin/fm-busy-lib.sh` is the single owner of what "this worker is busy" means, and `bin/fm-busy-event.sh` is the only writer of the per-task records it reads.
Every classification returns a verdict of busy, idle, unknown, or dead together with the source that produced it, so a consumer or a diagnostic can never confuse semantic state with a fallback.

Each converted adapter reports its own turn lifecycle through a machine-readable contract the vendor already exposes, rather than through rendered footer text: Pi and pi-signed through the Firstmate-owned extension's `agent_start` and `agent_settled` confirmed by `ctx.isIdle()`, OpenCode through its plugin's semantic `session.status`, and Claude through owned `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd` hooks.
Kimi behind Pi inherits Pi's lifecycle.
Codex and standalone Kimi classify unknown behind explicit probes until a semantic source is live-verified for them, and Grok keeps one clearly isolated rendered-tail fallback that can only ever classify a Grok task.

Missing, malformed, stale, untrusted, or unverified semantic state is unknown, never idle, and unknown is never promoted to busy either.
Ordinary task-state consumers act only on an exact busy verdict, so an unreadable worker surfaces for a closer look instead of being absorbed as still-working or written off as finished.
Endpoint death is the only process-level override and yields dead; child processes, CPU, process sleep state, and marker modification times are not state signals.
`state/<id>.turn-ended` files remain wake notifications, not current state.

Each record is bound to an incarnation token minted when the task's wiring is armed, so an event from a superseded incarnation is rejected rather than applied, and a record left behind by one classifies unknown.
Three rendered-text readers deliberately remain outside this contract because they answer delivery questions: the submit acknowledgement and away-mode supervisor-pane busy guard in `bin/fm-tmux-lib.sh`, and the secondmate delivery-confirmation observation in `bin/fm-pending-reply-lib.sh`.
All are harness-scoped rather than a global pattern union, and none is a recorded worker state source.

## Durable implementation capacity and attempt lifecycle design

This section specifies the approved target architecture for durable fleet refill and full attempt-to-terminal lifecycle management, and it does not describe behavior that is implemented today.
The design extends the existing worker, Decision OS bead, Git, forge, and cleanup owners instead of adding an independent scheduler or task tracker.
The Decision OS terminal-lifecycle design in `docs/superpowers/plans/2026-08-05-two-writer-delivery-capacity.md` Tasks 7.1 through 7.6 remains the upstream project-specific lifecycle authority, and this section defines how Firstmate composes with it rather than competing with it.

### Design objective and friction budget

The normal operator and worker path must remain dispatch once, work once, reconcile once, and refill automatically.
Ordinary delivery must not gain a manual approval, duplicate tracker update, mandatory ceremony, wrapper, daemon, dashboard, or control plane.
A new mechanism is allowed only when an existing primitive cannot satisfy a named invariant in this section, and the implementation must record that unmet invariant in its review rationale.
The smallest expected shared change set is the existing fleet-refill command, a factored canonical state parser only if the existing parser cannot be reused directly, the spawn success boundary, one durable attempt-record owner, one ordered terminal owner, the existing startup and heartbeat recovery paths, and focused behavior tests.
The private fleet sentinel may change only enough to consume the public projection and retain its local cadence, Decision OS candidate query, logging, and notification policy.
Existing commands must remain backward compatible where practical, with structured modes added beside human output instead of replacing established invocation shapes.
The hot path must publish measured per-worker and whole-projection latency under representative fleet size and timeout conditions before automatic refill is enabled.
The accepted latency budget must keep normal interactive reconciliation responsive and keep periodic observation comfortably below its cadence, while every exceeded bound produces explicit uncertainty rather than fabricated availability.
The implementation plan must name every superseded manifest read, output-path probe, duplicated counter, compatibility shim, and migration-only branch, together with the verification milestone that permits its deletion.
The final cutover is incomplete until that deletion plan has removed obsolete live arithmetic, while historical audit evidence may remain read-only under an explicit retention owner.

### Authority boundaries

The Decision OS beads graph is authoritative for implementation identity, priority, readiness, dependencies, claims and ownership, and closure.
A Firstmate record may cache or project a bead fact for bounded observation, but it must retain source identity and revision evidence and must never override the live graph.
Every Decision OS delivery attempt must bind immutably to one bead ID before provider allocation and must verify that live bead before dispatch, refill selection, terminal reconciliation, and closure.
A missing, stale, malformed, multiply claimed, or contradictory bead observation requires reconciliation and cannot authorize launch, refill, or closure.
Firstmate owns immutable delivery-attempt identity, home and provider ownership, isolated-copy allocation, endpoint observation, semantic worker-state composition, terminal orchestration, capacity projection, and refill execution.
The canonical worker-state owner remains `bin/fm-crew-state.sh`, including attribution of active validation to the exact branch and compatible code identity.
The implementation must reuse or factor that canonical parser rather than create a second worker state machine in the refill command, snapshot command, sentinel, or terminal owner.
Git owns branch, base, head, cleanliness, ancestry, reachability, and ref facts.
The forge owns pull-request identity, source and target identity, exact merge outcome, and available merge-head evidence.
The Decision OS main steward remains the only writer of Decision OS tracker mutations and Closure-Receipts under the Task 7.4 receipt adapter.
The existing cleanup safety primitives remain authoritative for endpoint shutdown, process proof, isolated-copy identity, dirty-state refusal, stale-lock handling, and provider return.
The historical attempt ledger is audit-only and must never be consulted as live capacity truth.

### Immutable attempt identity and records

An attempt is one physical effort to deliver one authoritative implementation item, and it is distinct from both the bead and a Firstmate queue item.
The minimum immutable identity is the task source, authoritative task key, home identity, attempt ID, and generation.
A Decision OS attempt must include its bead ID as the authoritative task key and must never be rebound to another bead.
The attempt must also preserve the provider-copy identity, initial branch, base commit, intended target branch, and delivery mode once those facts are allocated.
Mutable phase and obligation observations may advance under the attempt generation, but a stale generation must never overwrite the current attempt.
The durable record must use the existing low-level locking and atomic-publication patterns so concurrent allocation has one winner and replay converges.
Pending claim, allocation, launch, tracker, landing, preservation, cleanup, branch-fate, queue, and retirement obligations must remain distinct fields rather than being collapsed into a generic status.
The record must persist only immutable identity and the minimum receipts required to recover or replay an obligation safely.
Rendered output, transient process activity, and copied mutable tracker state must not be added merely for convenience.

A Decision OS attempt begins with the claim-before-allocation handshake from the upstream Task 7.4 design.
Firstmate must persist the attempt and an exact `claim_pending` request before allocating a provider copy or launching an endpoint.
The registered Decision OS main steward must verify the live bead, expected prior state and source revision, current authority, and intended bound agent before producing the authoritative claim receipt.
Only a matching current-generation receipt and matching live bead ownership may advance the attempt to `claim_observed` and permit allocation.
A missing, refused, stale, or mismatched receipt leaves the attempt reserved with no provider copy or endpoint and cannot be satisfied retroactively by terminal reconciliation.

A launch is successful only after the runtime-specific launch and required instruction-delivery confirmation have succeeded.
Spawn metadata published before that boundary is recovery evidence, not proof of successful launch.
The audit ledger must append a successful-launch receipt only after that boundary and must use the attempt ID as its idempotency key.
A partial or failed batch must write success rows only for attempts whose individual launch boundary succeeded.
A crash after endpoint launch but before audit publication must be recovered from the durable attempt record, and capacity correctness must not depend on repairing the audit row first.

### One versioned capacity projection

`bin/fm-fleet-refill.sh --count-json` is the sole public home-local implementation-capacity projection.
Human refill output and the private fleet sentinel must consume the same in-process or emitted projection rather than recomputing arithmetic.
The legacy output-path and frozen-manifest model must not participate in current capacity after cutover.
The projection must be produced from a sorted snapshot of current home-local attempt and worker identities and must tolerate a record disappearing or changing during observation without corrupting arithmetic.
The projection must exclude every scout and persistent second mate from implementation capacity, including a second mate's children because those children belong to that second mate's home-local projection.

The JSON document must identify schema `fm-fleet-capacity.v1` and carry an observation ID, observation start and completion times, home identity, completeness verdict, and timeout verdict.
Its `workers` array must carry deterministic per-worker rows sorted by immutable attempt identity, with no ordering dependency on filesystem enumeration or read completion.
Each implementation row must include attempt identity, task source and key, kind, generation, semantic worker classification and source, attempt phase, productive verdict, reserved-ownership verdict, ambiguity reasons, pending obligations, and whether terminal reconciliation is required.
A row may include cached bead identity and revision evidence, but the projection must label that evidence as observed or cached and cannot use a stale cache to authorize refill.
The aggregate must report `productive_count`, `reserved_ownership_count`, `ambiguous_count`, `reconciliation_required`, `observation_complete`, and `refill_safe`.
The aggregate may report target and safe ceiling when policy inputs are supplied, but it must not hide raw counts behind one battery scalar.
Every count must be derivable exactly from the emitted rows under the same schema version.
A schema mismatch must stop automatic refill and preserve ownership.

Productive work means an implementation attempt positively observed in active implementation or attributed active validation.
Productive work is always reserved ownership.
Reserved ownership means an attempt still owns any delivery obligation, whether or not it is currently productive.
Configuring and launching attempts remain reserved until launch success or exact launch-failure reconciliation.
Actionable validation waits, external waits, and explicit blockers remain reserved while their attempt ownership is intact.
Merge-waiting, completed, failed, endpoint-dead, and ambiguous attempts remain reserved until the ordered terminal owner reconciles every outstanding obligation.
A fully reconciled and retired attempt contributes neither productive nor reserved capacity.
A historical audit-ledger row contributes neither productive nor reserved capacity.
A completion notification, stale Firstmate queue entry, cached bead projection, dead endpoint, missing copy, or absent output file must never decrement capacity directly.

Each worker-state read must have a bounded timeout, and each projection must have a separate bounded total timeout.
A timeout, malformed result, torn read, unsupported runtime result, or unavailable authoritative observation must produce an ambiguous row or incomplete observation.
Uncertainty must never be converted into idle, terminal, zero active work, or a free slot.
The projection may parallelize independent reads only after backend concurrency safety, deterministic output, bounded buffering, and total-time behavior are verified for every supported runtime.

The private fleet sentinel must execute this same public JSON interface and parse only versioned fields.
It must not retain fallback arithmetic over manifests, output modification times, metadata counts, worker text, or private shadow fields.
The sentinel may include the observation ID and counts in its logs and notifications, but its local log cannot become capacity authority.
If the projection is incomplete, ambiguous, version-incompatible, or unavailable, the sentinel must return to alert-only behavior and must not report zero capacity.

### Refill decision

Refill evaluates only after the current projection is complete enough to set `refill_safe=true` and after any terminal action in the same flow has reached its persisted retirement boundary.
Refill is eligible when productive work is below the configured target and total reserved ownership is below the configured safe ceiling.
The separation between productive target and reserved ceiling permits useful refill without pretending merge waits or pending terminal work have disappeared.
The safe ceiling is a policy input rather than a fact inferred from worker count.

Candidate selection must query the live authoritative beads graph at decision time.
A candidate must be open, ready, unclaimed, dependency-safe, and high enough priority under the graph's canonical ordering.
The candidate's live identity, claim state, readiness, dependencies, and revision must be verified again when its immutable attempt and claim request are created.
Firstmate must separately prove that the candidate's expected write set and serialization requirements are safe against every active or reserved attempt.
Bead readiness does not imply write-set safety, and Firstmate write-set safety does not override bead ownership or dependencies.
If either authority cannot prove its part, the candidate is not dispatched.

The normal fast path performs one projection, selects only the deficit permitted by target and safe ceiling, creates each attempt through claim-before-allocation, launches each accepted attempt once, and publishes a fresh projection after successful launches or reconciled failures.
A failed launch remains reserved until its exact pending provider, endpoint, branch, and tracker obligations are reconciled.
Concurrent refill runs must serialize on existing home and attempt locks, re-read authoritative candidate ownership after winning the lock, and converge without duplicate dispatch.

### Drift and contradiction handling

Drift is any disagreement among the live bead, Firstmate queue record, durable attempt, semantic worker observation, provider copy, Git branch or head, forge result, tracker receipt, or cleanup receipt.
Drift must set `reconciliation_required=true`, and material identity or ownership drift must set `refill_safe=false`.
The reconciler must retain every independently trustworthy fact and identify which authority owns the disputed transition.
It must never resolve disagreement by dispatching another attempt, copying cached tracker state into the bead, marking the bead complete, deleting an isolated copy, deleting a branch, or converting the row to zero capacity.
A stale Firstmate queue item may be corrected only after the corresponding attempt and authoritative bead disposition are proved.
An active attempt absent from the queue remains reserved and must be restored or reconciled rather than ignored.
A bead closed while an attempt remains active requires terminal reconciliation and cannot justify destructive cleanup by itself.
A bead open after proven product landing remains open until the Decision OS receipt path truthfully closes it.
Multiple attempts or claims for one bead require ownership reconciliation before any one of them may launch, close, retire, or trigger refill.

### Ordered terminal owner

`bin/fm-terminal.sh` is the sole Firstmate attempt-to-terminal orchestrator and composes the upstream Decision OS Tasks 7.4 through 7.6 design with existing Firstmate safety primitives.
It must not select new work, maintain a second cleanup policy, or mutate the Decision OS tracker directly.
It must acquire the exact attempt lock and replay from persisted observations and receipts so a crash after any step converges without repeating a completed mutation.
Only full retirement removes reserved ownership, and refill runs only after a new projection observes that retirement.

The terminal owner must perform these ordered responsibilities for the exact attempt.

1. It must verify immutable attempt identity, generation, home, authoritative task key, and bound Decision OS bead.
2. It must verify the live bead and record any disagreement with the cached Firstmate queue or claim evidence.
3. It must observe and persist the exact runtime endpoint, provider copy claim, initial branch, base, current branch, current head, target, delivery mode, and relevant local and remote refs.
4. It must observe and persist the exact forge repository, pull request, source, target, head, and open, merged, closed-unmerged, or unknown result when a forge applies.
5. It must classify product disposition as `landed`, `preserved_unlanded`, or `unknown` from exact evidence.
6. It must obtain any required disposition authority without inferring approval from a completion event, tracker state, or remote preservation.
7. It must run existing teardown eligibility checks and preserve dirty, later, mismatched, live, or uncertain content.
8. It must persist the exact Decision OS tracker-mutation request, including expected bead state and revision, landing evidence, authority, and required Closure-Receipt evidence.
9. It must wait while the registered Decision OS main steward verifies or appends the one operative valid Closure-Receipt before canonical bead closure and publishes the tracker-only mutation through the authoritative path.
10. It must observe and verify the matching current-generation tracker receipt, post-mutation bead state, tracker revision, publication result, and canonical bead closure.
11. It must prove the exact copy has no live worker process, is clean, has the required landing or preservation disposition, and has satisfied the configured nonzero quiet interval.
12. It must create and verify an exact durable recovery ref before removing any local branch or copy that contains preserved unlanded content.
13. It must invoke the existing provider-specific safe isolated-copy cleanup for only the exact claimed copy and record the provider return receipt.
14. It must record the fate of every local and remote delivery branch as retained, deleted, unavailable, or preserved by exact ref, without treating branch deletion failure as success.
15. It must remove runtime ownership records only after endpoint, copy, ref, tracker, and branch obligations are complete or explicitly preserved under authorized disposition.
16. It must reconcile the Firstmate queue outcome from the authoritative bead and exact delivery disposition without creating parallel mutable task truth.
17. It must publish the post-retirement capacity projection and permit refill only from that projection's safe verdict.
18. It must retire the live attempt record from capacity while preserving the minimum immutable attempt and terminal receipts in audit history.

`landed` means the exact delivered content is in the authorized target branch or was joined through an authorized local-only merge with exact before and after commits.
`preserved_unlanded` means exact content is durably recoverable by a recorded ref or equivalent provider receipt but is not product-delivered.
A pushed branch, remote-only ref, or closed-unmerged pull request can prove `preserved_unlanded` but never proves `landed` by itself.
A squash merge proves `landed` only when the forge and Git evidence establish exact content equivalence under the existing landing-proof owner.
`unknown` preserves the attempt, copy, refs, bead state, and reserved ownership until authoritative evidence becomes available.
Data safety may permit authorized physical-copy return after `preserved_unlanded` is durably proved, but it must not produce successful bead closure or a successful Firstmate queue outcome.

A crash after forge observation, receipt request, tracker comment, bead close, tracker commit, publication, preservation, copy return, branch disposition, queue reconciliation, or retirement must resume from the matching persisted boundary.
A duplicate completion event, merge notification, periodic refill, startup recovery, or heartbeat recovery must converge on the same attempt and must not repeat a tracker mutation, cleanup, branch deletion, queue completion, or launch.
A completion and refill race may observe either pre-retirement reserved ownership or the post-retirement deficit, but it must never observe an intermediate free slot.

### Recovery without new control machinery

Pending attempt and terminal obligations must be exposed through the existing session-start, heartbeat, and fleet-snapshot paths from the upstream Task 7.6 design.
Those existing attended paths may retry idempotent observation and reconciliation, but no new daemon, scheduler, dashboard, or mandatory operator loop is authorized.
An ordinary fully evidenced attempt should reconcile without additional operator input.
Ambiguous identity, contradictory authority, destructive disposition, missing required approval, or unavailable authoritative evidence may stop for reconciliation.
A stopped case must preserve ownership and name the exact authority or evidence needed to continue.

### Migration and rollback

Migration must first reconcile repository ownership because the Firstmate operating `main` currently diverges from upstream and privately owns `bin/fm-fleet-refill.sh` while the reviewed upstream line does not.
The refill and lifecycle implementation must not begin on competing histories or overwrite the private script.
The maintainer must first identify the canonical integration base, preserve both histories, reconcile the script through a reviewed non-destructive branch integration, and verify the resulting owner before runtime changes begin.

After ownership convergence, migration proceeds in this order.

1. Introduce the read-only versioned JSON projection without changing either consumer's decisions.
2. Run the new projection in shadow mode beside the legacy count and record parity, latency, timeout, and per-row classifications without allowing shadow output to dispatch or clean.
3. Reconcile stale Firstmate records individually by proving endpoint, provider copy, branch, head, dirty or unlanded content, forge, bead, queue, and tracker obligations rather than deleting by age.
4. Introduce immutable attempts, claim-before-allocation receipts, and success-only audit publication for new launches while retaining compatibility reads needed for old attempts.
5. Introduce the ordered terminal owner and route new terminal events through it while legacy records remain explicitly reserved until reconciled.
6. Exercise startup and heartbeat recovery for pending claim, launch, tracker, preservation, cleanup, and retirement boundaries.
7. Switch normal refill and the private sentinel to the same JSON projection only after row and aggregate parity is explained and every divergence has a disposition.
8. Enable automatic refill only after duplicate-ownership, timeout, terminal, and concurrency tests pass and the reserved ceiling policy is configured.
9. Remove output-path, frozen-manifest, private-sentinel arithmetic, and migration compatibility reads only after both consumers have passed parity and rollback drills.
10. Retain the historical attempt ledger as audit-only evidence or archive it under a named retention owner without restoring it as capacity truth.

Rollback must disable automatic dispatch and return both consumers to alert-only behavior while preserving attempts, ledger rows, task records, beads, branches, refs, isolated copies, forge receipts, tracker receipts, and terminal obligations.
Rollback must never restore output modification time, frozen manifests, raw metadata count, or missing-data-as-zero behavior.
A projection schema mismatch, exceeded timeout, incomplete observation, ambiguous row, or terminal error must remain visible and reserved during rollback.
Forward recovery resumes from persisted attempt and terminal receipts rather than synthesizing a clean state.

### Behavioral regression matrix

The regression suite must exercise public commands and durable receipts rather than assert implementation-source text.
Every supported worker runtime and session backend combination that can host implementation work must prove active implementation, attributed validation, idle, dead, malformed, unavailable, and bounded-timeout projection behavior, with unsupported axes explicitly recorded rather than silently skipped.
Pi, pi-signed, Claude, Codex, OpenCode, Grok, Kimi, and Muse worker paths must be covered where each is supported, and tmux, Herdr, Zellij, Orca, and cmux provider behavior must be covered where each combination applies.

The capacity cases must cover active implementation, active validation, actionable validation waits, merge waits, completed workers, failed workers, dead endpoints, ambiguous state, stale metadata, disappearing records, scouts, persistent second mates, cross-home children, total timeout, malformed structured output, and schema mismatch.
Every uncertain case must remain reserved or make refill unsafe, and no uncertain fixture may yield fabricated zero active work.
Two independent consumers given the same projection fixture must produce identical row classifications and aggregate decisions without duplicate arithmetic.

The launch cases must cover failure before attempt allocation, after allocation but before claim receipt, after claim but before provider allocation, after provider allocation, after metadata publication, before endpoint launch, after endpoint launch but before instruction confirmation, and after launch success but before audit publication.
They must cover partial batch launch failure, replay after each boundary, concurrent same-home launch, cross-home duplicate bead claim, provider-wide copy collision, stale generation, and duplicate audit publication.
Only successfully launched attempts may receive one audit row, while every partial ownership obligation remains reserved.

The delivery cases must cover open pull requests, merge waits, closed-unmerged pull requests, exact-head merges, squash merges, later commits after the reviewed or merged head, unknown forge state, local-only merges, remote-only refs, missing remote refs, and forge identity mismatch.
They must prove the distinction between `landed`, `preserved_unlanded`, and `unknown` and must never treat remote preservation as product delivery.

The tracker cases must cover live bead verification before dispatch, refill, terminal reconciliation, and closure.
They must cover missing, malformed, stale, duplicate, and conflicting Decision OS Closure-Receipts, stale expected bead state or revision, claim refusal, unavailable steward, tracker write conflict, publication failure, and replay after comment, close, commit, publication, and receipt persistence.
No case may silently close a bead or mirror mutable bead truth into the Firstmate queue.

The cleanup cases must cover dirty copies, untracked files, live worker processes, insufficient quiet time, stale locks with live holders, provably abandoned locks, provider-copy identity mismatch, cleanup crashes, exact recovery-ref creation, remote-only preservation, branch deletion failure, already-returned copies, and retry after partial cleanup.
Every refusing signal must preserve content and exact ownership evidence.

The composition cases must cover duplicate completion and merge events, stale Firstmate queue entries, startup replay, heartbeat replay, terminal and periodic refill races, two concurrent refill runs, and a candidate becoming claimed or dependency-blocked between projection and dispatch.
They must prove that working to checks-green does not decrement reserved capacity, merge without bead closure does not decrement it, bead closure without safe copy and branch disposition does not decrement it, and only full retirement creates a refill deficit.
They must also prove that stale terminal records stop suppressing refill after successful exact retirement and that no race creates a duplicate attempt.

### Acceptance criteria

The design is implemented only when one public projection deterministically explains every row and aggregate, both consumers use it, and no obsolete arithmetic remains live.
The normal path must require no new operator action and must meet its measured latency budget under the configured target and safe ceiling.
Every Decision OS attempt must remain immutably bead-bound and replay safely from claim through audit retirement.
The ordered terminal owner must preserve data independently from proving product landing and must close the canonical bead only through the authoritative Closure-Receipt path.
Automatic refill must occur only from a complete safe projection and a live authoritative ready-and-unclaimed bead query plus an independent Firstmate serialization-safety proof.
Migration and rollback drills must demonstrate that uncertainty yields alert-only preserved ownership, never fabricated zero capacity.
The regression matrix must pass across every supported applicable worker runtime and provider, with explicit evidence for excluded combinations.
The final review must verify that no duplicate state machine, tracker, capacity counter, terminal owner, daemon, scheduler, wrapper, or control plane was introduced and that every superseded mechanism has an explicit deletion result.

## Runtime session backends

The runtime backend is the session-provider layer below firstmate's scripts.
It owns task endpoint creation, bounded capture, text/key sends, current-path reads for spawn-time worktree discovery when the backend does not create the worktree itself, live-window fallback lookup, agent-process liveness probes where verified, and endpoint teardown.
`bin/fm-backend.sh` centralizes backend selection, `state/<id>.meta` helpers, metadata-only cleanup identity validation, selector resolution, and operation dispatch; `bin/backends/tmux.sh` is the verified reference adapter ([`docs/tmux-backend.md`](tmux-backend.md)), and `bin/backends/herdr.sh` (P2), `bin/backends/zellij.sh` (P3), `bin/backends/orca.sh` (P4), and `bin/backends/cmux.sh` (P5) are experimental task-spawn adapters.
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
Herdr is experimental and can be selected explicitly or by runtime auto-detection: Treehouse remains its worktree provider, [`herdr-backend.md`](herdr-backend.md) owns current setup and safety limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) owns active empirical evidence.
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
For ship and scout work, `fm-spawn.sh` refuses to launch unless the resolved task path is a real git worktree root that is distinct from the project primary checkout.

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
Independently, `fm-spawn.sh`, `fm-send.sh`, and `fm-teardown.sh` source `bin/fm-gate-refuse-lib.sh` and exit with status 3 before fleet mutation when the gate environment marker is present or the current checkout matches the default no-mistakes gate-repository topology.
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
That keeps spawn launch compatible across claude, codex, opencode, pi, pi-signed, grok, kimi, and muse while preserving the requested profile for later audit.

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
The parent guards every marked request against a missing correlated report without reading the secondmate conversation; `bin/fm-pending-reply-lib.sh` owns the correlation, recovery, escalation, and retention contract.
Explicit backend-target sends and direct human typing stay unmarked, so captain intervention in a secondmate pane remains conversational.
After seeding a secondmate, `fm-backlog-handoff.sh` validates the fleet-specific handoff, then atomically delegates already-judged in-scope queued item moves to `tasks-axi mv` so the domain queue starts in the right place.
Remote routes move that dependency-closed set into a non-dispatchable backlog-format outbox before transfer, then use an idempotent remote receive under the destination backlog's own lock.
The outbox is the complete retry record, so no two-phase journal or transport-level retry is needed.
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
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns the complete inherited-local-material allowlist and propagation contract.

The `data/secondmates.md` line contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), and the secondmate environment variables are documented in [configuration.md](configuration.md).

## Delivery modes are explicit per task

`no-mistakes` tasks run the full validation pipeline, `direct-PR` tasks open PRs without that pipeline, and `local-only` tasks stay local until firstmate performs an approved fast-forward merge.
Each task's mode and `yolo` posture are firstmate's decision at intake and are passed explicitly to `bin/fm-brief.sh`, `bin/fm-spawn.sh`, and `bin/fm-promote.sh`, which refuse a ship task that does not carry them.
A ship brief records its mode as a fixed machine-readable line and the spawn refuses to launch on a different one, so the worker's instructions and the recorded task delivery cannot diverge.
`data/projects.md` records each project's standing posture and optional `+yolo` flag as the captain's default and as context for that decision, including the conditional `no-mistakes-prod-only` policy; a ship spawn that drops below the registered rigor prints a deviation notice and continues.
`bin/fm-project-mode.sh` remains the one registry parser for the mechanical consumers that have no task in hand: fleet sync's `local-only` skip and home seeding's refusal and no-mistakes initialization.
When a selected delivery path calls for a diff, `bin/fm-review-diff.sh` refreshes the authoritative base and, when task meta records `pr=`, always fetches and compares against `refs/pull/<n>/head` by default (recorded `pr_head=` is only an offline fallback) before falling back to the local branch with a warning.
For target project repos shipped through their own no-mistakes pipeline, commits under `.no-mistakes/evidence/` are the pipeline's PR-viewable validation evidence and are expected to stay in the crew branch until the evidence-hosting design changes.
The firstmate repo itself is the exception: its `.no-mistakes/` directory is local state, stays gitignored, and is rejected by CI if tracked.
PR-based task merges go through `bin/fm-pr-merge.sh`, which records `pr=` and any available `pr_head=` through `bin/fm-pr-check.sh` before calling `gh-axi pr merge`.
The helper requires a full `https://github.com/<owner>/<repo>/pull/<n>` URL, invokes `gh-axi pr merge <n> --repo <owner>/<repo>`, defaults to `--squash`, preserves explicit merge-method flags, and rejects malformed URLs or repo override flags before recording merge state; a well-formed GitLab merge request URL (see [docs/gitlab-merge-watch.md](gitlab-merge-watch.md)) is refused too, explicitly, rather than sent to the wrong forge.
Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
[`bin/fm-teardown.sh`](../bin/fm-teardown.sh)'s header owns the landed-work proofs, PR-discovery fallback, and stale-lock recovery procedure.

## Optional Relay

Relay is opt-in presence for the shared `@myfirstmate` bot on both public surfaces it supports, X and Discord.
A user enables it by putting `FMX_PAIRING_TOKEN` in the firstmate home's gitignored `.env`; `FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`.
That token is standing authorization for firstmate to answer public mentions and act autonomously on normal reversible mention requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while parent-thread context may still include other public accounts.
On the locked session-start bootstrap step, that token creates the local polling and watcher-cadence artifacts described in the [Relay configuration reference](configuration.md#relay-env).
Without the token, the locked session-start bootstrap step removes those artifacts on opt-out and otherwise stays silent, so non-Relay users see no behavior change.
Newly offered mentions are stored as `state/x-inbox/<request_id>.json` and wake firstmate once per retained request ID; the [Relay configuration reference](configuration.md#relay-env) owns the durable offer-marker and re-offer contract.
The `fmx-respond` agent-only skill drains that inbox, uses `in_reply_to` parent-post context for conversational continuity, classifies each mention as an actionable request, question, or pure acknowledgment, and submits public-safe replies through `bin/fm-x-reply.sh`.
When a reply has a real visual artifact, `--image <path>` attaches one local PNG, JPEG, GIF, WebP, BMP, or TIFF to the relay's optional `{media_type,data_base64}` image object.
Actionable reversible requests run through firstmate's normal intake, backlog, dispatch, investigation, or ship lifecycle.
Work that completes in the answering turn gets one outcome reply.
Work that spawns a longer-running task gets an acknowledgement reply first; `bin/fm-x-link.sh` records `x_request=`, `x_request_ts=`, `x_followups=0`, and optional reply-platform context in that task's `state/<id>.meta`, while durable per-request context preserves the original platform and budget independently of task links and inbox cleanup.
Later milestone wakes use `bin/fm-x-followup.sh` to post up to three public-safe follow-ups through the relay's `connector/followup` endpoint, ending with a `--final` one for ordinary Relay-linked work. A typed promised-final commitment owns its terminal reply through `bin/fm-public-followup.sh`; after its receipt is validated, `bin/fm-x-followup.sh --clear <task-id>` removes any legacy link without posting another reply.
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
`bin/fm-public-followup.sh` composes those three and adds nothing of its own beyond the activation gate, a private terminal-event inbox, and the idempotent delivery sequence.
Work routed to another home reports a *typed* terminal result through `bin/fm-public-followup-emit.sh`; firstmate never recovers the source home, work id, outcome, or deliverables by parsing a free-form `done:` sentence, and the child never learns the thread.
Because a terminal event's id is derived from its identity tuple rather than generated, duplicate reports and restart replay converge without coordination.
Reconciliation rides the existing relay poll and the session-start digest instead of a new watcher, daemon, or timer, and both are gated on the same `.env` activation contract so a home that never opted into the relay executes none of it.
The [Relay configuration reference](configuration.md#promised-public-replies-statepublic-followup) owns the operator-facing contract, and the `fmx-respond` skill owns the procedure.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
Each project `AGENTS.md` carries a short `## Maintaining this file` self-governance section; `bin/fm-ensure-agents-md.sh` owns the canonical wording and injects it idempotently when creating the skeleton, promoting an existing `CLAUDE.md`, or reconciling an existing `AGENTS.md` that still lacks it.
It refuses a case-variant real memory file such as a lowercase `agents.md`, whose `CLAUDE.md` symlink would carry an uppercase literal target that dangles on a case-sensitive filesystem, and surfaces the mismatch for manual reconciliation.
The full ownership rule - what is project-intrinsic versus fleet-private, and how firstmate keeps the two apart without writing into project clones - is owned by [`AGENTS.md`](../AGENTS.md) (project and knowledge management).

## Operational memory routing

`/stow` sweeps the current session for durable knowledge that only exists in conversation and routes each finding to the most specific disk home.
Home-domain captain preferences go to `data/captain.md`, cross-domain shared captain preferences go to the primary home's `data/captain-shared.md`, fleet-local operational facts and gotchas go to home-local `data/learnings.md`, project-intrinsic knowledge goes through normal crewmate delivery into that project's committed `AGENTS.md`, and task-scoped notes or undone next steps go to the backlog.
Memory writes use inspect-then-update: read the current destination first, then rewrite or prune matching bullets or notes in place instead of appending by default.
Task-scoped notes use `tasks-axi show <id> --full` followed by `tasks-axi update <id> --body-file <path>`, adding `--archive-body` when the prior body should remain recoverable.
Generalizable firstmate knowledge goes to shared tracked docs through the normal PR pipeline; the firstmate-internal `/stow` deliberately never stores findings in either skill directory.

## Local clones stay fresh

The locked session-start deferred network stage, PR-based teardown, and merged-PR wake handling refresh remote-backed project clones when the clone is safe to move.
Wake-time refreshes can target a single clone by project name, so the primary home also catches up when a secondmate reports a merge from its own home.
Clean default-branch clones fast-forward to `origin/<default>`, and a clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.
Dirty clones, non-default branches, detached HEADs with unique commits, diverged defaults, and default branches checked out in another worktree are reported as `STUCK:` with their behind count and left untouched.
Fetches blocked by an orphaned `.git/packed-refs.lock` use bounded retries and remove the lock only when the shared staleness proof can prove it abandoned; [configuration.md](configuration.md#toolchain) owns the recovery details and tuning knobs.
Local-only projects, clones without an origin remote, and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin`, then re-reads updated instructions and nudges updated secondmates without touching project clones.
For a remote route, the configured code root updates from its own origin on that host before the persistent home fast-forwards to the code-root commit.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
Local homes share the guarded fast-forward helper, while remote updates delegate the same safety decision to the configured host through the generic transport.
The mechanics are owned by the `/updatefirstmate` skill and firstmate's operating manual in [`AGENTS.md`](../AGENTS.md) (self-update).

## Restart-proof

Fleet state lives in each task's session-provider backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected), no-mistakes run records, status event logs, local markdown under `data/` including `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, and persistent secondmate homes.
For herdr, respawning after a server-restored layout closes and replaces confirmed no-agent or dead task-tab husks instead of requiring manual tab cleanup.
At session start, confirmed-dead secondmate agent endpoints are closed and relaunched through the same secondmate spawn path, while ambiguous liveness reads are left untouched to avoid duplicate supervisors.
Use `/stow` before an intentional reset when the conversation may hold durable knowledge that has not yet been written to disk; after that, the next firstmate session can reconcile and carry on.

## Development notes

The current watcher reliability work combines always-on bash triage with a durable queue for actionable wakes, a race-proof singleton lock, duplicate self-eviction, drain-time liveness assertion, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) provides walk-away supervision via the `/afk` skill while reusing the same shared wake classifier as the always-on watcher.
