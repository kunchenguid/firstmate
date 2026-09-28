# Architecture

How firstmate works, in depth.
This document is for maintainers and contributors who need the mechanisms behind firstmate's supervision, task lifecycle, runtime backends, and memory.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
firstmate's supervisor contract and routing index for conditional procedures is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Find a topic

| Topic | Start here |
| --- | --- |
| How the watcher decides when to wake firstmate | [Event-driven supervision](#event-driven-supervision) |
| Stalled, wedged, dead, or waiting workers | [Wedge escalation](#wedge-escalation-and-declared-waits), [parked validation gates](#deferring-for-a-parked-validation-gate), [agents that are gone](#agents-that-are-gone), and [busy panes past the busy bound](#busy-panes-past-the-busy-bound) |
| The wake queue, open decisions, and current-state reads | [Durable wake queue](#durable-wake-queue), [open decisions](#open-decisions-and-drain-sections), and [current-state reads](#current-state-reads) |
| Secondmate supervision | [Secondmate wake-queue stalls](#secondmate-wake-queue-stalls), [secondmate liveness recovery](#secondmate-liveness-recovery), and [registered secondmate current state](#registered-secondmate-current-state) |
| Per-harness supervision, guards, and away mode | [Supervision block and watcher arming](#supervision-block-and-watcher-arming), [guards and backstops](#guards-and-backstops), and [away mode](#away-mode-and-the-away-record) |
| What "busy" means for each harness | [Busy state is semantic, per adapter](#busy-state-is-semantic-per-adapter) |
| tmux, Herdr, Zellij, Orca, and cmux | [Runtime session backends](#runtime-session-backends) |
| Worktree isolation and the gate's authority boundary | [Worktrees](#worktrees-not-branches-in-your-checkout) and [no-mistakes gate authority boundary](#no-mistakes-gate-authority-boundary) |
| Choosing a harness, model, and effort per task | [Dispatch profiles](#dispatch-profiles) |
| Persistent secondmate homes | [Optional secondmates](#optional-secondmates) |
| Delivery modes, merges, and teardown | [Delivery modes are explicit per task](#delivery-modes-are-explicit-per-task) |
| Public mentions on X and Discord | [Optional Relay](#optional-relay) |
| Where knowledge and memory are stored | [Project memory](#project-memory-belongs-to-projects) and [operational memory routing](#operational-memory-routing) |
| Clone refresh, self-update, and restarts | [Local clones stay fresh](#local-clones-stay-fresh), [self-updates stay safe](#self-updates-stay-safe), and [restart-proof](#restart-proof) |

## Event-driven supervision

The declared-wait vocabulary, including the legacy "external wait" label, is owned by [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh).
Worker declaration instructions are owned by [`bin/fm-brief.sh`](../bin/fm-brief.sh).

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Zero-token means the watcher spends no model tokens: all of its triage runs in bash.

### What counts as actionable

Actionable wakes include:

- Captain-relevant status signals.
- No-verb signals without positive evidence that their crew is still executing.
- Authenticated check output, such as PR merge polling or a Relay mention.
- Stale panes whose crew is not provably working, whether their status log looks terminal or non-terminal.
- Provably-working stale panes that persist past `FM_STALE_ESCALATE_SECS` with all of the following:
  - no wait their own worker declared;
  - no writes to their own task worktree;
  - in a home that armed `config/wedge-defer-parked-gate`, no validation gate of their own awaiting an unanswered supervisor decision.
- Declared external waits and attended captain-held transfers that remain declared past `FM_PAUSE_RESURFACE_SECS`.
- Heartbeat backstop hits.

### Captain holds on delivered work

For an ordinary crew task, a wait is read from both of its records:

- The status line a worker declared.
- The backlog hold `bin/fm-captain-hold.sh` recorded once firstmate handed the work to the captain.

Consider a delivered ordinary crew task whose last line stays a `done` PR-ready line.
For the length of the captain's decision, repeated alarms from new pane hashes on that task are bounded to the `FM_PAUSE_RESURFACE_SECS` cadence:

- The first hash still alarms.
- Each new hash inside that window is absorbed.
- A new hash after the window re-surfaces the hold.
- A terminal pane hash that never changes stays inert after its first alarm, exactly as it did before this bound.

The throttle is scoped to both the current captain-call lifecycle and the status-log state.
So releasing and re-holding the same task without a status append starts a fresh window, and that window's first new hash alarms.

A secondmate reaches the stale path only for a wait declared in its status line.
So a hold recorded only in the backlog, while the secondmate's last line is `working:` or `done:`, is outside this guard.
Reaching that case would require consulting the backlog for windows the secondmate gate deliberately skips.
That would put backlog reads on the ordinary poll hot path this design preserves.

### Wedge escalation and declared waits

A wedge is a worker that is stuck but might recover.
Repeated provably-working stale escalations on the same unchanged pane add an escalation count to the wake reason.
At `FM_WEDGE_DEMAND_INSPECT_COUNT`, they also add a `demand-deep-inspection` marker.

In the same branch that is about to escalate, the pane's own account of its quiet is consulted first: the worker's declared `paused:` or verified `captain-held` status line.
That declaration defers the escalation to the `FM_PAUSE_RESURFACE_SECS` recheck cadence instead.
A lane waiting on something it named is silent for a reason the escalation would misreport.
Without the deferral, the ladder would climb for as long as the wait lasts.

A declared clearing time (`paused: ... until <UTC ISO 8601>`) that has already passed stops counting as that account.
So two kinds of lane keep the unchanged escalation schedule, reason and `demand-deep-inspection` wording:

- A lane whose own wait is over.
- A lane that never declared one.

### Deferring for a parked validation gate

One further record is read only when both of these hold:

- The status line accounts for nothing.
- This home armed the default-off `config/wedge-defer-parked-gate` flag.

That record says whether the crew's own current state is a validation gate whose answer is owed to the supervisor, who has actually been asked and has not answered.

The record exists because the quiet of a parked lane is the pipeline's doing rather than anything the worker wrote down.
No status-line predicate can see it.
The signal naming who owes that answer and what clears it lives in this record, rather than in any line the worker could write.

Arming it is a per-home choice.
Every other wait here is the worker's own declaration about its own silence, while this one is derived from a pipeline's gate state.
So which lanes give up the escalation ladder is a decision each home makes for itself.

A home that has not armed it reads no further record at all.
The flag is tested before the fold, which is the pass over a task's status log that decides which keyed decisions are still open.
So in that home:

- No fold or current-state read is spent.
- No wait record exists to defer on.
- Every parked lane keeps the unchanged escalation schedule, reason and `demand-deep-inspection` wording.

The record has two halves.

#### First half: an ask-user finding row

The first half is minted only from the gate's own findings table, by a row whose `action` column is exactly `ask-user`.
That column is read by position out of the table header.
It is not searched for over the run payload, where a finding's free-text description or a branch name would satisfy a search just as well.

The row is then split on raw commas, and the producer does not quote commas inside free text.
So the derivation refuses outright, keeping the ladder, unless every column the header places before `action` is one of the short comma-free scalars this table is known to carry (`id`, `severity`, `file`, `line`).
A header that grows an unrecognised or free-text column ahead of `action` therefore reads as unsafe rather than as safe.

That precision is what keeps the distinction the ladder depends on.
The gate's shape - `awaiting_approval`, `fix_review`, `awaiting_agent` - is reported parked in every case and does not by itself say who owes the answer.
Only a findings row whose `action` column is exactly `ask-user` does.
A crewmate that goes quiet before answering its own gate is exactly the wedge this ladder exists to catch.
So a gate with no such row keeps the unchanged escalation schedule, reason and `demand-deep-inspection` wording.

#### Second half: an open decision for this run

The second half is the task's own decision fold still holding an open `needs-decision` record whose key is `nm-<run>-<step>` for the run the current state reports.
That record is the positive evidence that firstmate was told about this gate, rather than merely that someone owes it an answer.

Two things are not that evidence, and both keep the unchanged ladder:

- An open decision under any other key, such as an unrelated question left open earlier in the same task.
- A current state that names no run.

This half is what keeps the ladder in the two cases where a parked supervisor-owed gate is really the crewmate's move:

- A decision that has already been answered, where `fm-send --resolve-key` closed it at answer time while the gate stays parked until the crewmate relays it.
- A crewmate that parked at such a gate and went quiet before escalating it at all, where nobody was ever told.

A `blocked` record is not that evidence either.
A blocker is an obstacle the crew reported rather than an unanswered question, and a different action clears it.

Every way the fold can come back empty, including an unreadable status file, leaves the unchanged escalation schedule in place rather than taking the ladder away.

### Who or what each wait is on

Each kind of wait carries its dependency or decision owner and the action that clears it as data alongside the verdict.
Those are not wording chosen per branch where the recheck is written.
So a new kind of evidence cannot reach the deferral without deciding both.
The deferral refuses a record that does not carry all of them and escalates as it would have.
Deferring on a half-filled record is what would name the wrong dependency or decision owner, or an action that clears nothing.

The three have different clearing conditions:

| Wait | Dependency or decision owner | What the recheck asks for |
| --- | --- | --- |
| A `paused:` declaration | The work or condition the worker names as awaited | The reader confirms the wait still holds. |
| A hold | The captain reading the recheck | The captain answers the held decision or releases the hold. |
| A parked gate | Firstmate's `ask-user` decision | That finding is decided and relayed to the crewmate. |

A parked gate is owed to firstmate because ask-user findings are routed to firstmate, which decides most of them itself.
One it escalates becomes a captain-held transfer that the hold record already covers.
Wording any of them as another would point the reader away from the one action that clears it.

### How a wait is aged

A wait with a written record is aged from the status file, since that is when the worker wrote the line.
Anchoring on a per-window marker instead would let a churning display reset the cadence.

A parked gate has no such record, because the worker never wrote the wait down.
So its recheck publishes no wait age at all.
It does not use an age read from the quiet window, because this deferral resets that window on every pass, so it would report the same small number for a gate of any age.

### Held waits while the captain is away

The away-posture record is `state/.afk-contract`, described under [away mode](#away-mode-and-the-away-record) below.
While the away-posture record exists, a hold is not rechecked here at all, as on every other captain-facing path.
There is nobody to answer it, and the return brief already lists it.
So the pane is absorbed silently and no re-surface throttle is armed, which leaves the recheck owed once the record is archived.

That absorb deliberately leaves the idle timer alone too.
Only a captain-held hold ever reaches it, and that verdict is reached before the armed-home flag is tested, so before any fold or current-state read.
The one read repeating under the away record is the status-line read that predates this deferral, which is nothing costly enough to throttle.
So the recheck owed on return stays owed in full the moment the record is archived, rather than starting a cadence nobody could act on.

A parked gate is not silenced that way.
It is owed to the supervisor rather than the captain, and under away posture the supervision branch is the actor allowed to answer it.
So it keeps the long recheck cadence throughout.

### Cost and known bound of the consult

The consult costs:

- One status-line read.
- Only in an armed home, a status-log fold.
- Only in an armed home, then one current-state read for the lanes whose status line explained nothing and whose fold holds some open `needs-decision`.

All of these are taken in the same at-threshold branch as the worktree walk.
So the consult is bounded to at most once per window per `FM_STALE_ESCALATE_SECS` and never runs on an ordinary poll.
The fold is read before the current state so a lane with no open decision never pays for the costlier read at all.

A known bound: the recheck throttle is scoped to the pane hash.

- The long cadence holds for a lane whose pane is genuinely static.
- A lane whose display churns (a ticking clock, a token counter) drops the throttle with each new hash and is rechecked once per idle window instead.

That churning lane still loses the escalation ladder and the `demand-deep-inspection` wording, which is the defect being fixed.
But it is not the full delivery of a long cadence.
The alternative is letting the throttle outlive the hash.
That trades this bound for a stale throttle surviving into an unrelated later episode and suppressing that episode's first recheck, which is the worse failure.

### Worktree write evidence

A pane is deferred instead of escalated when it holds a file newer than the start of its own quiet window, anywhere in the worktree recorded for that task.
A crew writing source, then tests, then documentation behind a static pane is liveness that neither pane quietness nor the run step can show.

That deferral re-surfaces on the same `FM_PAUSE_RESURFACE_SECS` cadence as a declared wait, with a reason naming the write evidence rather than a wedge.
It is bounded to one pruned, depth-bounded, wall-clock-bounded walk (`FM_WORKTREE_WRITE_PRUNE`, `FM_WORKTREE_WRITE_MAXDEPTH`, `FM_WORKTREE_WRITE_TIMEOUT`).
The walk is taken only in the branch that was about to escalate, never on every poll.

Every absence of write evidence leaves the existing escalation schedule untouched, including:

- A missing worktree record.
- A torn-down worktree.
- A walk that outlives its wall-clock bound on a hung mount.
- A failed walk.

So a crew that writes nothing still escalates exactly as before.

A secondmate's recorded worktree is never probed for write activity.
It is a provisioned firstmate home whose own supervision keeps writing inside it whether or not the mate produces anything.
So its panes keep escalating on the unchanged schedule.

### Agents that are gone

A pane whose recorded endpoint holds no agent at all is not a wedge suspect.
A wedge is something stuck that might recover, while an agent that is gone never moves again.
Its pane never churns and the idle timer never resets, so the escalation ladder had no ceiling at all.
Two finished lanes on one live fleet reached 226 and 203 consecutive escalations, roughly one every `FM_STALE_ESCALATE_SECS`, which is what drowns the alarms that matter.

In the same branch that was about to escalate, `bin/fm-backend.sh`'s recovery-grade `fm_backend_agent_state` is read once.
Only two of its verdicts report that record once and then stop re-escalating it while it stays that way:

| Verdict | Meaning |
| --- | --- |
| `dead` | An endpoint still present with no agent running in it. |
| `missing` | An endpoint authoritatively absent. |

Every other verdict, including `alive`, `ambiguous`, `unreadable`, `unverified`, and a read that failed outright, keeps the identical escalation schedule, reason, and count.
So a genuinely wedged live agent is unaffected.

The report decides nothing about the record's fate, because such a lane routinely still holds unlanded work that teardown is right to refuse.
Retiring, relaunching, or cleaning it up stays with the supervisor.

The once-marker records the verdict together with the agent incarnation it was reported for.
That incarnation is the task's per-incarnation busy gen (`state/<id>.busy-gen`), minted by `bin/fm-busy-event.sh arm`, which changes exactly when the agent is replaced.
So the marker re-arms when that endpoint reads live again and when the agent is replaced.
A successor dying in the same window is reported again, even when no threshold probe reads it alive in between and its dead display hashes identically to the one already reported.

When no busy incarnation token is readable for the task (it was never armed, or its sidecar is unreadable), the marker falls back to keying on the pane hash.
That keeps the once-per-display absorb for a record-less task rather than re-reporting on every threshold.
The residual cost is that such a successor dying into a byte-identical dead display stays absorbed.

### Busy panes past the busy bound

A busy pane is otherwise exempt from staleness, but only until its last completed turn or explicit native-harness progress reaches `FM_BUSY_TURN_MAX_SECS` (`bin/fm-watch.sh` owns marker selection).
Past that bound it is routed through the same wedge escalation, for inspection only - never an automatic interrupt, signal, or restart:

- A live agent gets the identical reason, escalation count, worktree-write deferral, and `demand-deep-inspection` marker.
- An endpoint proven gone gets the same dead-record report.

There are two exceptions to that bound:

1. A crew that declared an external wait (`paused:`) or a verified captain-held transfer.
   Its busy verdict supplies liveness while identifying the long-running foreground call as the declared wait.
   So it takes the bounded `FM_PAUSE_RESURFACE_SECS` recheck instead of a wedge escalation.
   A captain-held transfer, though, is not rechecked while the away-posture record exists.
2. In a home that armed `config/wedge-defer-parked-gate`, a crew whose own validation gate awaits the supervisor's still-open decision for that run.
   It is reached through the shared wedge timer rather than the declaration branch, because who owes that answer does not depend on what the pane is rendering.
   It takes the same bounded recheck, including while the away-posture record exists.

Lifting the declaration restores the unchanged busy-pane wedge path.
A pane that is no longer busy returns to the existing idle declared-wait classification.

While the legacy daemon flag is active, a busy pane that crosses the bound under a declared external wait is handed to the daemon as the plain wake identity.
It does not take that recheck in the watcher, because the daemon owns triage there and a wake already decorated as a possible wedge would override the daemon's own declared-wait verdict.
An undeclared busy pane past the bound still takes the wedge escalation.

That handoff is keyed on the declaration itself (the status log's signature) rather than on the pane capture.
So a harness footer that ticks on every poll wakes the daemon once per declaration instead of once per poll.
The handoff also clears the wedge timer, escalation count, and worktree-write deferral exactly as the normal-mode absorber does.
So an undeclared busy phase's timer does not resume when the declaration lifts.

### Durable wake queue

Those actionable wakes are written to a durable local queue (`state/.wake-queue`) only after generation-bound recovery evidence is published.
So an interrupted watcher or handling turn can be recovered without losing the queue record.

### Secondmate wake-queue stalls

Agent endpoint liveness and queue-consumption liveness are separate.
On each poll, the primary watcher reads the oldest valid actionable row from every endpoint-recorded local secondmate home's durable wake queue.
It does so without locking, consuming, or rewriting that foreign queue.

A queue that is draining is not stalled.
So the primary times the interval since that oldest actionable row last changed, rather than the age of the row itself.
Rows that declare themselves a bounded external wait (`awaiting external - declared pause`) are not actionable evidence at all.

A stall is handled in this order:

1. The no-progress interval reaches `FM_SECONDMATE_WAKE_STALL_SECS`, and the mate is not provably inside an active turn.
   Proof of an active turn is an exact busy verdict, honored only while that same no-progress interval is under `FM_BUSY_TURN_MAX_SECS`, because a mate's turns end in its own home and leave no completed-turn evidence in the primary's.
2. A mate whose semantic busy class is exactly idle, whose agent is alive, and whose composer is not pending is rung once so its own home can drain.
   The parent notification is withheld until that same row stays frozen for another stall interval.
   Unknown, busy-over-bound, and ring-unsafe panes keep the parent alarm.
   An empty inbox or a fresh child beacon is not idle proof.
3. The primary then appends one keyed `check` wake naming the mate, row sequence, and observed idle interval.

Parent receipts and queued-key deduplication suppress repeats across watcher and handling crashes.
One notification covers a whole no-progress episode.
Any move of that position ends that episode and starts a fresh observation interval.
That includes drain progress, and the fresh rows of a queue reprovisioned under the same task id, at whatever sequence it restarts.
Empty, advancing, and declared-wait queues remain silent.

Endpointless registered mates remain outside this queue scan because its preconditions can never be met for them.

`tests/fm-wake-queue.test.sh` pins the no-progress notification, drain-progress reset, declared-pause exclusion, active-turn deferral, proven-idle child-first ring, busy and unknown parent-alarm paths, genuine stall after a ring, idempotence, quiet-queue, and byte-for-byte foreign-row preservation guarantees.

### Secondmate liveness recovery

Dead-or-missing endpoint recovery is shared by two drivers over one library, `bin/fm-secondmate-liveness-lib.sh`:

- The session-start sweep in `bin/fm-bootstrap.sh`.
- The watcher's own `FM_SECONDMATE_LIVENESS_SECS`-cadence tick during ordinary supervision.

Both drivers follow the same rules:

- They relaunch only the recovery-grade `dead` and `missing` verdicts, through the ordinary guarded `fm-spawn.sh --secondmate` path.
- A remote route is probed read-only across its host-local boundary and is never replaced by a local endpoint.
- The per-mate liveness lock keeps a concurrent sweep and tick from killing or re-probing an endpoint the other is mid-relaunch on.

Each automatic relaunch surfaces as exactly one `check` wake plus a durable line in `state/.secondmate-relaunch-<id>`.
A mate that exceeds `FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS` ledgered attempts inside `FM_SECONDMATE_LIVENESS_WINDOW_SECS` is parked behind a bound marker and escalated once.
It stays parked until a live probe rearms it with a full attempt budget.

### Merged PR outcomes

When a canonical validated task PR poll returns exactly `merged`, the watcher routes it through the shared merge-outcome emitter before retiring the poll.
[`bin/fm-merge-outcome-lib.sh`](../bin/fm-merge-outcome-lib.sh)'s header owns role routing, PR-specific wake identity, marker-locked normal deduplication, and the at-least-once ordering that prefers a rare duplicate over silence.

A legacy poll armed on a persistent `kind=secondmate` record is residue from a child's relayed PR.
The watcher retires it without a merge outcome, notification marker, or wake, leaving the mate's lifecycle intact.
`bin/fm-pr-check.sh` refuses new polls on such records.

After successful outcome publication, the watcher immediately delivers the emitter's local actionable poll row.
It also publishes a private retirement receipt bound to the poll's registration, bytes, file identities, metadata, provider, URL, and task ID.

The retirement receipt makes poll cleanup safely retryable across restarts.
Fixed-path recovery:

1. Revalidates the same evidence.
2. Removes the runnable check first.
3. Removes its registration and data sidecars.
4. Removes the receipt last.

It preserves task metadata, including `pr=` and `pr_head=`.

A concurrent replacement remains armed, and every non-merged or invalid observation remains unchanged.
Retirement never performs task or persistent-secondmate cleanup.

Ownership of this path is split:

- `bin/fm-pr-lib.sh` owns the notification-marker and retirement-receipt formats plus their strict identity mechanics.
- [`bin/fm-merge-outcome-lib.sh`](../bin/fm-merge-outcome-lib.sh) owns role-routed publication, the local durable row, and marker ordering.
- `bin/fm-watch.sh` owns immediate poll-result delivery and retirement.

### No-verb wakes and pane churn

No-verb wakes, such as `working:` notes and bare turn-ended signals, are benign only when every referenced task independently has positive evidence that its crew is still working.
Two forms of evidence count, both read through `bin/fm-crew-state.sh`:

- A currently attributed active no-mistakes step.
- An exact busy verdict from the semantic busy-state contract.

A home that creates `config/turnend-churn-absorb` lets each eligible bare turn-ended task that lacks either authoritative proof use a third form.
That form is pane content that changed since the previous poll, compared against the same `state/.hash-*` marker the staleness backbone records.
It claims no harness semantics and needs no adapter cooperation.
It stays opt-in because it infers execution from rendered bytes rather than from a verdict the harness vouches for.
So with the flag absent, triage behaves exactly as it did before ([`configuration.md`](configuration.md) "Turn-end pane-churn absorb").

That evidence clears the pane's prior stale classification and wedge-escalation count, then defers such a wake rather than swallowing it.
A crew that has stopped renders nothing further.
Its now-static pane surfaces through the staleness backbone within a poll or two, even if its final bytes match an earlier stale render.

A wake naming any status file remains governed solely by the strict authoritative proof.
The pane-churn fallback is unavailable to an entire batch that references a secondmate.

Each of these surfaces without clearing prior stale classification:

- An unresolvable endpoint.
- An ambiguous marker key.
- A missing or malformed prior hash.
- A capture that fails or returns empty.
- An invalid deferral bound or deadline.
- An unwritable deferral marker.

The deferral is bounded per endpoint by `FM_TURNEND_CHURN_ABSORB_SECS`, tracked in `state/.churn-since-*`, after which the turn-end surfaces and the window restarts.
That bound is load-bearing rather than cosmetic, because churn and staleness read the same pane.
A pane that renders continuously - a clock, a spinner, a shell heartbeat, or a harness that leaves a background renderer alive after its agent yields - never reaches the staleness backbone's two-identical-hashes test either.
An unbounded churn absorb would leave a genuinely stopped worker behind such a renderer with no path left to surface it.

If two metadata records derive the same per-window marker key, including two records that name the same endpoint, that marker is not attributable churn evidence for either task.
So the bare turn-ended wake surfaces without changing or migrating existing marker state.

A `kind=secondmate` task's status stream doubles as its parent-directed reply channel, so its lines new since the last classification are read before busy evidence counts:

- A decision, blocker, terminal outcome, `note:`, correlation-marked line, or unknown verb always surfaces.
- Unmarked routine `working:` and `paused:` progress is absorbed only by the same provably-working proof an ordinary crewmate gets.

Its bare turn-ended signal is absorbed only by the ordinary authoritative working proof.
That is because an active secondmate does not enter the staleness backbone that would resurface deferred pane-churn evidence.

### Declared waits on idle panes

A crew that declares `paused:` for a known external wait, or carries a verified `captain-held` transfer, is separately absorbed while idle.
It is re-surfaced only on the longer pause cadence, rather than being treated as a possible wedge.
The exception is that a captain-held transfer is not rechecked while the away-posture record exists.

For an ordinary crew that has stopped, the normal-mode watcher first surfaces one stale wake.
While attended, it then applies that same cadence to an unchanged `paused:` or durable `captain-held` endpoint.
The pause classification itself is recovered only when the backend confidently reports its agent dead.
Live or inconclusive liveness remains fail-open at that initial surface, so a worker genuinely waiting on a decision is never silenced.
Its later sights are still held to that same bounded cadence rather than re-alarming on every pane-hash change.
That is because the throttle is keyed to the declaration and not to the pane an idle parked worker keeps ticking.

The pause path still never reads a secondmate's endpoint liveness.
Dead-or-missing recovery belongs to the dedicated [liveness tick](#secondmate-liveness-recovery) above.
A mate is admitted to that same cadence only to serve a status-declared wait's bounded re-surface.
So a forgotten `paused:` declaration, or an attended `captain-held` declaration, cannot rot invisibly.
Its initial normal-mode status signal still surfaces through the no-verb path.
A daemon-backed away posture self-handles that routine signal and owns later external-wait rechecks.

Fresh stale panes use the same current-state read before trusting the status log.
So an active run or a proven busy worker outranks an old captain-relevant status-log line left behind before validation.

No-change heartbeats are also benign.

### Inactive-work scan

Separately from heartbeat backoff and wedge handling, the watcher poll runs `bin/fm-inactive-reconcile.sh` on its own bounded cadence.
Locked session start sends the same bounded local scan through `bin/fm-startup-network.sh`'s deferred worker, so current-state reads never block the digest.

In each home, the scan:

- Considers only that home's long-inactive direct ordinary crewmates.
- Excludes captain-held work.
- Accepts only `done` or `failed` from `bin/fm-crew-state.sh`.

A secondmate retains a durable receipt for its idempotent report through the established parent route.
Main-home captain presentation retains a separate receipt.
Neither path performs a forge or PR check.

A secondmate home's terminal child ledger lines, PR registrations, captain holds, and merges are published on that same parent route by the scripts that record them.
So no captain-facing outcome depends on the mate model appending it ([secondmate-parent-channel.md](secondmate-parent-channel.md)).

### What stays silent

Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
Each `fm-wake-drain.sh` presentation runs the same liveness guard as the supervision scripts, so a lapsed watcher chain surfaces even on a turn that only handles queued wakes.
Routine watcher polling, supervision no-ops, elapsed waiting time, and absorbed benign wakes stay silent.
A declared external wait or an attended verified captain-held transfer trades that silence for one bounded recheck per pause window, naming the dependency or decision owner.
While the away-posture record exists, captain-held work waits without rechecks and remains visible in the return brief.

### Open decisions and drain sections

Crew status files are append-only wake-event logs, not current-state fields.
Because of that, a per-wake read of only the latest line can bury an earlier still-open `needs-decision`/`blocked` under later unrelated appends.
So `fm-wake-drain.sh` prints a separate, fleet-wide OPEN DECISIONS section on every presentation, including the empty-queue path session-start relies on.
That section is built through `fm-classify-lib.sh`'s cursor-backed incremental scan, using the authoritative `status_open_decisions` fold semantics.
So the buried decision keeps surfacing until that fold closes it, while each presentation folds only new status-log appends.

The drain coordinates that fold and its annotations through a locked fleet-wide snapshot.
The snapshot's `.status-presentation-cursor` manifest records each status file's identity plus independent annotation and outcome-backstop byte offsets.
[`pi-supervision-branch.md`](pi-supervision-branch.md#lost-wake-outcome-backstop) owns the bounded lost-wake backstop that uses the latter offset.

A queued signal annotation prints every status line still unread at that cursor.
The fleet-wide UNREAD STATUS section prints `note:` lines and reserved-key pending-reply resolutions once, even on an empty-queue drain, because those verbs never enter the OPEN DECISIONS fold.

A third bounded section, RECORD DIVERGENCE, prints on the same drains for the opposite failure.
There the status fold went quiet on a key that the durable captain-held task still shows as open.
So the status side reads as complete while the two records contradict each other.
`bin/fm-captain-hold.sh diverged` decides what counts and closes nothing, and `docs/captain-hold-lifecycle.md` owns the mechanism.

| Drain section | What it prints |
| --- | --- |
| OPEN DECISIONS | Every decision the fold still holds open, including one buried under later appends. |
| UNREAD STATUS | `note:` lines and reserved-key pending-reply resolutions, once. |
| RECORD DIVERGENCE | Keys the status fold went quiet on while the durable captain-held task still shows them open. |

A failed read, output, or concurrent-replacement check prevents the snapshot cursor from advancing across uncertain bytes.
Teardown retires a task's manifest row before that task ID can be reused.

### Closing a decision

The explicit resolution is written by the actor that answers, not the busy worker.
`fm-send`'s `--resolve-key` appends the closing `resolved` line to this home's own copy of the ledger at answer time.
That covers crewmates, local secondmates, and remote secondmates identically.
A remote mate's escalations reach that local copy through the parent-replies ingest, and only the answer message itself crosses the transport.

This home's answerer close, pending-reply escalation close, and captain-held transfer use the provenance-guarded append owned by `bin/fm-wake-lib.sh`.
That append records the exact byte range it appended, so a later wake scan can tell this home's own growth from a foreign write instead of waking on it.

The watcher marker advances past those bytes only when every earlier byte was already classified by the watcher or listed as an open decision by the OPEN DECISIONS fold.
Any other earlier line, including a worker line the fold read but never listed, and any interleaved foreign write, fails toward an ordinary wake.

A turn-ended-only queue row omits its historical status annotation when that status file exactly matches the same seen marker.
Any direct or remaining historical annotation prints every status line unread at the presentation cursor instead of replaying only the latest line.
The owned-append ledger only decides whether growth wakes this home.
It never removes a line from presentation, so both that annotation and the UNREAD STATUS section still print this home's own bookkeeping closes.

### Current-state reads

`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review.
It attributes an active or terminal no-mistakes run under the shared run-attribution contract, then keeps that run-step authoritative even if the pane has closed.
The exception is a `blocked:` event reporting a refused or missing daemon socket.
That event outranks a potentially stale active run record only while the socket-down declaration is itself the log's latest recognized event.
Any later event, including another `blocked:` one, means the crew moved on.

For other daemon, timeout, or unreachability claims, a running or fixing run with recent pipeline-reported activity supersedes the event.
The read then names reattachment as the recovery instead of surfacing a false block.

[`bin/fm-nm-run-lib.sh`](../bin/fm-nm-run-lib.sh) owns branch, head, and pipeline-custody attribution, plus complete same-branch run selection, optional inventory lookup, and ambiguity reporting.

A run executing on the crew's own branch is current regardless of head.
The pipeline rebases that branch and commits its fix rounds in its own checkout, so reading an older run that still matches the local head would report a working crew as failed.
Every other run, parked or terminal, still binds on head equality or ancestry, or on the pipeline's own custody attribution while it owns the branch.
That head-free live bind is withdrawn once an explicit `daemon status` probe answers that the daemon is down.
[`tests/fm-crew-state.test.sh`](../tests/fm-crew-state.test.sh) covers run selection; its [capture provenance and live-evidence limits](../tests/captures/no-mistakes-v1.70.1/README.md) distinguish recorded inputs from composed scenarios.

#### CI monitoring

During no-mistakes' `ci` monitor phase, `bin/fm-crew-state.sh` also reads the full ci step log.
It does so because `axi status` reports both "still waiting on checks" and "checks green, waiting on merge" as `ci,running`.
The most recent recognized ci log marker wins.
So checks-green monitoring reports done, while a later failed-check, checks-running, or issue marker returns the crew to working.
A base-branch timeout re-arm is not a marker, because it leaves readiness unchanged.
`bin/fm-crew-state.sh` owns the evidence guard that recognizes ended CI monitors after green checks, including cancelled runs and skipped rebase steps.
A passed run alone never proves a forge merge.

#### When the daemon is down

In the coarse runs-ledger fallback, which has no steps table and no ci log, a terminal failed record whose daemon an explicit `daemon status` probe proves down reports unknown as unverified instead.
An instrument failure must never read as work failure.

The same instrument rule covers the ledger-anchored continuation of a selected run whose head this copy cannot resolve.
Once the probe answers down:

- That still-executing record reports unknown as unverified.
- A run parked at a gate keeps its gate and findings, because an open decision stays open when the instrument dies.
- A `needs-decision` or `blocked` event the crew observed first hand stays open, with the unverified record named as the reason rather than superseded by it.

#### When no run matches

`bin/fm-crew-state.sh` consults semantic busy state only when no matching run exists:

| Busy verdict | Reported state |
| --- | --- |
| Exact busy | Working. |
| Exact idle | Fallback to the log's resolved current declaration, when its verb maps to a recognized run-state. |
| Unknown, or a dead pane | Unknown, instead of trusting a stale log. |

The resolved current declaration is the newest decision the fold still holds open, otherwise a declared wait still standing after later resolved lines for other keys, otherwise the latest recognized event.
Decision-only events such as `resolved` never become current state or leak their prose into the current-state detail.
In that status-log fallback, a declared external wait reports the distinct `paused` state with its reason.
The semantic branch reports working only on an exact busy verdict and names the source that produced it.
An unknown verdict never becomes working, never permits the status-log fallback, and never becomes a silent idle.

### Published contributions

Published-contribution records, PR verdict freshness against the observed current head, actor classification, measured coverage, and incoming forge signals are owned by `bin/fm-contributions.sh` and verified by `tests/fm-contributions.test.sh`.
GitHub PRs and issues are observed.
Unsupported forges remain disclosed as unmeasured coverage rather than fleet work.
The existing Bearings Captain's Call consumes that coverage, and its skill owns supervisor triage through existing captain holds and durable check wakes.

### Fleet snapshot

For whole-fleet review, `bin/fm-fleet-snapshot.sh --json` emits schema `fm-fleet-snapshot.v1` from:

- The backlog.
- Task metadata.
- Local current crew state.
- Supervision-owned endpoint evidence.
- PR/report pointers.
- Scout reports.
- Bounded current summaries from registered secondmate homes.
- Secondmate return-channel guidance.

Each home atomically publishes that bounded home summary with freshness epoch metadata at `state/home-summary.json`.
It publishes after a locked session start, a watcher-observed status change, task spawn, task teardown, and on a recurring live-watcher cadence.
`bin/fm-home-summary-refresh.sh` owns the publication mechanics.

The fleet snapshot and Bearings paths use the concurrent remote-ledger collection, cache, unreadable-home disclosure, and remote-liveness boundary owned by `bin/fm-fleet-snapshot.sh`'s header.
`bin/fm-fleet-view.sh` renders that snapshot as Markdown for humans, while `bin/fm-bearings-snapshot.sh` provides the bounded bearings projection.
So both views consume one structured contract instead of reparsing raw fleet files.
The `bin/fm-fleet-snapshot.sh` script header owns the exact JSON schema.

### Supervision on a Pi primary

On a Pi primary, supervision is default-on.
The watcher extension can hand two kinds of work to a persistent in-process supervision conversation, called the branch:

- Eligible task-local rows from an ordinary actionable wake.
- Selected fleet-wide heartbeat reviews.

Main-only rows remain on the captain-facing path.
The branch handles those rows, stores the outcome durably, and merges it back into main.

A captain-facing outcome persists as one exact, sequence-keyed visible transcript entry.
It then opens one sequence-keyed processing turn on main, which only main's sequence-bound acknowledgement closes.

[docs/pi-supervision-branch.md](pi-supervision-branch.md) owns row eligibility, dispatch architecture, deterministic outcome delivery, and processing re-presentation.
The generated [Pi supervision protocol](supervision-protocols/pi.md) owns MAIN's merged-event handling and acknowledgement duty.
[supervision-host.md](supervision-host.md) covers the opt-in supervision host that runs the same branch contract beside a non-Pi primary, away and on Claude and Cursor also attended.

### Registered secondmate current state

A registered secondmate's validated home is the authority for bearings current state, because it owns:

- The child metadata inventory.
- Each child's current-state result.
- Endpoint observations.
- Backlog holds and dependencies.
- Keyed unresolved decisions.
- The recent Done baseline.

The original cross-home projection instead treated the secondmate agent as an ordinary parent task.
So an idle secondmate's `fm-crew-state` fallback selected the latest append-only parent status event, even when structured state in the registered home contradicted it.
The parent-status contract also required explicit keyed resolution for decisions and blockers but not for a material `working` phase.
So a start event could remain unsuperseded after the corresponding home backlog had moved the work to Done.

Generated secondmate charters:

- Reject generic receipt or start acknowledgements.
- Key only supervisor-actionable material phase reports.
- Close an opened phase with a same-key later state or `resolved` event.

The structured home remains authoritative even if that closure is missing.

Cross-home reads validate the seeded identity and operational-directory boundaries.
They classify unavailable, malformed, or inconsistent structured state as unknown, rather than reviving a parent event as current work.
`bin/fm-fleet-snapshot.sh`'s header owns collection, cache selection, and unreadable-home behavior.

When only an owned child's current classification is unavailable, the home classification stays unknown.
Independently trustworthy structured decisions, holds, queued and landed records, endpoint identities, counts, and provenance remain available in that case.
Every other invalid path stays strict and exposes none of those child-derived surfaces.

A bounded direct-report terminal tail can help diagnose a mismatch by showing that historical parent wording is still visible.
But it is untrusted supplemental evidence, because scrollback, prompts, copied output, idle shells, and agent prose are not durable state.
The snapshot strips control sequences, retains only capture metadata and literal event-corroboration flags, and never lets terminal evidence override a valid structured classification.
Live GitHub enrichment exists only behind the bearings `--include-prs` opt-in.
Optional Relay integrates with the watcher only after explicit opt-in; [configuration.md](configuration.md#relay-env) owns its generated-artifact and dispatch mechanics.

### Supervision block and watcher arming

At session start, `bin/fm-session-start.sh` emits exactly one primary-harness supervision block rendered by `bin/fm-supervision-instructions.sh` from `docs/supervision-protocols/`.
That block owns the live wait shape for the running primary harness:

| Primary harness | Live wait shape |
| --- | --- |
| Claude | Its Stop `asyncRewake` hook owns tokenless re-arm cycles. |
| Cursor | Its stop hook parks on the watcher. |
| Grok | Background-notify cycles. |
| Codex | Bounded foreground checkpoints. |
| Pi and pi-signed | The same two tracked primary extensions. |
| omp | Its own two tracked `.omp/extensions/` files. |
| OpenCode | Its TUI plugin. |

`bin/fm-watch-arm.sh` remains the verified arm wrapper for protocols that call it.
It:

1. Forks the watcher as a tracked child.
2. Verifies it is genuinely alive with a fresh liveness beacon.
3. Prints an honest `started`, `attached`, or nonzero `FAILED` status.

[`watcher-continuity.md`](watcher-continuity.md#arm-layer-cycle-contract) owns the arm layer's successor, terminal-delivery, re-arm recovery, and typed clean-close failure contract.
The arm layer records one bounded lifecycle row per observed cycle in `state/.watch-cycle-exits.log`.
`state/.watch-triage.log` remains exclusively the absorbed-wake debug log.

Pi, omp, and OpenCode verify session-lock ownership and launch one singleton successor from their child-close handlers before delivering an actionable wake prompt, with bounded exponential retry for failed restoration.
Pi additionally retains an established predecessor across ordinary same-process session shutdown until the replacement generation commits its tracked arm.
Its active-versus-handoff generation marker prevents an absent replacement extension from satisfying the fresh-beacon handoff tolerance.

Claude's `bin/fm-claude-stop-autoarm.sh` hook fires on every Stop.
When the home is eligible and still needs supervision, the hook:

1. Claims one home-scoped cycle.
2. Foregrounds the arm wrapper (or the [opt-in supervision host](supervision-host.md)).
3. Translates actionable closes into exit-2 rewakes.

It suppresses failed-looking closes when the same identity-matched watcher is healthy, and it retries genuine failures within a bound.
It coordinates exhausted failure episodes with the Claude turn-end guard as documented in [`turnend-guard.md`](turnend-guard.md).
[`watcher-continuity.md`](watcher-continuity.md) owns Claude's residual active-turn coverage and watcher-status command-gating boundary.

Cursor's `bin/fm-turnend-guard-cursor.sh` hook is the same between-turns shape in one synchronous step.
It parks the awaited `stop` hook on the arm wrapper and translates an actionable close into one `followup_message`.
A generation baton makes an older park that is still running after the next `stop` claim stand down, instead of leaking a stale duplicate wake.

The existing turn-end guard remains the final backstop for every harness-engine protocol:

- pi-signed shares Pi's protocol.
- omp's blocking `session_stop` hook compels one continuation per turn.
- The `--claude` mode cooperates with the auto-arm claim.
- Cursor's `--cursor` mode renders a block as one bounded follow-up, because its `stop` step cannot be blocked.

Its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.

### Guards and backstops

A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output when:

- The primary checkout is tangled.
- Work, process-event sources, registered custom checks, or Relay polling has an unhealthy model-aware supervision verdict.
- On main only, queued wakes are waiting for main itself to drain.

The drain script calls that guard after presenting the queue.
Records remain durable until the exact generation-bound acknowledgement printed by the drain succeeds after handling, and main may keep the queued-wakes warning visible until then.

Teardown also prunes a torn-down task's own pending rows under the queue lock, so a finished task cannot re-wake the fleet.
The pruned rows are:

- Stale wakes for its target window.
- Signal wakes for its status and turn-ended files.
- Its check wakes.

The Pi supervision branch's deliberate queued-wake warning exception is owned by [`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners).
[`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the guard's per-actor counting, the advisory main gets for rows a live branch grant holds, and main's retirement of queue rows no actor could ever present or acknowledge.

The guard leads with a prominent bordered tangle banner.
`bin/fm-guard.sh` owns the watcher-down banner and reminder policy, so repeated guarded commands stay noisy without reprinting the full banner in the same episode.

On every verified primary harness, tracked hook integration gives the primary session a push-based backstop.
It acts when both of these hold:

- Work, a process-event source, a registered custom check, or Relay polling needs supervision.
- No supervision owner provably holds this home with a fresh beacon.

Then blocking-capable Stop hooks block, and nonblocking turn-end integrations force one bounded follow-up.
This push-based guard covers the main primary and genuinely marked secondmate homes, and exempts child crewmate/scout worktrees.
It is loop-safe per harness and is documented in [turnend-guard.md](turnend-guard.md).

### Away mode and the away record

Away mode is a posture of the one supervision session.
`bin/fm-afk-contract.sh` records it in `state/.afk-contract` in the same turn as `/afk`, with no wait for a further go.
The record is read back in plain sentences only after entry.
Entry is announced as hold-for-return only, because no phone channel exists.

The captain's away words are the whole mandate:

- The record owner's header is the single owner of the record schema.
- The words are recorded verbatim.
- By the captain's mandate, no parser, tokenizer, classifier, or grammar reads them anywhere.

The supervision session reads the words at the tail of every wake.
It acts on them by its own judgment at the moment an event makes them relevant, only through the guarded scripts under standing authority, never by analogy, holding for the return on doubt.
`bin/fm-branch-prompt.sh` "Postures" owns those execution rules.

What stays mechanical is exactly what a script can check without reading words:

- A merge green at its live head under the record lock.
- Synchronous merges only.
- The spend cap.
- The never-set.

Destructive, irreversible, and security-sensitive actions are never pre-authorizable, whatever the words say.

The record's presence is the posture on every harness.
`bin/fm-afk-launch.sh` owns entry and exit.
`bin/fm-afk-return.sh` archives the record and owns the return brief's ordered sections, including landed live task records that still owe cleanup, rendered from durable state.
Persistent secondmates are excluded from that cleanup section even if an older record carries a child's merged PR.

While the record exists, neither supervisor rechecks an item held for the captain.
A declared external wait names when it clears with `until`, for a condition-aware recheck in both postures.
That recheck occurs at the declared time or at the hours-long `FM_PAUSE_RESURFACE_SECS` bound, whichever comes first.

Who runs supervision while away depends on the primary harness:

| Primary | Away supervision |
| --- | --- |
| Pi and pi-signed | The ordinary supervision session, with main parked. |
| Opted-in non-Pi home | The [supervision host](supervision-host.md). |
| Remaining harnesses | The sub-supervisor daemon `bin/fm-supervise-daemon.sh`. |

On Pi and pi-signed the away daemon is no longer launched.
The ordinary supervision session continues under the record with main parked, so:

- The supervision branch takes every actionable wake.
- Captain outcomes accumulate for the return brief.
- Main's standing authority relocates to the branch through the guarded scripts, each keeping its own gate ([`pi-supervision-branch.md`](pi-supervision-branch.md#postures)).

A wake the branch cannot take and a watcher failure still reach main.

On an opted-in non-Pi home, the [supervision host](supervision-host.md) runs the away session instead of the daemon.

### Away-mode sub-supervisor daemon

A presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) still extends walk-away supervision on the remaining harnesses.
Once the record exists, the `/afk` skill starts it through the tracked foreground helper `bin/fm-afk-start.sh`.
After that, the watcher reverts to daemon-managed one-shot mode, and the daemon self-handles routine wakes in bash.

The watcher and daemon share `bin/fm-classify-lib.sh` for:

- Captain-relevant status verbs.
- Declared-wait vocabulary: a `paused:` external wait and a verified `captain-held` transfer alike, through one combined predicate.
- Status-scan primitives.

Terminal verbs remain captain-relevant.
A nonterminal progress verb cannot become terminal merely because its prose contains a legacy free-text token such as `merged`.
Bare legacy free-text lines remain compatible.
The shared latest-event read takes the most recent line that leads with a recognized verb, a legacy token, or an unrecognized status prefix.
So a bad declaration stays visible as itself, while continuation prose and trailing blank lines after a multi-line record cannot hide a declared wait.

Both supervisors decide a declared wait through the library's declared-wait read rather than that latest event.
So a later `resolved` line for a different phase key - including an `fm-send --resolve-key default` answer to a keyless decision - does not end a standing keyless or keyed `paused:` wait.
A resolved line for the wait's own key or any other later event still does.

Both supervisors classify the status bytes appended since they last classified that log, never its last line alone.
They report every actionable event through the captured endpoint before committing that position.
The watcher's `.seen-*` and `.hb-surfaced-<task>` markers and the daemon's `.subsuper-seen-status-<task>` marker independently track reported file state and successfully classified position.
As a result:

- An unchanged unreadable state reports once without advancing past unread content.
- A changed state retries.
- An unusable position re-reads the whole log.

A keyed `needs-decision` or `blocked` transition accepted by the whole-file decision fold is retired only when that fold retires it.
The fold retires it on an explicit close for its exact key, or on a terminal declaration by the ship or scout that owns the log.
A reserved-key transition the fold rejects surfaces as a reconciliation signal without becoming an open decision.
The fold remains the sole owner of open/closed semantics, including same-key reopening and reserved-key handling, shared with the durable OPEN DECISIONS surface.

The always-on watcher also uses that library's absorb classification on no-verb signals and first-sighting stale panes before status-log terminality is trusted.
The daemon maintains distinct wedge and declared-wait recheck cadences.
The daemon's declared-wait window ages against the crew's own latest status line rather than against pane busy state, because a declared wait can legitimately hold a pane busy.
Only a status append that stops declaring the wait ends that routing and restores wedge detection.
A wake already decorated as a possible wedge does not override the daemon's own declared-wait verdict either, so a declaration keeps its pane on the recheck cadence instead of the wedge cadence.

In away mode, seen-status dedupe does not clear possible-wedge aging for nonterminal progress, so housekeeping still re-escalates an unchanged idle pane at the configured bound.
Away-mode housekeeping has no worktree-write deferral of its own, so while `state/.afk` exists a quiet crew that is writing its own worktree still escalates as a possible wedge at that bound.

The daemon escalates captain-relevant events, plus a bounded recheck for a declared external wait that is still declared, as one batched, single-line digest.
That digest uses the canonical `away-supervisor` kind from `bin/fm-operational-input.sh`.
A Claude Code primary receives that owner's record-backed doorbell instead of the stripped invisible marker, so firstmate can distinguish the escalation from ordinary captain messages.
Captain-held transfers remain silent until return while the posture record exists.

#### Injecting escalations

The daemon's supervisor injection path supports tmux and herdr panes, with `FM_SUPERVISOR_BACKEND` and `FM_SUPERVISOR_TARGET` resolved independently from the task-spawn backend.
Pane existence, busy checks, composer checks, capture, and verified submit route through `bin/fm-backend.sh`.
The composer is the input area that injected text is typed into before Enter submits it.
Submit differs by backend:

- tmux keeps the same submit core used by the tmux send backend.
- herdr, for a Claude pane, types only into an empty composer and withholds Enter until that composer shows the typed payload.
  It then uses native agent-state submit confirmation on idle baselines, a composer empty fallback when native stays idle, and a pre-Enter rendered-footer transition when that baseline is unavailable.

The retries-exhausted queued-Enter decision is owned by `fm_composer_queued_enter_verdict` in `bin/fm-composer-lib.sh`; tmux and herdr provide only their backend-specific busy signals.

Composer classification has one shared owner, `bin/fm-composer-lib.sh`.
tmux, herdr, Zellij, Orca, and cmux contribute only a screen capture plus declarative styled, cursor, identity, and row capabilities.
The shared classifier owns every shape and the `empty`/`pending`/`pending-unproven`/`unknown` verdict.
`fm-spawn.sh` also routes Kimi launch readiness through that classifier instead of carrying another shape copy.

The daemon injects only into an affirmatively `empty` composer, so every other or future verdict defers.
Positive container proof is required, and a blank unidentified row or bare dead-shell prompt cannot receive an escalation.
The current operator boundary is in [Composer and injection safety](herdr-backend.md#composer-and-injection-safety).
Unsupported supervisor backends refuse at daemon startup.
Stalled escalation delivery writes `state/.subsuper-inject-wedged` and attempts a configured backend-independent active alert after `FM_MAX_DEFER_SECS` instead of silently deferring forever.

#### Returning from away

On an unmarked return, `bin/fm-afk-return.sh` owns:

- Ordered shutdown.
- The record archive.
- Durable catch-up evidence.
- The return brief.
- The fail-closed gate that keeps ordinary work behind every live firstmate-actionable blocker the away session could not fix.

### Steering delivery

`fm-send.sh` delivers every remote text steer and ordinary local text steer as a durable steering-inbox record plus a best-effort constant doorbell line (`bin/fm-task-inbox-lib.sh`).
The doorbell line is a shell no-op and is never typed into an endpoint classified as dead or missing.
That record surfaces once for recovery instead of walking the re-ring ladder (`bin/fm-task-inbox-lib.sh` header).

`fm-send.sh` also has a local-only typed plane: harness-native invocations and explicit backend targets.
That plane selects a pre-Enter popup-settle for slash commands and for codex `$...` skill invocations, using metadata-routed target `harness=` values.
It then adds its own `FM_SEND_SETTLE` pause after successful typed sends, so immediate peeks catch the receiving turn starting.
The sub-supervisor uses only the shared submit core and does not pay that post-submit pause.

### Data plane and control plane

Text for a worker to read and commands that drive a worker's process are separate planes.

`fm-send.sh` is the data plane and always routing-marks a `kind=secondmate` target.
That is right for a message and wrong for a lifecycle command, because a marked exit command arrives as chat the agent reasons about instead of executing.

`bin/fm-control.sh` is the control plane:

- It offers an allowlisted `interrupt`, `exit`, and transactional `relaunch` addressed to an exact task id.
- Per-harness mechanics are owned by `bin/fm-control-lib.sh`.
- Each verb has a verified postcondition.
- There is no arbitrary-text or raw-key entry point.

[`docs/agent-control.md`](agent-control.md) owns the verb contract, the capability matrix, the relaunch transaction, and the fail-closed boundaries.

## Busy state is semantic, per adapter

`bin/fm-busy-lib.sh` is the single owner of what "this worker is busy" means, and `bin/fm-busy-event.sh` is the only writer of the per-task records it reads.
Every classification returns a verdict of busy, idle, unknown, or dead together with the source that produced it.
So a consumer or a diagnostic can never confuse semantic state with a fallback.

### Lifecycle sources per adapter

Each converted adapter reports its own turn lifecycle through a machine-readable contract the vendor already exposes, rather than through rendered footer text:

| Adapter | Lifecycle source |
| --- | --- |
| Pi and pi-signed | The Firstmate-owned extension's `agent_start` and `agent_settled`, confirmed by `ctx.isIdle()`. |
| omp | Its extension's `agent_start` and `agent_end` without `willContinue`. |
| OpenCode | Its plugin's semantic `session.status`. |
| Claude | Owned `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd` hooks. |
| Muse | Its session log. |
| Cursor | Its conversation transcript. |

Kimi behind Pi inherits Pi's lifecycle.
Codex and standalone Kimi classify unknown behind explicit probes until a semantic source is live-verified for them.
Grok, Rovo, and AGY each keep one clearly isolated rendered-tail busy fallback that can only ever classify their own task.

### Launch-prompt backstop

The one case where the contract reads rendered text for a converted adapter is the launch-prompt backstop (`fm_busy_launch_prompt_parked` in `bin/fm-busy-lib.sh`).
It applies when both of these hold:

- A record is still the untouched `fm-spawn` seed.
- The caller supplied a captured pane matching that harness's own recognized interactive launch prompt - a workspace-trust dialog, sign-in screen, or first-run menu.

Then `fm_busy_classify` reports `unknown launch-prompt` instead of `busy fm-spawn`.
That keeps a launch that never began its brief from holding the busy-age exemption for the whole `FM_BUSY_TURN_MAX_SECS` bound.
Such a launch surfaces through the ordinary not-provably-working path instead.

A record any real hook event has advanced is never reclassified this way, however its pane looks.
No captured tail means the record's own state stands, and the general busy bound is unchanged.
The per-harness signature table lives in `bin/fm-busy-lib.sh`'s header, and [runtime backend verification](verification/runtime-backends.md#launch-prompt-backstop-signatures) owns the live evidence.

### Unknown is never idle or busy

Missing, malformed, stale, untrusted, or unverified semantic state is unknown, never idle, and unknown is never promoted to busy either.
Ordinary task-state consumers act only on an exact busy verdict.
So an unreadable worker surfaces for a closer look instead of being absorbed as still-working or written off as finished.
Endpoint death is the only process-level override and yields dead.
Child processes, CPU, process sleep state, and marker modification times are not state signals.
`state/<id>.turn-ended` files remain wake notifications, not current state.

### Incarnations and delivery checks

Each record is bound to an incarnation token minted when the task's wiring is armed.
So an event from a superseded incarnation is rejected rather than applied, and a record left behind by one classifies unknown.

Three rendered-text checks deliberately remain outside this contract because they answer delivery questions:

- Submit acknowledgement consumes the shared delivery-footer matcher owned by `bin/fm-composer-lib.sh`.
- The away-mode supervisor-pane busy guard consumes that same matcher.
- `bin/fm-pending-reply-lib.sh` owns the secondmate delivery-confirmation observation.

All are harness-scoped rather than a global pattern union, and none is a recorded worker state source.

## Runtime session backends

The runtime backend is the session-provider layer below firstmate's scripts.
It owns:

- Task endpoint creation.
- Bounded capture.
- Text/key sends.
- Current-path reads for spawn-time worktree discovery, when the backend does not create the worktree itself.
- Live-window fallback lookup.
- Agent-process liveness probes where verified.
- Endpoint teardown.

### Adapters and selection

`bin/fm-backend.sh` centralizes backend selection, `state/<id>.meta` helpers, metadata-only cleanup identity validation, selector resolution, and operation dispatch.

| Backend | Adapter | Support | Selection | Worktree provider |
| --- | --- | --- | --- | --- |
| tmux | `bin/backends/tmux.sh` | The verified reference adapter ([`docs/tmux-backend.md`](tmux-backend.md)). | Hard default, or auto-detected. | Treehouse |
| herdr | `bin/backends/herdr.sh` (P2) | Has its own required CI lane ([`docs/herdr-backend.md`](herdr-backend.md)). | Explicit, or auto-detected. | Treehouse |
| zellij | `bin/backends/zellij.sh` (P3) | Experimental task-spawn adapter with no dedicated real-backend CI lane. | Explicit only. | Treehouse |
| orca | `bin/backends/orca.sh` (P4) | Experimental task-spawn adapter with no dedicated real-backend CI lane. | Explicit only. | Orca |
| cmux | `bin/backends/cmux.sh` (P5) | Experimental task-spawn adapter with no dedicated real-backend CI lane. | Explicit, or auto-detected. | Treehouse |

[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns new-spawn backend selection precedence and authorization.

Runtime auto-detection is innermost-first: `$TMUX` wins over `HERDR_ENV=1`, which wins over cmux's primary `CMUX_WORKSPACE_ID` marker and documented fallback signals.
Auto-detected Herdr stays silent like tmux.
Auto-detected cmux prints a one-time notice because cmux remains experimental.
The zellij and orca backends are never auto-detected; they take only explicit selection.
Unknown backend names fail loudly.
For compatibility, default tmux tasks do not write `backend=tmux`; every reader treats a missing `backend=` field as `tmux`.

### Busy state and native events

`fm-watch.sh` decides each window's busy state through the semantic contract above rather than by polling the backend for rendered text.
Herdr's native `agent.get` verdict still participates, but only as evidence of activity:

- A native `busy` is accepted when the task has no record of its own.
- A native `idle` is not, because `agent.get` reports generation state and reads idle while a worker blocks on its own long-running foreground tool call.

tmux, zellij, orca, and cmux expose no native busy primitive at all, so a task on those backends is classified purely from its adapter's own lifecycle record.
That poll loop is still the default event source for backends with no native push events, so this stays an extraction of the abstraction rather than a watcher rewrite.
For capable Herdr sessions, the same watcher replaces its terminal sleep with a bounded native event wait that immediately surfaces `blocked`.
[Push events and polling fallback](herdr-backend.md#push-events-and-polling-fallback) owns the current mechanism and capability gates, while [runtime backend verification](verification/runtime-backends.md#native-blocked-event) owns the active evidence.

### Agent-process liveness probes

The deeper agent-process liveness probe is separate from that busy-state poll.
It is shared by the session-start sweep and the watcher's liveness tick through `bin/fm-secondmate-liveness-lib.sh`:

- tmux and Herdr have verified classifiers for secondmate recovery.
- Zellij remains unverified.
- Orca and cmux do not support secondmate spawns.

### Herdr backend

Herdr can be selected explicitly or by runtime auto-detection.
Treehouse remains its worktree provider.
[`herdr-backend.md`](herdr-backend.md) owns current setup, CI coverage, and safety limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) owns active empirical evidence.
Herdr uses one tab per task; [Watching and task containers](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, and recovery scope.

Its default-on presentation projection may place one clean new task in a disposable workspace without changing endpoint authority or lifecycle ownership.
[Presentation spaces](herdr-backend.md#presentation-spaces) owns that conditional design, the Herdr version floor its unconfigured default is gated behind, and its narrow home-local restored-shell cleanup at locked session start.

### Zellij backend

Zellij is experimental and selected only explicitly.
Treehouse remains its worktree provider.
[`zellij-backend.md`](zellij-backend.md) owns current setup and limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#zellij) owns active empirical evidence.
Zellij's container shape is simpler than herdr's: one shared `firstmate` session, one tab per task, with no per-home workspace split.
Visible tab titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path.

### Orca backend

Orca is experimental and selected only explicitly.
Orca owns both worktree and terminal lifecycle, and records `orca_worktree_id=` and `terminal=`.
It removes worktrees through `orca worktree rm` only after the usual firstmate teardown checks pass.
[`orca-backend.md`](orca-backend.md) owns current behavior and limitations, while [`verification/runtime-backends.md`](verification/runtime-backends.md#orca) owns active smoke evidence.

### cmux backend

cmux is experimental, GUI-first, and macOS-only.
It can be selected explicitly or by runtime auto-detection from its primary `CMUX_WORKSPACE_ID` marker plus documented fallback signals.
Treehouse remains its worktree provider.
[`cmux-backend.md`](cmux-backend.md) owns current setup and limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#cmux) owns active source and live evidence.
cmux's container shape is one workspace per task with one surface, and no per-home container split.
Workspace titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path.
`--secondmate` spawns are refused, mirroring Orca.

### Codex App

Codex App support is recorded in `docs/codex-app-backend.md`; it is not selectable as a runtime backend.

## Worktrees, not branches in your checkout

Crewmates never intentionally touch the project clone.
[treehouse](https://github.com/kunchenguid/treehouse) pools clean worktrees for tmux, herdr, zellij, and cmux tasks, while Orca creates its own worktrees for `backend=orca`.
The [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns ship/scout worktree isolation and fresh-base refusal rules, including spawns from linked homes.

Portable regressions live in:

- [`tests/fm-spawn-pool-base-freshen.test.sh`](../tests/fm-spawn-pool-base-freshen.test.sh), for spawn isolation and base freshness.
- [`tests/fm-control-relaunch.test.sh`](../tests/fm-control-relaunch.test.sh), for preserving the recorded copy on relaunch.

### The firstmate repo working on itself

The firstmate repo has one extra exposure because it can dispatch crewmates to work on itself.
Its operating checkout (`FM_ROOT`) and the disposable crewmate worktrees are all linked git worktrees of the same repository.
So the valid discriminator is branch state, not whether the checkout is linked:

- The primary checkout is healthy on its default branch.
- Linked worktrees or secondmate homes are healthy at detached HEAD.
- Only a named non-default branch checked out in `FM_ROOT` is a worktree tangle.

### Detecting and preventing a tangle

`fm-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`fm-guard.sh` prints the repair command on the next mutable fleet action.
`bin/fm-session-start.sh` reports the same condition through bootstrap as a `TANGLE:` line at session start.
If another live session holds the fleet lock, both surfaces keep the alarm but switch to read-only wording with no repair command.

Ship briefs also tell the crewmate to verify `pwd -P` and `git rev-parse --show-toplevel` before creating its ship branch (`fm/<id>` by default, or the project's registered prefix).
The briefs also tell it to stop with a blocked status if it landed in the primary checkout.

Placement is proven only at launch.
So `bin/fm-spawn.sh` also exports the task id as `FM_TASK_ID` into every ship and scout pane, and `bin/fm-test-run.sh` refuses to execute the behavior suite from the primary checkout while that marker is set.
The runner's header owns the predicate and [`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh) pins it.

## No-mistakes gate authority boundary

Firstmate's own no-mistakes gate runs agents inside a checkout that also contains the fleet-captain identity in `AGENTS.md`.
So gate execution needs an authority boundary separate from ordinary crewmate worktree isolation.
Two independent protections provide it.

The tracked `.no-mistakes.yaml` sets `disable_project_settings: true`.
no-mistakes honors that setting only from the trusted default-branch copy, so a pushed branch cannot enable its own project instructions during validation.

Independently, the fleet lifecycle entrypoints use `bin/fm-gate-refuse-lib.sh` to refuse gate calls against the real fleet.
They still permit validation against a disposable lab home minted by `bin/fm-lab-home.sh`.

A normal primary checkout or crewmate worktree remains unaffected.
The refusal library's header owns the gate detection, lab-home exception, test-harness bypass, and relationship to no-mistakes' HEAD-continuity guard.
The lab helper's header owns its usage.

## Two task shapes

| Shape | What it does |
| --- | --- |
| Ship | Changes projects and ships by project mode (`no-mistakes`, `direct-PR`, or `local-only`). |
| Scout | Leaves standalone investigation reports at `data/<id>/report.md` and never pushes. |

The intake and authority contract in `AGENTS.md` owns when separate scout research is warranted.

## Dispatch profiles

Crewmate and scout dispatch can stay on the static crewmate harness resolved by `config/crew-harness`, or it can use local dispatch profiles in `config/crew-dispatch.json`.

The dispatch file is intentionally judgment-based.
At intake, firstmate:

1. Reads the natural-language rules.
2. Chooses the best matching rule.
3. Resolves profile arrays itself from current quota output, under the `AGENTS.md` section 4 intake boundary and the `quota-array-dispatch` selection procedure.
4. Passes only concrete `--harness`, `--model`, and `--effort` axes to `fm-spawn.sh`.

The shell scripts validate the JSON shape and verified harness/effort combinations.
They do not parse task intent, match natural-language rules, or own array selection.
The session-start bootstrap step keeps valid dispatch configuration silent unless verbose facts are enabled, and surfaces a concise invalid-config line when validation fails.

When the file exists, `fm-spawn.sh` refuses crewmate and scout launches without an explicit harness.
So `config/crew-harness` is only automatic when no dispatch profile file is active.
Secondmate launches are exempt because they resolve the secondmate harness and any optional secondmate model or effort tokens instead.

Unsupported effort values are still recorded in task meta when passed to `fm-spawn.sh`, but the launch template omits any effort flag that the selected harness does not accept.
That keeps spawn launch compatible across claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, gemini, muse, rovo, omp, agy, and devin while preserving the requested profile for later audit.

## Optional secondmates

`data/secondmates.md` records persistent secondmates with natural-language scopes, project clone lists, and home paths.

### Local and remote routes

A local route points directly at its home.
A remote route adds an SSH alias and remote Firstmate code root, so the entire home and all of its child work stay on that host.
Remote placement pins the remote second-mate agent to Herdr while leaving the remote home's worker backend selection independent.
Every non-doctor primary-to-remote `fm-on` command runs through the remote account's Firstmate-owned job worker rather than its SSH process or a Herdr pane.
[`remote-secondmates.md`](remote-secondmates.md) owns current setup, supplied-origin provisioning, transport, relay, failure, and retirement behavior.

### Seeding and launching a home

`fm-home-seed.sh` provisions a local isolated home:

1. It clones the listed PR-based projects into it.
2. It initializes newly cloned `no-mistakes` projects.
3. It copies the charter to `data/charter.md`.

`fm-spawn.sh --secondmate` then launches it through the same session-provider and status-file path as any direct report.

For a domain whose subject is the firstmate repo itself, a deliberate `--no-projects` seed creates a project-less home whose crews take pooled worktrees of that repo instead of separate clones.
The signal cannot be mixed with project names or omitted accidentally, and a populated home cannot be converted in place.
The full seed contract is in [configuration.md](configuration.md#secondmate-routes-datasecondmatesmd).
Herdr secondmate and child placement follows the launcher-binding contract in [Watching and task containers](herdr-backend.md#watching-and-task-containers).

When seeded with `-`, the home is a durable treehouse lease under the secondmate id.
So it survives with no live process and is not recycled by later `treehouse get` or pruning.
Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
If returning the lease fails during teardown, firstmate leaves the route and home intact instead of hiding a still-held lease.

Seeding is transactional.
If validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

### Scope and idle behavior

`local-only` projects stay with the main first mate because they merge into the main local checkout instead of a remote-backed PR path.
The same project may appear in multiple secondmate homes when their scopes differ, such as issue triage versus feature development.
Secondmates are idle by default.
After startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.

### Messages to a secondmate

Metadata-routed `fm-send.sh` requests to a live `kind=secondmate` use the live-charter-compatible `from-firstmate` carrier owned by `bin/fm-operational-input.sh`.
That applies when called with `FM_HOME=<this-firstmate-home>` or when `FM_HOME` is already set to the active firstmate home.
So the secondmate returns terse answers through status lines and detailed answers through docs plus status pointers, instead of replying only in its own chat.

The parent guards every reply-bearing marked request against a missing correlated report without reading the secondmate conversation.
`bin/fm-pending-reply-lib.sh` owns the correlation, recovery, escalation, and retention contract, while `bin/fm-send.sh` owns the explicit fire-and-forget exception.
Explicit backend-target sends and direct human typing stay unmarked, so captain intervention in a secondmate pane remains conversational.

### Backlog handoff

After seeding a secondmate, `fm-backlog-handoff.sh`:

1. Validates the fleet-specific handoff.
2. Atomically delegates already-judged in-scope queued item moves to `tasks-axi mv`.
3. Attempts a marked routed-work wake through the receiver's recorded endpoint.

The [`fm-backlog-handoff.sh`](../bin/fm-backlog-handoff.sh) header owns route-specific wake outcomes, remote outbox release after receipt, and stable wake-correlation retry behavior.
`tests/fm-backlog-handoff.test.sh` and `tests/fm-remote-backlog-handoff.test.sh` pin the local and remote delivery boundaries.

An unreachable remote host is unknown rather than dead.
It preserves its route and durable work, and is never failed over or relaunched locally.
Idle secondmate panes are healthy.
Teardown is explicit and refuses while the secondmate home has in-flight work, unless the captain has approved discard with `--force`.

### Version convergence

Secondmate homes converge conservatively to the primary's version and declared inherited local material at launch and during locked session start.
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns the full guarded sync, propagation, nudge, and mid-session local-material push contract.

### Secondmate harness, model, and effort

Secondmate agents can run on a different verified harness than crewmates.
`config/secondmate-harness` controls the primary's secondmate launch harness.
It may also carry optional model and effort tokens as `<harness> [<model>] [<effort>]` on the first non-empty, non-comment line.

- A bare harness line remains harness-only, so existing `config/secondmate-harness` files keep their previous behavior.
- When the harness token is unset or `default`, launch falls back to `config/crew-harness`, then to the primary's own harness, and the model and effort tokens are ignored.
- Those optional tokens are re-read on every secondmate spawn or respawn and are overridden by explicit per-spawn `--model` or `--effort` flags.
- For a local route, an explicit per-spawn harness or raw launch command does not inherit model or effort tokens from `config/secondmate-harness`.
- Remote routes accept verified harness adapters only and reject raw launch commands.

`config/crew-harness` remains the crewmate harness and is inherited into secondmate homes.
`config/crew-dispatch.json` is inherited too; secondmates use the same natural-language dispatch profiles when spawning their own crewmates.
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns the inherited-local-material propagation contract and points to the implementation's item declaration.

The `data/secondmates.md` line contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), and the secondmate environment variables are documented in [configuration.md](configuration.md).

## Delivery modes are explicit per task

| Mode | What the task does |
| --- | --- |
| `no-mistakes` | Runs the full validation pipeline. |
| `direct-PR` | Opens PRs without that pipeline. |
| `local-only` | Stays local until firstmate performs an approved fast-forward merge. |

### Mode and merge posture at intake

Each task's mode and `yolo` merge posture are firstmate's decision at intake.
The mode is passed explicitly to `bin/fm-brief.sh`, and both values are passed explicitly to `bin/fm-spawn.sh` and `bin/fm-promote.sh`.
Each command refuses to guess the values it consumes.
A ship brief records its mode as a fixed machine-readable line, and the spawn refuses to launch on a different one.
So the worker's instructions and the recorded task delivery cannot diverge.

`bin/fm-dod-lib.sh` is the one owner of that mode's definition of done.
That definition is rendered into:

- A generated ship brief.
- The ship instructions a promoted scout receives.
- That scout's own `brief.md`, so a later relaunch reads the same contract.

So a promoted worker cannot be handed a weaker contract than a briefed one.
`bin/fm-dod-lib.sh` also owns the named-head reachability gate that refuses a ship `done:` while that head exists only in the worker's disposable copy.
The gate tests the named head rather than whether some branch moved.
`bin/fm-crew-state.sh`, `bin/fm-pr-check.sh`, and the secondmate ledger-first publisher call that same gate before treating a ship `done:` as ready.
`bin/fm-dod-lib.sh` is also the one owner of the no-mistakes `--intent` contract those workers follow.

`data/projects.md` records each project's standing posture and optional `+yolo` merge flag as the captain's default and as context for that decision, including the conditional `no-mistakes-prod-only` policy.
A ship spawn that drops below the registered rigor prints a deviation notice and continues.

### Forge bindings and Gerrit

The registry's optional `forge=` token is different in kind.
It is the captain's confirmed project fact rather than a standing default, and it is orthogonal to both the mode and `+yolo`.
It changes what a publishing mode publishes rather than firstmate's latitude over it ([gerrit-forge-integration.md](gerrit-forge-integration.md) is the design).

On a `forge=gerrit` project, both `no-mistakes` and `direct-PR` end with the worker publishing one squashed change through `gerrit-axi`.
The worker reports `done: PR <change url> published for review`, which `bin/fm-pr-check.sh` registers like any PR URL.
A `no-mistakes` task first runs the pipeline with its push, PR, and CI steps skipped, recovers the pipeline's fix commits, and lists each finding and its fix in a `note:` line.
That lets firstmate relay what the squash's description hides.
`local-only` refuses a forge because it publishes nothing.
`yolo` is refused because a Code-Review+2 is a positive attributed claim that a named human approved.

Firstmate passes the binding unchanged to `bin/fm-brief.sh --forge` and never infers one from a remote, host, or protocol.
A ship spawn reads it from the registry through `bin/fm-project-mode.sh --forge` and refuses a brief that disagrees with it.
A promotion reads it the same way for the binding alone.
`bin/fm-forge-detect.sh` only proposes a binding at project-add intake; nothing re-derives one from a clone at use time.
`bin/fm-project-mode.sh` remains the one registry parser for the mechanical consumers that have no task in hand: fleet sync's `local-only` skip and home seeding's refusal and no-mistakes initialization.

### Ship-branch prefix

The registry's optional `branch=<prefix>` annotation overrides a project's ship-branch prefix (default `fm/`) the same way.
Firstmate resolves it via `bin/fm-project-mode.sh --branch-prefix` at intake and passes it explicitly to `bin/fm-brief.sh --branch-prefix`, which never reads the registry itself.
Each script's own header owns its side of that contract.

### Review diffs and validation evidence

When a selected delivery path calls for a diff, `bin/fm-review-diff.sh` refreshes the authoritative base.
When task meta records a GitHub pull-request `pr=`, it always fetches and compares against `refs/pull/<n>/head` by default, before falling back to the local branch with a warning.
Recorded `pr_head=` is only an offline fallback.
A GitLab merge request and a Gerrit change expose no such ref, so a task recording one of those diffs the local branch under that same warning, which is its current content.

Where a no-mistakes pipeline stores evidence in the repo, it publishes that PR-viewable validation evidence to an orphan evidence branch that shares no history with code branches.
So that evidence never enters the crew branch or the default branch.
This repo uses that setting, and its own `.no-mistakes/` directory remains local state that stays gitignored and is rejected by CI if tracked.
[`configuration.md`](configuration.md) owns the setting.

### Merging a GitHub pull request

PR-based task merges go through `bin/fm-pr-merge.sh`, which records `pr=` and any available `pr_head=` through `bin/fm-pr-check.sh` before calling the forge CLI.
The helper requires a full canonical URL and rejects malformed URLs or repo override flags before recording merge state.

A `https://github.com/<owner>/<repo>/pull/<n>` URL requires `gh` and `jq`.
It is merged only after live reads confirm all of these:

- The pull request is open.
- It is not a draft.
- It is mergeable and conflict-free.
- Every unwaived check is green at the current head.
- Every unwaived check the base branch requires has reported at that head.

Then `gh pr merge` binds that verified head with `--match-head-commit`.

A required check that never reported is absent from the checks list rather than red.
[`bin/fm-pr-merge.sh`](../bin/fm-pr-merge.sh)'s header owns required-context sources, producer identity, partial-read refusals, and attended check waivers.

A check run is green when its current run is green.
That rule exists because GitHub leaves a cancelled run in the rollup beside the passing re-run it triggered when the base branch advanced.
`bin/fm-pr-merge.sh`'s `github_checks_not_green` owns the rule.
It uses `startedAt` to clear only an older completed check run that a passing run with the same name provably replaced.
Unfinished check runs and non-green status contexts stay red.

`--auto`, `--admin`, and branch-deletion flags are refused unless `--attended-override` is passed for an explicit captain instruction.
That override never skips the live green check, the away-record read, or a captain hold.

### Merging while away

Away merge authority is read from the away-posture record and then acted on by the forge.
So the authority read and the synchronous forge command share the record's cross-subsystem lock, closing the common live-owner TOCTOU (time-of-check to time-of-use) race.
A lock that cannot be taken refuses the merge.

While the record exists:

- GitHub auto-merge is refused before submission.
- Any base whose rules cannot prove the absence of a merge queue is refused before submission.
- GitLab auto-merge flags or scheduled state are refused, while an immediate merge is forced with a final `--auto-merge=false`.

One branch-rules read failure does not refuse: a failure caused only by the repository's plan not exposing branch rules at all (GitHub's plan-upgrade 403).
That failure proves the absence of a merge queue on its own.
Every other failure to read that state still refuses.

This is deliberately confused-agent-grade, as `bin/fm-lease-lib.sh` defines that grade, rather than fully atomic.
Two gaps remain:

- A GitHub queue-rule or PR-base change after the queue-free preflight can still enqueue a merge that lands after its away authority lapses.
- Killing the lock-owning shell while its forge child survives lets stale-owner recovery admit archive or replacement before that child completes.

These are accepted limitations, not oversights.
Durable authority, landing re-verification, and child-lock handoff are outside this boundary.
`bin/fm-afk-contract.sh` owns the lock contract, while `tests/fm-afk-contract.test.sh` and `tests/fm-pr-merge.test.sh` pin the serialization and fail-closed merge behavior.

### Merging a GitLab merge request

A `https://<host>/<path>/-/merge_requests/<n>` URL (see [docs/gitlab-merge-watch.md](gitlab-merge-watch.md)) invokes `glab mr merge <n> -R https://<host>/<path>`, so the instance comes from the URL.
It adds no merge-method flag, because the project's own merge method applies.

That path merges only after one live read of the merge request confirms all of these:

- It is open.
- It is mergeable and conflict-free.
- Blocking discussions are resolved.
- A successful pipeline exists at the current head.

It binds the merge to that verified head.
Recorded metadata is never the authority for those conditions, because a rebase leaves it stale.

### Gerrit changes are never merged

A `https://<host>/c/<project>/+/<n>` Gerrit change URL (see [docs/gerrit-change-watch.md](gerrit-change-watch.md)) is recorded, watched, and read back like any other, but never merged.
Firstmate never submits a Gerrit change.
So `bin/fm-pr-merge.sh` refuses such a URL non-zero before any metadata read, forge read, or recorded state.

Submitting a change means first recording a Code-Review+2, a positive attributed claim that a named human approved it.
The server permitting self-approval is what makes that a policy boundary rather than a capability limit.
So the refusal is stated in the code rather than left as an absent provider branch.

### Confirming the landing

After either forge command returns, the script confirms the PR or MR actually landed.
Only a confirmed landing records a landed outcome.
A queued or unconfirmed request records none and leaves its poll armed.

On GitLab, an auto-merge-queued or unconfirmed request is reported without failing the run.

On GitHub, an outcome that is neither merged nor queued is refused loudly and non-zero, naming the observed state.
In attended posture, a base branch that requires the merge queue is refused with the concrete `--attended-override -- --auto --<method>` retry flags its configured method requires, rather than having a merge method chosen on the caller's behalf.
When the forge already accepted exactly those flags and the pull request still has not entered the queue, that refusal points at the queue state to re-check instead of echoing back the flags the caller just ran.
An auto-merge request is held to the same standard: `--auto` that leaves the pull request neither merged nor queued is refused rather than reported as success.

Every GitHub refusal states what it could not observe as plainly as what it did.
So each of these is named rather than left to look like a base branch with no queue at all:

- An unreadable branch-rule response.
- An unrecognised queue method.
- A merge queue no available read can see.

### Merge outcomes and authority

A confirmed merge leaves a durable role-routed outcome instead of living only in the merging agent's memory.
[`bin/fm-merge-outcome-lib.sh`](../bin/fm-merge-outcome-lib.sh)'s header owns its destination, shape, identity, normal-case deduplication, and at-least-once recovery.
The same emitter handles a merge firstmate performed and one its poll detected, while the watcher immediately delivers the emitter's local actionable poll row.

After the forge accepts firstmate's merge request, the merge path persists the resolved away or attended authority, bound to the task's canonical PR identity.
While the away-posture record exists, any green merge runs under away authority, and which merge the captain's words meant is the supervision session's reading.
A later merged poll consumes only that matching persisted value.
With no match, it records the landing as external rather than consulting a live away-posture record that may have been archived or replaced.
[`bin/fm-merge-authority-lib.sh`](../bin/fm-merge-authority-lib.sh)'s header owns resolution, private atomic persistence, identity-checked consumption, and retirement, while only the merge path gates on the answer.

### Teardown and worktree return

Teardown is fail-closed for ship worktrees:

- Dirty worktrees refuse.
- Committed work must be landed before the worktree is returned.

A pool worktree is only returned after teardown passes the slot-ownership proof.
A contradictory task record or a supported live endpoint refuses without touching either task, and no discard authority relaxes that.

A slot's own owner claim is written by the spawn that takes it, under the allocation lock, and is owned by [`bin/fm-wake-lib.sh`](../bin/fm-wake-lib.sh).
It covers a slot reassigned to a task that left no record the scan could reach.
A claim naming a different task releases nothing: teardown warns, names the claimant, and finishes only the task's own cleanup.
That is because Treehouse's own live process lease cannot answer ownership once the worker's exit releases it.

Allocation and return serialize on one project lock per machine-local Firstmate tree.
Every home reachable through local parent links shares that lock.
A home seeded from another machine anchors its own, because a lock taken on this filesystem is neither held nor observable across that boundary.

Before the worktree is returned, teardown concludes the task's own no-mistakes run when it is parked at a gate.
That includes a run whose head the task copy cannot resolve.
The shared runs-ledger continuation proof is the only recognition for that case, so cleanup never orphans a parked run the pipeline advanced past the submitted head.

[`bin/fm-teardown.sh`](../bin/fm-teardown.sh)'s header owns the landed-work proofs, slot-ownership proof, endpoint-close refusal, PR-discovery fallback, pre-teardown run conclusion, and stale-lock recovery procedure.
[`tests/fm-teardown-endpoint-safety.test.sh`](../tests/fm-teardown-endpoint-safety.test.sh) and [`tests/fm-secondmate-safety.test.sh`](../tests/fm-secondmate-safety.test.sh) pin the slot-collision boundary.

## Optional Relay

Relay is opt-in presence for the shared `@myfirstmate` bot on both public surfaces it supports, X and Discord.

### Enabling Relay and its authority

A user enables it by putting `FMX_PAIRING_TOKEN` in the firstmate home's gitignored `.env`.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`.
That token is standing authorization for firstmate to answer public mentions and act autonomously on normal reversible mention requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while its surrounding conversation context may still include other public accounts.

On the locked session-start bootstrap step, that token creates the local polling and watcher-cadence artifacts described in the [Relay configuration reference](configuration.md#relay-env).
Without the token, the locked session-start bootstrap step removes those artifacts on opt-out and otherwise stays silent, so non-Relay users see no behavior change.

### Receiving and answering mentions

Newly offered mentions are stored as `state/x-inbox/<request_id>.json` and wake firstmate once per retained request ID.
The [Relay configuration reference](configuration.md#relay-env) owns the durable offer-marker and re-offer contract.
Attached media stays in that stashed payload as URLs the responding agent fetches and views with its own tools, so the polling path itself never downloads third-party content.

The `fmx-respond` agent-only skill:

1. Drains that inbox.
2. Uses the preserved Relay conversation context for continuity, under the wire contract owned by the [Relay configuration reference](configuration.md#relay-env).
3. Classifies each mention as an actionable request, question, or pure acknowledgment.
4. Submits public-safe replies through `bin/fm-x-reply.sh`.

When a reply has a real visual artifact, `--image <path>` attaches one local PNG, JPEG, GIF, WebP, BMP, or TIFF to the relay's optional `{media_type,data_base64}` image object.
Actionable reversible requests run through firstmate's normal intake, backlog, dispatch, investigation, or ship lifecycle.
Work that completes in the answering turn gets one outcome reply.

### Longer-running work and follow-ups

Work that spawns a longer-running task gets an acknowledgement reply first.
`bin/fm-x-link.sh` records `x_request=`, `x_request_ts=`, `x_followups=0`, and optional reply-platform context in that task's `state/<id>.meta`.
Durable per-request context preserves the original platform and budget independently of task links and inbox cleanup.

That link therefore reaches only work whose task record lives in the answering home.
Work routed to a secondmate is bound instead by a typed promised-final commitment registered with `--work-home secondmate:<id>`.
`bin/fm-x-link.sh` refuses a non-local task with that path named, rather than leaving the public promise unbound.

Later milestone wakes use `bin/fm-x-followup.sh` to post up to three public-safe follow-ups through the relay's `connector/followup` endpoint, ending with a `--final` one for ordinary Relay-linked work.
A typed promised-final commitment owns its terminal reply through `bin/fm-public-followup.sh`.
After its receipt is validated, that owner asks the bound work home to remove any legacy link without posting another reply.
It routes a REMOTE secondmate clear through its SSH transport, with the registration's Relay request identity as the mutation guard.
The [Relay configuration reference](configuration.md#relay-env) owns the exact context retention, platform-resolution, and fail-safe posting contract.

If recovery relinks the same relay request onto a successor task, `fm-x-link.sh --carry-count <n> --carry-ts <epoch> --carry-platform <x|discord> --carry-max <n>` preserves:

- The consumed follow-up count.
- The original 7-day window.
- The reply split budget.

It does this instead of granting a fresh local budget or falling back to the wrong platform.
The follow-up helper forwards `--image <path>` to the same reply client when a follow-up needs an image.

Each follow-up is bounded by a local 7-day window and a 3-post cap.
A successful non-final post increments the counter and keeps the link.
Any of these clears the link:

- `--final`.
- Reaching the cap.
- The window lapsing.
- The relay itself rejecting an exhausted binding.

The helper is skipped for tasks that did not originate from a Relay mention.

### Dismissals, threads, and dry runs

Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh`.
It calls the relay's `connector/dismiss` endpoint and posts no text, then the local inbox file is cleared.

Concise replies stay single unnumbered messages.
Genuinely long replies are split by the client into bounded, numbered threads using the target platform's reply budget, with `texts` carrying the ordered chunks for the relay.
Splitting preserves fenced-code, paragraph, line, and word boundaries when possible.
If an image is attached to a split reply, the relay puts it on the first/opener message only and leaves later chunks text-only.

For preview testing, `FMX_DRY_RUN` makes `fm-x-reply.sh` and `fm-x-dismiss.sh` skip the public post or dismiss call and record the would-be payload under `state/x-outbox/`.
That record includes `texts` when the reply would be a thread, and an `endpoint` marker when the preview is a completion follow-up or dismiss.
The rest of the poll -> compose -> would-post loop still succeeds.
Attached images are recorded as compact `{media_type, bytes, source_path}` metadata in dry-run instead of base64 bytes.
Relay remains layered on top of the existing check mechanism without changing its request-handling behavior.

### Promised final replies

A promised *final* public reply is a stronger commitment than a milestone follow-up, because forgetting it is publicly visible.
It is therefore not carried in conversation memory at all.
Intake turns it into a typed `kind=public-followup` obligation owned by `tasks-axi public-followup`, and every later step reads that obligation from disk.

The mechanism boundary is deliberately narrow:

| Component | Role |
| --- | --- |
| `tasks-axi` | Owns the obligation state machine and the authoritative validation of a terminal result's source home, work id, generation, schema, outcome, and deliverables. |
| `state/x-context/` | Remains the only owner of the private full request context. |
| `bin/fm-x-reply.sh` | Remains the only thing that posts. |
| `bin/fm-public-followup.sh` | Composes those three and adds the activation gate, a private terminal-event inbox, the idempotent delivery sequence, and retained-loop disposition. |

Within `bin/fm-public-followup.sh`:

- Delivery stamps the registration delivered.
- `rechain` hands its thread binding to one follow-on obligation.
- `retire` is the only close.

Work routed to another home reports a *typed* terminal result through `bin/fm-public-followup-emit.sh`.
Firstmate never recovers the source home, work id, outcome, or deliverables by parsing a free-form `done:` sentence, and the child never learns the thread.
The emitter mirrors `tasks-axi`'s deliverable rules to reject correctable mistakes at their source.
Reconciliation still revalidates through `tasks-axi` and queues an at-least-once wake when `tasks-axi` refuses an event.

When that home is a remote secondmate, no local path reaches the owning home.
So the result is staged where the work runs, and the owning home pulls it over the same SSH route with `bin/fm-public-followup-collect.sh`.
Because a terminal event's id is derived from its identity tuple rather than generated, duplicate reports and restart replay converge without coordination.

Reconciliation rides the existing relay poll and the session-start digest instead of a new watcher, daemon, or timer.
Both are gated on the same `.env` activation contract, so a home that never opted into the relay executes none of it.
The [Relay configuration reference](configuration.md#promised-public-replies-statepublic-followup) owns the operator-facing contract, and the `fmx-respond` skill owns the procedure.

## Project memory belongs to projects

Project-memory ownership and the crewmate corrections-only boundary are defined in [`AGENTS.md` section 6](../AGENTS.md#6-project-and-knowledge-management).
`data/projects.md` stays a thin private registry.

For manual project initialization, [`bin/fm-ensure-agents-md.sh`](../bin/fm-ensure-agents-md.sh) owns the `CLAUDE.md` pointer, self-governance insertion, and case-variant file refusal.
Its header and help document the explicit mark for equivalent project-owned guidance.

## Operational memory routing

`/stow` sweeps the current session for durable knowledge that only exists in conversation and routes each finding to the most specific disk home.
The destination for each kind of knowledge, including project-intrinsic knowledge, is owned by [`AGENTS.md` section 6](../AGENTS.md#6-project-and-knowledge-management).

Memory writes use inspect-then-update rather than blind append.
The internal [`stow` skill](../.agents/skills/stow/SKILL.md) owns tier markers, decay, cold archival, and offload.

### Open work records

The same pass also persists open-work record state the session is holding.
That means filing a thread that was never recorded and correcting one the session knows went stale, bounded to the open work that session is actually holding.
It is deliberately not a reconciliation of durable records against repository or PR reality.
Its input is the volatile context, so it can only preserve what the session still knows, and no reconciliation that outlives a session exists today.
Task-scoped notes use `bin/fm-tasks-axi.sh show <id> --full` followed by `bin/fm-tasks-axi.sh update <id> --body-file <path>`, adding `--archive-body` when the prior body should remain recoverable.

### Skills and secondmates

The stow pass never writes a skill.
A separately executed, captain-approved migration may move conditional knowledge into a user-owned local skill excluded from the Firstmate clone.
Changes to Firstmate's tracked skills remain deliberate repository work through the normal PR pipeline.

Invoked in a primary home, `/stow` then cascades the same sweep to every registered secondmate, enumerated through `bin/fm-stow-cascade.sh`:

- Each home is accounted and curated against its own startup-memory allowance.
- A live secondmate sweeps its own session.
- A slow or unreachable home is reported as an exception rather than blocking the primary.

## Local clones stay fresh

The locked session-start deferred network stage, PR-based teardown, and merged-PR wake handling refresh remote-backed project clones when the clone is safe to move.
Wake-time refreshes can target a single clone by project name, so the primary home also catches up when a secondmate reports a merge from its own home.

Clean default-branch clones fast-forward to `origin/<default>`.
A clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.

These are reported as `STUCK:` with their behind count and left untouched:

- Dirty clones.
- Non-default branches.
- Detached HEADs with unique commits.
- Diverged defaults.
- Default branches checked out in another worktree.

Fetches blocked by an orphaned `.git/packed-refs.lock` use bounded retries and remove the lock only when the shared staleness proof can prove it abandoned.
[configuration.md](configuration.md#toolchain) owns the recovery details and tuning knobs.
Local-only projects, clones without an origin remote, and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin` without touching project clones.
It restarts every live second mate whose home the pass left on the target commit through a persist-gated replacement, including a home that needed no advance.
That is because a restart is also the only thing that re-resolves launch-time harness wiring.
The re-read nudge is retained only as the fallback for live agents whose runtime cannot prove a restart.
For a remote route, the configured code root updates from its own origin on that host before the persistent home fast-forwards to the code-root commit.

The primary update is fast-forward only.
A clean secondmate divergence may reconcile with `reset --keep` only when a three-way temporary-index proof shows its complete local tree result is already present at the target, including after a squash merge.
Dirty, uniquely diverged, offline, and off-default targets are reported and left untouched.
Genuine secondmate divergence remains visible through a durable reconciliation record until a later successful convergence clears it.
Local homes share the guarded fast-forward helper, while remote updates delegate the same safety decision to the configured host through the generic transport.
The procedure and outcome vocabulary are owned by the [`/updatefirstmate` skill](../.agents/skills/updatefirstmate/SKILL.md); the relevant script headers own the mechanics.

## Restart-proof

Fleet state lives in:

- Each task's session-provider backend: tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected.
- No-mistakes run records.
- Status event logs.
- Local markdown under `data/`, including `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`.
- Persistent secondmate homes.

For herdr, respawning after a server-restored layout closes and replaces confirmed no-agent or dead task-tab husks instead of requiring manual tab cleanup.
At session start and again on the watcher's bounded liveness cadence, confirmed-dead secondmate agent endpoints are closed and relaunched through the same secondmate spawn path.
Ambiguous liveness reads are left untouched to avoid duplicate supervisors.
`/stow` should run before an intentional reset when the conversation may hold durable knowledge that has not yet been written to disk.
After that, the next firstmate session can reconcile and carry on.

## Development notes

The current watcher reliability work combines:

- Always-on bash triage with a durable queue for actionable wakes.
- Generation-bound post-handling acknowledgement.
- Deterministic re-arm recovery after watcher downtime.
- A race-proof singleton lock.
- Duplicate self-eviction.
- Drain-time liveness assertion.
- A self-verifying tracked-child arm wrapper.

The away posture is the record `bin/fm-afk-contract.sh` owns.
[supervision-host.md](supervision-host.md) covers the opt-in non-Pi away session, and the `/afk` skill covers the remaining daemon-backed harnesses.
