# Watcher continuity

This document explains how Firstmate keeps the watcher re-armed after a wake, how wakes are ordered and acknowledged, and which tests and live evidence cover that contract.
Read it when debugging a supervision gap or changing a harness's re-arm path.

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.
In this document, an arm is one run of `bin/fm-watch-arm.sh`, which starts a watcher cycle or attaches to one and returns the cycle's reason.

| Topic | Section |
| --- | --- |
| Which component re-arms the watcher on each harness | [Ownership](#ownership) |
| What happens between an actionable close and the wake reaching the model | [Actionable wake ordering](#actionable-wake-ordering) |
| How a watcher-downtime episode is announced and retired | [Recovery episode acknowledgement](#recovery-episode-acknowledgement) |
| How each actor consumes the wake queue | [Per-actor acknowledgement](#per-actor-acknowledgement) |
| What `bin/fm-watch-arm.sh` guarantees about each cycle | [Arm-layer cycle contract](#arm-layer-cycle-contract) |
| Which test suites pin these contracts | [Regression coverage](#regression-coverage) |
| What is not guaranteed, and where live evidence lives | [Active limits and verification](#active-limits-and-verification) |

## Ownership

On Pi, omp, OpenCode, Cursor, and Claude primaries, one component owns re-arming the watcher.
Codex and Grok keep their own protocols; see [Manual recovery and other harnesses](#manual-recovery-and-other-harnesses).

| Harness | Re-arm owner |
| --- | --- |
| Pi | `.pi/extensions/fm-primary-pi-watch.ts` |
| omp | `.omp/extensions/fm-primary-omp-watch.ts` |
| OpenCode | `.opencode/plugins/fm-primary-watch-arm.js` |
| Cursor | `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) |
| Claude | `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) |

On a non-Pi primary, a home opted into the supervision host also changes what the owner runs; see [Supervision host](#supervision-host).

### Pi, omp, and OpenCode adapters

Pi's `.pi/extensions/fm-primary-pi-watch.ts`, omp's `.omp/extensions/fm-primary-omp-watch.ts`, and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter:

- Starts the next arm before delivering the wake prompt.
- Checks current session-lock ownership at launch.
- Preserves one child or scheduled retry at a time.
- Applies bounded exponential retry after an unexpected or failed close.

A failed follow-up never cancels continuity restoration.

### Pi session replacement

Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`:

1. `session_shutdown` changes the current generation's durable extension marker from `active` to `handoff`, but keeps its established arm child alive.
2. The owning `session_start` publishes a distinct active generation.
3. That `session_start` commits its tracked replacement arm.
4. Only after that commit does the replacement arm retire the predecessor.

A state-scoped replacement handoff carries every actionable close whose delivery overlapped `session_shutdown`, including:

- A main follow-up Pi accepted but had not yet consumed.
- Branch handling.
- A retiring child that reports after the successor claim.

A handoff marker never satisfies the extension-ownership tolerance.
So a running Pi process whose replacement did not load this extension is reported as missing, rather than borrowing stale load evidence from its predecessor.

A main follow-up counts as delivered once Pi accepts it, never once the model reads it.
The reason is that a follow-up queued while main is streaming joins the running run without a `before_agent_start`.
The extension header owns how consumption is observed and why it only decides what a replacement replays.

### omp session replacement

omp's replacement follows its own generation-owner contract in `.omp/extensions/fm-primary-omp-watch.ts`, whose header owns its differences from Pi:

- It retires the predecessor arm at replacement shutdown instead of retaining it across the handoff.
- It reports no shutdown reason, so every shutdown with a pending actionable close persists the handoff for the next owning `session_start` to replay.

### Cursor stop hook

Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary.
It re-arms by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up.
[`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its Pi-host stand-down, loop bounds, and supersession baton.

### Claude Stop hook

Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop.
On each Stop, an eligible primary with supervision need admits one home-scoped owner, which foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

### Claude session-lock ownership

The hook handles the session lock as follows:

- A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes.
- A live owner the session does not own, an absent lock, or a malformed lock keeps the competing hook inert.

Whether the session owns that lock is the shared `fm_session_lock_owned_by_self` verdict in `bin/fm-session-lock-lib.sh`.
That verdict accepts either of two cases:

- A recorded pid inside the current harness ancestry.
- A live lock recorded under this same trusted Claude session id.

With that verdict, a background session keeps arming after its transient helper chain is recycled.
[`turnend-guard.md`](turnend-guard.md#guard-predicates) owns the Claude guard's behavior when that live owner is genuinely another session.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.

### Claude arm failures

After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
The beacon is `state/.last-watcher-beat`, which only the watcher process touches.

- A cycle-end failure is benign when that live-watcher predicate is true.
  In that case the hook suppresses the arm output and continues silently.
- Only an exhausted failure with no verified watcher commits one last-resort notice for the continuous failure episode.
- A refused notice commit stays silent for a later retry.
- After a successful notice, later Stop cycles exit 2 without repeating it until the turn-end guard consumes the attended fail-open.

The Claude turn-end guard owns that notice commit contract, the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).

### Supervision host

On a non-Pi primary, a home opted into the supervision host runs `bin/fm-supervision-host.sh` in place of the arm its re-arm owner would start.
The host owns successive watcher cycles through the same arm.
It starts and confirms each successor before its engine handles an away wake, and it stops its cycle before handing a wake back.
So the recovery and acknowledgement contracts below apply unchanged ([supervision-host.md](supervision-host.md)).

## Actionable wake ordering

This section covers what each re-arm owner does between an actionable close and the wake reaching the model.

### Pi, omp, and OpenCode successor start

After an actionable Pi, omp, or OpenCode child close, the adapter:

1. Waits for the predecessor process to close.
2. Starts and verifies one singleton successor.
3. Confirms the handling handoff against that successor before scheduling the follow-up.
4. Delivers the original wake.

A complete Pi reason line can be observed while the predecessor is still finishing durable cleanup.
That line is retained for replacement handoff, but the adapter never treats that already-ready predecessor as its own successor.

If the handoff confirmation fails, the adapter retries it once against the current generation and successor.
A failed confirmation is a restoration failure: the adapter classifies the error, retires a successor that is no longer alive, and surfaces exactly one typed message.
A failed confirmation is never swallowed.

### Readiness timeout and retry

The adapter waits at most one readiness timeout per attempt.
If the successor is not ready in that time, the adapter sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.

If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, the adapter delivers the original wake with a typed continuity-restoration failure, even if every successor arm hung without reporting readiness.

This is deliberate Option B ordering.
Whenever restoration succeeds, the fleet is protected before the model handles the wake.
When restoration does not succeed, the model is never left blind.

### Claude handling successor

Claude's Stop hook also starts one handling successor before notification.
After an actionable foreground close, including an attached peer cycle that ended, the hook:

1. Launches `bin/fm-watch-arm.sh` with the closed arm's pid as `FM_WATCH_PREDECESSOR_ARM_PID`.
2. Waits for that arm's one status line.
3. Only then exits 2 with the wake.

A child of the hook cannot outlive its exit-2 rewake.
So that successor is the one deliberate detached launch in the continuity path:

- It runs under nohup.
- Its stdio is away from the hook's pipes.
- It has its own process group.

This is the shape `bin/fm-startup-network.sh` uses, and [`verification/supervision.md`](verification/supervision.md#detached-session-open-workers-survive-the-hook) verified that it survives the hook.

The next Stop's foreground arm attaches to that live cycle.
A successor that confirms no live watcher adds one line to the rewake banner and never withholds the wake.
The next Stop then re-arms as before.

### Durable queue and turn-end backstop

The durable wake queue preserves actionable events between a watcher close and the next drain.
The bounded turn-end guard enforces recovery at Stop when no watcher is live and no open generation claim is still deciding.
So a finished, hung, or identity-mismatched claim cannot suppress that recovery ([`turnend-guard.md`](turnend-guard.md#harness-integrations) owns that boundary).

The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce.
It enters its poll loop immediately and keeps scanning signals, stale panes, and checks.

### Manual recovery and other harnesses

- The model no longer re-arms after ordinary wakes.
- No PreToolUse hook denies fleet commands based on watcher status.
- A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
- Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
- Codex retains its bounded foreground checkpoint protocol.
- Grok retains its tracked background-task notification protocol.

No adapter starts a replacement with a fire-and-forget shell `&` from a model command.
The Claude hook's detached handling successor is launched by the hook itself, which waits for the successor's status line before it exits.

The turn-end guard remains the final backstop rather than the normal continuity mechanism.
In its `--claude` mode it cooperates with the auto-arm.

## Recovery episode acknowledgement

A recovery episode is one generation of the `state/.watcher-down` marker.
It is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.

### Announcement

An announced downtime generation is announced at most once while it stays announced.
The first recovery marks it announced, and later arms wait until a new down stretch reopens it.
A non-successor watcher start after an announced-but-unacknowledged episode is that new down stretch.
It returns the episode to pending so buried decisions still resurface.

The reopen keeps the episode's own generation rather than minting a fresh one.
A harness that re-arms only between turns reaches that reopen at every turn boundary, so minting there invalidated the acknowledgement the handling turn had already been given.
That acknowledgement then reported a newer episode and asked for a re-drain whose own acknowledgement the next boundary invalidated again - one firstmate turn per round, indefinitely, with no watcher alive in between.

### Generation reuse

Every watcher close and every durable queue append publishes downtime.
So a downtime republication of any pending episode reuses its generation instead of minting a new one, and an already-announced generation stays announced.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and from trapping later arms in repeated recovery presentation.

### What an acknowledgement retires

An acknowledgement carries two separable facts:

- Queue-row consumption is bound to the monotonic `--ack-through` sequence (further scoped per actor - see "Per-actor acknowledgement" below).
- Only retiring the episode is bound to `--recovery-generation`.

A generation mismatch therefore does not block consumption of rows through that sequence.
It is a non-fatal result that names its own remedy: re-drain, then acknowledge the newer episode.

The acknowledgement retires the marker whenever it settled what was presented.
It settled what was presented when it consumed rows of its own, or when it had none to consume and no presented row waits above its cutoff.

Consuming any row at all is enough, so the rule reaches wider than a wake appended after presentation.
A partial acknowledgement that consumes rows 1 to 3 of 5 presented retires the episode, and so does a branch actor's acknowledgement that consumes its own eligible rows while main-only rows remain queued.
Whatever is left stays queued and resurfaces through its own wake, or through the next cycle's recovery check on a non-empty queue, which mints a fresh announced episode for it rather than holding the current one open.
That costs one extra cycle before the leftover rows resurface.
Holding the episode open for them instead is what left a busy home with an episode no acknowledgement could ever retire, so every later start re-announced recovery instead of supervising.

A stale acknowledgement settles nothing, because it consumed none of its own rows while a presented row still waits above its cutoff.
It therefore leaves the episode open, and the remedy names that episode's live generation.
An empty-queue downtime publication during handling is likewise retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Per-actor acknowledgement

`bin/fm-wake-drain.sh` consumes the queue per actor, not per whole-queue cutoff.
It uses the `fm_lease_actor` identity owned by `bin/fm-lease-lib.sh`.
The Pi branch extension injects its branch actor into its own bash tool calls.

### Claiming rows

Every presented row is claimed to exactly one actor under the durable queue lock.

- Main records its presented set in `state/.main-eligible-rows`.
- A branch grant is published through `bin/fm-wake-grant.sh` under that same lock in `state/.branch-eligible-rows`.
  The grant is bound to the live branch process and extension generation recorded in `state/.branch-eligible-owner`.
  Publication is refused if main already claimed any requested row.
- A main drain validates that owner evidence under the queue lock and reclaims the grant when its process is gone or its identity no longer matches.
- A main drain claims every currently unclaimed row and excludes an active branch grant from both presentation and acknowledgement.

### Lock deadlines during presentation

An ordinary presentation drain bounds both its initial queue-lock acquire and its later status-presentation-lock acquire at the deadline owned by the script header.

| Lock with a live holder | Drain result |
| --- | --- |
| Initial queue lock | One PID-naming advisory, and the whole drain is skipped before any claim or mutation. |
| Status-presentation lock | One such advisory after raw wake presentation, and status annotations, sections, and cursors are left retriable on the next drain. |

Acknowledgement invocations and every other mutation-critical queue-lock acquire retain blocking semantics, so acknowledgement atomicity is unchanged.

### Guard counts for branch-held rows

Because the main drain's exclusion makes branch-granted rows invisible to main, `bin/fm-guard.sh`'s queued-wake warning counts only the rows the calling actor can itself present or retire.
So an actor is never sent to a drain that provably has nothing for it.
`bin/fm-wake-lib.sh` owns that per-actor count (`fm_wake_actor_pending_count`) alongside the grant row-list and owner-record reads that the drain and `bin/fm-wake-grant.sh` share.

A row a live grant reserves is therefore never counted as drainable for main.
Rather than going silent about a visibly non-empty queue, the guard prints a distinct advisory.
That advisory names the live supervision branch as the holder and says not to drain those rows from here.

The branch actor's queued-wake output stays suppressed in every case.
A main drain with nothing of its own left, and a live grant still holding the queue, says so in one bounded line instead of exiting silently.

### Structurally unusable rows

A row that lost the five appended fields or its numeric sequence can never be claimed, presented, or named by an `--ack-through` cutoff.
A main drain retires such a row under the queue lock.
It reports how many it removed, together with those rows verbatim, bounded to the first 20 and a count of the rest, because the queue was their only durable record.
A branch drain never retires them, because a grant can only name sequences that were structurally valid when it was published.

A retirement that cannot be read or written is reported and never fails the drain.
The rows that remain usable are still presented with their acknowledgement command, and the unusable ones stay queued for a later drain to retire.
Failing the whole drain would strand the usable rows too.

### Acknowledgement cutoffs

| Acknowledgement | What it deletes |
| --- | --- |
| Main `--ack-through <SEQ>` | Only claimed main rows at or below the cutoff. |
| Branch | Only claimed branch rows at or below its cutoff. |

A main acknowledgement first claims every unreserved row at or below its cutoff, so none is stranded.
It leaves a row above the cutoff that arrived after presentation unowned, so an away-session grant can still take it rather than handing every later wake back to main.

Every settled branch prompt releases any residual grant.
So an omitted or failed acknowledgement leaves the durable row available to a later main drain.
A successful acknowledgement has already removed it.

An acknowledgement can remove none of the actor's rows while a presented row above the cutoff still waits.
Such an acknowledgement is reported as having acknowledged nothing, together with the exact `--ack-through` and `--recovery-generation` command for that presented row.
The presented set is read before any re-claim, so a row that arrived after presentation is never named for unseen acknowledgement.

If a branch offer loses the claim race to main, it rejects its settlement so the watcher retains the actionable close until Pi accepts its main follow-up.

### Branch eligibility and check rows

[`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners) owns branch eligibility, mixed-queue dispatch, the pre-drain recheck, and heartbeat's all-or-nothing rule.

While attended, a check-kind row is main-owned, including a heartbeat review.
So it is never part of a branch claim and never defers one.
Main is woken for it on that check's own triggering close.
Under the away-posture record the exclusion lifts and a check row is offered to and claimed by the branch like every other actionable row.

`fm-wake-drain.sh` never reclassifies a row itself.
It filters the queue to the current actor's opaque claim before same-key deduplication, then presents and acknowledges only that actor-local view.
A missing or empty branch snapshot is refused loudly rather than read as "nothing eligible", because reaching the drain without the non-empty handoff promised by the extension is a wiring bug.
A branch acknowledgement retires the check-row receipts - inactive-outcome, inactive-reconcile notice, and secondmate stall - of exactly the granted sequences it consumes, so a branch-consumed check is never re-queued by its producer.
Attended, a grant names no check row and each scan finds nothing.

### Per-actor regression tests

`tests/fm-wake-queue.test.sh`'s mixed-queue actor, stale-acknowledgement remedy, and presentation-deadline tests drive the real scripts and check that:

- Branch acknowledgement cannot swallow a main row.
- A concurrent main turn cannot present or acknowledge an active branch grant.
- A no-op stale acknowledgement names the current presented wake's exact command.
- Live-holder presentation contention stays bounded and retriable.
- Acknowledgement locking remains blocking.

The same suite pins the counted-equals-presentable invariant against `bin/fm-guard.sh` and `bin/fm-wake-drain.sh` together:

- A branch-held row raises the held advisory rather than the ordinary queued-wake warning for main.
- That row is presented with its acknowledgement command - with the ordinary warning restored - as soon as the grant clears.
- Structurally unusable rows are retired by main alone while every remaining row stays presentable and acknowledgeable.

Branch acknowledgement retiring the check-row receipts of exactly its granted sequences is pinned by `tests/fm-wake-queue.test.sh` for the secondmate stall receipt and by `tests/fm-inactive-reconcile.test.sh` for the inactive-outcome receipt.

`tests/fm-pi-branch-extension.test.sh` pins extension-side classification, claim publication and release, and the pre-drain recheck.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.

### How an arm resolves a close

| Child return | What the arm does |
| --- | --- |
| Actionable output | Returns that reason normally. |
| Zero/empty | Rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger. |

An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one.
It does this because it holds no handle on the watcher's stdout and cannot read the reason line itself.

### Terminal-delivery ledger

Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero, even after its durable wake was handled and acknowledged.
An unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

### Cycle exit log

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes:

- Arm and watcher PIDs.
- Start and end timestamps.
- Exit code and signal.
- Classified reason.
- Beacon age.
- Lock identity before and after close.
- Successor disposition.

The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

### Grace, beacon, and stop signals

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`.
No helper process can make a wedged watcher appear healthy.
An arm whose own script path sits under a disposable no-mistakes validation checkout (`.no-mistakes/worktrees/`) refuses with the typed failure line before touching any state, because a watcher started there outlives the validation step and keeps writing the real home's state from a checkout about to be deleted.
Once per poll the watcher checks that its home, its state directory, and its own code root still exist, and exits with a logged reason when one is gone, scoped to itself alone, so a torn-down temporary home or a discarded checkout never leaves an orphan watcher behind.
The watcher uses bash's native fatal handling for HUP and TERM, including during a blocked poll, so both run its EXIT cleanup.
`watcher_stop_signals` in `bin/fm-watch.sh` owns the signal-handling rationale.

The watcher beats at each proven-progress point inside a cycle rather than once per cycle - between side-band reconciliation steps, before each registered check, at each scan phase, before each scanned window, and once per item inside the loops that cost per item.
A cycle's work scales with the fleet while the grace does not, because a check sweep spends up to `FM_CHECK_TIMEOUT` per check and the pane scan captures every recorded window, so a large home's ordinary cycle outruns the grace.
Whole-fleet loops scale the same way without a bound of their own: the provably-working check spends up to `FM_WORKTREE_WRITE_TIMEOUT` per task and short-circuits only on the first task that is not working, and a pending reply to an unreachable host costs that record an ssh timeout.
The watcher's own per-item loops scale that way too: the signal and heartbeat status scans read one span per log, the turn-end churn absorb path builds a whole-fleet metadata snapshot and then captures one pane per batched window, and each of those spends subprocesses per item.
The two status scans, the metadata snapshot, the batch-to-snapshot lookup and the provably-working walk all report at the top of their body, after only the cheap guards that decide whether the item is in scope, so an item that leaves the body through an early `continue` is still reported.
The pane-capture loop reports immediately after the one `fm_backend_capture` that dominates it instead: that loop has no `continue`, every earlier statement is a cheap marker read, and every failure leaves the whole function through `return 1`, so the gap there is still one capture.
Beacon age is therefore bounded by one item's work rather than by a whole fleet's.
Every route into the provably-working check is bounded that way now - the shared `signal_crew_provably_working` list through the hook, the churn absorb path's own walk over a coalesced batch, and the single call the per-window stale scan makes inside a loop that already beats per window - so the provably-working gap is closed rather than narrowed.
`tests/fm-watch-triage.test.sh` pins the rates as exact per-item counts, including over a batch whose items exit the body early.
`fm_classify_progress` in [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) owns that reporting contract for the shared check code, and the watcher supplies its beacon through `FM_CLASSIFY_PROGRESS_HOOK`; a caller that sets no hook is unaffected.
The hook names a shell function of the watcher process and is deliberately not exported, because every consumer runs in that shell or a subshell of it.
Beacon age therefore bounds how long the watcher has gone without making progress, not how long since a cycle turned over.

One gap remains and is not closed by per-item reporting, because it is a threshold rather than a reporting rate.
`bin/fm-watch-arm.sh` and `bin/fm-guard.sh` still take a bare 300-second default instead of deriving it from the poll interval, so a healthy watcher idle-waiting on a home with `FM_POLL` at 300 still reaches that age however often it beats.
Closing it means deriving those two defaults from the poll the way `fm_poll_derived_grace` already does for its own callers.

`state/.last-cycle-turnover` marks cycle turnover for test synchronization, touched exactly once per cycle immediately before the terminal wait and at no progress point.
No production code reads it today; its only reader is the test suite's cycle-wait helper.
It exists because the liveness beacon deliberately no longer implies a completed cycle, so a test that must wait out a whole cycle has nothing else to synchronize on.
If supervision should ever depend on cycle turnover, that is a new decision and must not be inferred from this file's presence.
Nothing may infer turnover from the beacon either, which fires many times per cycle.

## Regression coverage

### Pi and OpenCode watch extension

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops.
It then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, and:

- Blocks prompt delivery to prove the successor launches first.
- Verifies single-flight behavior.
- Changes the session lock before close to prove ownership is rechecked.
- Hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.

The same suite covers ordinary same-process session replacement for `/new`, `/resume`, `/fork`, and reload, plus:

- Same-instance shutdown-plus-start.
- The predecessor remaining live under a handoff generation until its replacement commits.
- Bounded retry after that replacement kills the predecessor but fails before readiness.
- Automatic re-arm before any model turn.
- A fresh extension-module rebind carrying all in-flight actionable closes exactly once.
- Stale prior-generation callbacks.
- Repeated transitions with exactly one live cycle.
- Disappearance of the shutting-down refusal after a valid replacement activates.
- Terminal quit still refusing late rearm.

The guard and session-start suites prove that active generation evidence tolerates a fresh-beacon handoff.
They also prove that a legacy or handoff-phase watcher marker from an absent replacement extension still raises the outage diagnostic.

### Arm, recovery, triage, and lock suites

`tests/fm-watch-arm.test.sh` covers:

- Durable queue replay.
- Real remote parent-replies ingestion into the authoritative status log.
- Decision-only OPEN DECISIONS recovery.
- Interrupted handling replay.
- Generation-bound acknowledgement.
- A persistent live successor after recovery.
- A watcher close inside the handling window that must leave the printed acknowledgement valid.
- A re-arm whose recovery cycle is slowed after confirmation and must still surface rather than read as a watcher that stayed live.
- The self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
- The disposable-checkout arm refusal.
- The home-gone and state-gone watcher exits.
- The test reaper that stops a watcher armed for a temporary home.

`tests/fm-watch-recovery-loop.test.sh` covers:

- The once-per-generation announcement bound with the real Pi extension against a refused handling handshake.
- A handling successor that must surface a real crew event instead of going blind.
- A turn-boundary re-arm between a drain's presentation and its acknowledgement, which must leave that acknowledgement able to retire its own episode and must supervise once the episode is settled.

`tests/fm-watch-triage.test.sh` proves TERM stops a watcher blocked inside a poll's pane capture and still releases its lock and records an acknowledgeable stop.
It also checks that a newly appended keyed decision is classified without rereading earlier status bytes, so signal handling can return to the watcher's beacon refresh even when the status history is long.

`tests/fm-watcher-lock.test.sh` covers:

- Verified-successor attach.
- Recovery publication before stale-lock removal.
- The typed self-eviction failure.
- Bounded and successor-linked lifecycle rows.
- A SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
- A check sweep longer than the stale grace whose beacon must stay fresh throughout. The case asserts the sweep really outlasted the grace, so it cannot pass vacuously.

### Claude auto-arm and turn-end guard

`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.

`tests/fm-claude-stop-autoarm.test.sh` covers:

- The auto-arm's scope.
- Stale and live session owners.
- Unchanged AFK and need boundaries.
- Single-flight.
- Bounded failure retries.
- Benign live-watcher cycle ends.
- One-notice failure episodes.
- Exit-2 translation.
- The handling successor an ended attached cycle starts with the closed arm as its predecessor and that outlives the rewake.
- An unconfirmed successor reported in the banner without withholding the wake.
- Host-timeout HUP/TERM/INT translation into the same durable failure handoff.

It also covers generation-claim single-flight, stuck-claim supersession, superseded-owner silence, notice-marker refusal and retry, ownership-atomic episode reset, and the legacy upgrade shim.
[`turnend-guard.md`](turnend-guard.md) owns those behavior contracts.

`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh`:

1. Starts with the reproduced stale-lock state.
2. Receives session start through the tracked SessionStart hook.
3. Completes two tokenless cycles.
4. Checks the competing-live-owner negative control.

`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including:

- Monotonic failed-epoch progression.
- The integrated bounded fail-open.
- Post-alarm continuation suppression.
- Positive recovery reset.

[`turnend-guard.md`](turnend-guard.md#regression-coverage) lists that suite's full generation and legacy claim coverage.

## Active limits and verification

The goal is continuity without a Pi, omp, or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed, because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.

The other harnesses rely on these mechanisms:

- Claude depends on the Stop `asyncRewake` rewake.
- Cursor depends on its awaited stop-hook park.
- Grok retains native background-completion notifications.
- Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current cross-harness live evidence, the dated Stop-owned Claude auto-arm results, and exact opt-in commands.
