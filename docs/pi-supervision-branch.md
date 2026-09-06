# Pi supervision branch

![Multi-brain agent architecture: one agent, two branches of attention, events are commits](pi-supervision-branch-poster.svg)

The poster is the visual of the idea.
This document stays the owner and the contract.

Fleet supervision on the Pi primary harness runs on a second conversation - the supervision branch - inside the same `pi` process as the captain's chat.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch handles eligible task-local rows from ordinary actionable wakes plus heartbeat scans that the cheap bash-level scan flags as possibly captain-relevant, then merges each outcome back into the captain conversation's transcript.
Ordinary main-only rows remain on main even when eligible task-local rows share their queue, except that a decision-owned signal or stale trigger keeps its entire coalesced trigger batch on main.
An unresolvable row makes the scan unsafe and returns the whole wake to main, and every watcher-failure alarm also stays on main.
Captain-relevant branch outcomes persist as exact, sequence-keyed visible transcript entries and then open one sequence-keyed processing turn on main, which stays open until main acknowledges that sequence.
The design source is the captain-approved forked-supervision architecture board, a captain-private fleet record (a self-contained HTML explainer with the measured cache and judgment evidence); this document records the shape it landed as, and the delivering PR cites the board artifact itself.

The supervision branch itself is Pi-only by construction:

- The branch lives in `.pi/extensions/fm-branch-supervision.ts`, which only a Pi primary ever loads; no other harness gains branch supervision behavior.
- The bash-side additions (leases, the outcome store, session-start recovery) are inert in a home with no branch state: no lease files exist, no actor variable is set, every guard passes silently, and no new state appears (`tests/fm-branch-supervision.test.sh` holds this).
  A home on any harness that already has an outcome store still receives the shared drain compatibility recovery described in [Lost-wake outcome backstop](#lost-wake-outcome-backstop).
- It does not change which harness is primary and never moves a home to Pi.

## Components and their owners

- Wake dispatch: `.pi/extensions/fm-primary-pi-watch.ts` stays the dispatcher; `.pi/extensions/lib/fm-branch-dispatch.ts` owns the offer handshake and row eligibility, while [`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the per-actor consume contract.
  A successful row grant transfers ownership of exactly the currently branch-eligible rows to the branch; a check-kind triggering close (merge-confirmation polls, Relay mentions, credential/auth failures, and every other legitimately main-only class) is never offered even when other rows are eligible, no acceptor (extension absent, away mode, branch broken) keeps today's wake-to-main path for that close, and watcher-failure alarms always go to main because only main can repair the watcher cycle.
  A decision-owned event surfaced by `bin/fm-watch.sh`'s signal path gets the identical treatment even though it keeps the ordinary `signal` kind.
  `signal_files_actionable` marks the queued payload `needs-decision:` for a newly surfaced `needs-decision`, a `captain-held` declaration surfaced through the no-verb fallback, or a pending-reply second-mate escalation; `scopeForUnreadWake` excludes every marked row from what the branch may claim.
  For a stale row, `scopeForUnreadWake` folds the mapped task's status log and excludes the row when any `needs-decision` remains open or the current meaningful declaration is `captain-held`; an unreadable or symlinked status log fails the scope closed rather than influencing routing.
  The dispatcher resolves trigger keys and every currently unread excluded decision row to task identity before cross-referencing them: any signal or stale trigger containing a decision-owned task goes wholly to main, including a batch that also contains routine rows, and an unread decision for one task keeps every later signal or stale trigger for that same task on main until the decision row is read, regardless of whether the rows use its status-file key or window alias.
  Other tasks remain independently eligible.
  The wake message itself retains its existing shape, so other harness-arm scripts remain unchanged.
  Heartbeat handling remains independent.
  A fleet-wide heartbeat keeps its own all-or-nothing rule (see "Heartbeat routing" below): it takes every branch-ownable unread row or none of them.
  A co-present main-owned check row no longer defers that review to main, because it is not fleet context the branch is missing and main is woken for it on its own triggering close.
- The branch itself: `.pi/extensions/fm-branch-supervision.ts` creates the branch session, serializes wakes, mirrors dialog, and merges outcomes.
  The branch conversation lasts for exactly one main session: every main session start - a cold start, `/new`, `/resume`, `/fork`, or a reload - opens a NEW branch conversation, and a conversation recorded by an earlier session is never reopened as the live one.
  That keeps the branch reasoning from the current generated prompt and the current main dialog rather than from weeks of accumulated thread, where a superseded rule could still outweigh today's.
  Only a rebuild inside one main session, which is what a model or effort change triggers, continues that session's own conversation, and `state/.branch-session` records it.
  Earlier conversations stay on disk under `state/branch-session/`, exactly as Pi keeps its own session files, and are never reopened as live branch context; the effort picker may only inspect the model named by the current pointer as the last-resort lookup documented in [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort).
  Nothing captain-facing rides on that conversation: the durable outcome store and its processed marker are what carry unacknowledged outcomes across the boundary, and they re-present on the new main session exactly as they do after a crash.
  It checks the current extension generation and `state/.lock` ownership before each guarded branch side effect so replacement or lock loss cannot let an old continuation mutate the new session.
  Those checks and the store calls around them are awaited rather than synchronous, and an explicit queue inside the extension is what keeps them serialized (see "Off-thread delivery" below).
  Every accepted path that cannot reach a working branch rejects its settlement to the watcher, which retains delivery ownership and routes the wake to main as a follow-up that counts as delivered once Pi accepts it; a broken branch declines later offers so they take that path directly.
  After wake rows are claimed, a branch prompt counts as handled only when `fm_branch_report` appends a durable outcome before that prompt settles; a settled provider error or a settled prompt with no report releases the grant and rejects delivery ownership back to the watcher.
  While a signal or stale prompt is open, `fm_branch_report` accepts only the tasks that prompt's claimed rows resolve to (a signal row by its status-log key, a stale row through the task record naming that endpoint); a report for any other task id, `fleet` included, is refused before the store is touched, so a task remembered from an earlier wake cannot become a delivered outcome, while a heartbeat review is not scoped by task.
  The branch's guarded commands never tell it to drain queued rows mid-handling: for that actor `bin/fm-guard.sh` keeps the queued-wakes warning silent, and an acknowledgement that consumed nothing reports that plainly with the exact command for the current wake (`docs/watcher-continuity.md` "Per-actor acknowledgement").
  Two consecutive settled provider errors latch the branch broken and surface a one-line health note only on that initial trip.
  Main keeps every wake during a five-minute cooldown, after which one wake may probe the branch while concurrent wakes still stay on main; each probe that settles with another provider error doubles the next cooldown up to one hour.
  A prompt from the current branch generation and model or effort selection that appends a durable `fm_branch_report` and then settles without a provider error clears both the latch and provider-error streak and surfaces a one-line recovery note; a provider error settled after that report wins instead, re-latches the branch, and extends the cooldown.
  A session replacement or branch model or effort change resets the recovery state immediately.
- Branch model and effort selection: the same extension registers `/supervision-model`, which picks the branch's model and then its reasoning effort, and applies both at the branch-session creation boundary; [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns the operator-facing schema and behavior.
- Branch system prompt: `bin/fm-branch-prompt.sh`; its header owns the byte-stable-prefix contract (no timestamps, no fleet snapshot, no per-wake content).
- Outcome store: `bin/fm-branch-outcome.sh`; its header owns the append-only format, read cursor, and bounded per-task status-coverage indexes.
  Outcomes are written to the store before delivery to Pi.
  A captain row advances the cursor only after its matching visible session entry exists, while locked session-start replay stops before the first captain row so it cannot acknowledge that outcome through prose alone.
  A routine note has no such sequence-keyed record, so if its cursor write fails after the note was delivered the next reconciliation sends that note once more.
  That asymmetry is a known limitation of the routine delivery representation rather than of the ordering above, it predates delivery moving off Pi's render thread, and closing it means giving routine delivery a durable idempotent record - tracked as follow-up `fm-pi-routine-delivery-idempotency-followup-r1` and pinned meanwhile by `tests/fm-pi-branch-extension.test.sh`.
- Consistency: `bin/fm-lease-lib.sh` owns the per-task lease contract, the main-only role partition, and the deliberate CONFUSED-AGENT-GRADE threat model these guards target (captain-decided; adversarial-grade separation is out of scope and tracked as follow-up design work); `bin/fm-lease.sh` is the command surface.
  The guards are wired into `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` (overlap, lease-checked, with claim serialization retained through the mutation) and `fm-pr-merge.sh`, `fm-merge-local.sh`, and `fm-spawn.sh` (main-owned, branch refused; a relaunch through `fm-control` stays branch-legal recovery).
- Autonomy: supervision is default-on for every task once a Pi primary session owns the fleet lock (docs/configuration.md "Pi supervision branch"); no captain grant file is required.
  A fleet-wide heartbeat is separately eligible only when every row other than a check or decision-owned signal/stale row is a heartbeat row or a resolvable task-local row (see "Heartbeat routing" below); every other fleet-wide or unresolvable wake, and every watcher-failure alarm, stays on main.
  The branch recomputes eligibility immediately before prompting the branch to drain and publishes the exact eligible row set to `state/.branch-eligible-rows` through `writeEligibleRowsSnapshot`.
  After an independently eligible wake has already been offered, a newly-arrived main-owned row observed at that pre-drain recheck does not revoke the offer: it is excluded from the eligible set, so whatever else is currently eligible still reaches the branch, and the main-owned row stays queued for main's own drain.
  [`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the consume-side guarantee that neither actor can present or acknowledge the other's claim.
  Heartbeat keeps its own all-or-nothing recheck over the rows it can claim: it takes every branch-ownable unread row or none of them, and an unresolvable task-local row still defers the whole review to main.
  A producer can still append a row in the instant between that final check and drain startup; this accepted residual follows the confused-agent-grade boundary above rather than claiming adversarial queue isolation.
  Away mode and a broken branch between its bounded recovery probes keep today's wake-to-main behavior.

## Off-thread delivery

The supervision branch lives inside the captain's own Pi process, and Pi runs extensions, their tools, and their event handlers on the single JavaScript thread that also draws the TUI and reads the keyboard.
A synchronous subprocess in the delivery path therefore stops repaint and key echo for the child's whole lifetime, which the captain saw as a subsecond freeze every time a routine or captain-facing outcome arrived.
Subprocess work reached through Pi's asynchronous APIs is now awaited instead: `.pi/extensions/lib/fm-async-exec.ts` owns that awaited-spawn replacement and preserves the status, captured-output, and failure semantics its callers used from the synchronous form.

Awaiting yields the thread, so what the single thread used to guarantee for free is now an explicit queue in `.pi/extensions/fm-branch-supervision.ts`.
Every delivery, every acknowledgement, and every turn boundary's reconciliation runs as one unit of that queue, which is what preserves the durable append before anything visible, one delivery at a time in sequence order, the read cursor advanced before the next reader sees a row, and one ownership activation per generation.
Cancellation is preserved by the generation and lock-ownership rechecks the awaits are placed around: a session replaced mid-delivery fails the next recheck rather than acting into the session that replaced it.

Two reads stay synchronous because Pi's own API is synchronous there, not as an optimization.
Pi types its bash spawn hook as a plain function, so the guard on the branch's own shell commands cannot await; and the watcher reads `offer.accepted` the moment its dispatch event returns, so a session that does not own the fleet lock must still refuse a wake without waiting.
Both read the same uncached ownership authority: the lock's process ancestry is walked in full every time it is asked, never cached, because reparenting and pid reuse can invalidate a remembered chain and this answer decides ownership rather than hinting at it.

## Lost-wake outcome backstop

Every main-actor wake drain checks each task's newest non-blank status event against the latest supervision-branch outcome that causally covers that task's status log.
When that event is terminal or otherwise captain-facing and remains uncovered, the drain prints it once in `STATUS OUTCOME BACKSTOP`, even if the original queue row was already acknowledged; routine events stay silent, and valid open decisions remain owned by `OPEN DECISIONS`.
The one-shot backstop cursor is independent from signal annotation, so a delayed signal can still present its status context without repeating the recovered event.
The drain reads one fixed-size per-task outcome index instead of scanning append-only outcome history and inspects at most the final 64 KiB of each status log.
Status provenance added to new outcome rows distinguishes covered and genuinely later events even within one timestamp second.
Legacy outcomes predate that causal position, so equal-second migration cannot prove order and deliberately favors surfacing a plausibly later event; this can rarely duplicate an already handled legacy event.
A pathological latest status line that crosses the 64 KiB window is unclassifiable and remains silent rather than risking presentation of routine content; this is an accepted limit, not a status-line size contract.
A missing or invalid outcome-index ready marker is rebuilt from the authoritative outcome rows by `processed-init` under the outcome lock on the next main drain, on every harness.
Only a genuine store fault keeps that backstop skipped.

## How the branch knows what the captain said

Main's captain and assistant text - never tool calls, tool results, operational injections, or the branch's own merged notes - is mirrored into the branch as read-only `fm-main-mirror` messages.
The idle path mirrors at main's turn end.
At `before_agent_start`, Pi's authoritative prompt is staged verbatim before SessionManager persists that user entry, so the complete current captain message precedes any branch wake accepted after that boundary; the later persisted copy is suppressed and older dialog entries remain bounded.
The mirror cursor is durable (`state/.branch-mirror-cursor`), so within one main session only not-yet-mirrored dialog is replayed.
Every main session start re-anchors the mirror to the current main session's start, because that start also opens a new branch conversation: the cursor records what the PREVIOUS branch conversation received, so without the reset a `/resume` or reload, which keeps main's own session file, would leave the new branch blind to dialog main itself still has.
The reset is bounded by the current main session and costs only re-delivered read-only context, and the cursor keeps advancing incrementally from there.
The branch prompt frames mirrored text as context for judgment, never as instructions addressed to the branch; an authorization addressed to main (for example "you may merge when green") does not relax the branch's role limits.

## Two-stage noise filter

Stage one is unchanged: the bash watcher absorbs everything provably fine at zero token cost.
Stage two is the branch's verdict on each handled event, reported through its `fm_branch_report` tool: `routine` keeps the existing custom-message path without a follow-up turn, while `captain` appends a versioned `fm-branch-visible-outcome` custom session entry.
The captain entry contains the store sequence, task, verdict, exact summary, and silent flag, and its renderer presents the exact task and summary with an anchor prefix.
Pi custom session entries persist in the transcript but do not enter model context, so a stale compaction summary, an unrelated assistant response, prompt caching, or model instruction noncompliance cannot acknowledge or rewrite the outcome.
The store sequence is the idempotency key: reload after entry persistence but before cursor advancement finds the matching entry, avoids a duplicate, and advances the cursor; conflicting content for one sequence fails closed.
Reconciliation runs at session start when that generation already owns the fleet lock and at the first post-lock `turn_end`, so a cold start that acquires the lock through the startup digest still delivers stored captain outcomes without waiting for another wake.
Display is only half of a captain outcome; the other half is processing, because a blocker, a decision, or a ready PR needs main to act, not only the captain to see it.
After the visible entry exists and the read cursor has passed it, the extension hands every still-unprocessed captain row to main as one hidden, typed `fm-branch-process` request (kind `branch-outcome`) listing each `[seq N] task: summary`, and that request opens exactly one main turn.
Main closes it only by calling `fm_branch_processed` with the highest sequence the request listed, which advances a processed marker that `bin/fm-branch-outcome.sh` keeps separately from the read cursor and never moves past it or backwards.
A lower listed captain sequence is accepted only as a partial acknowledgement and leaves every newer captain sequence open.
Nothing else advances that marker: an unrelated reply, an empty reply, or a reply that paraphrases the outcome leaves the sequence unprocessed, and the extension presents the current unprocessed sequence set again at the next main run boundary and at every session start.
A presentation already pending its run boundary is not resent or widened; once that run settles, the extension presents the then-current sequence set.
The first two presentations of a given sequence set open a turn of their own; after that the request rides the captain's next prompt so an ignored request cannot become an unbounded loop of empty turns, while changed sequence membership and a session replacement each start that budget over.
Routine outcomes never enter this path and stay turn-free.
A home upgraded with outcomes already delivered treats those rows as processed once, at the first reconciliation that finds no processed marker, so its history is not re-presented.
The generated [Pi supervision protocol](supervision-protocols/pi.md) owns event ownership for merged outcomes and main's acknowledgement duty, while deterministic entry delivery owns captain visibility.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is also delivered silently with no rendered note, while every other `routine` outcome stays rendered with its sailboat prefix.
The branch prompt's "Verdict: routine or captain" section owns the verdict criteria, including how requested work's finished results and its mere progress updates are classified; unsolicited routine outcomes remain routine sailboat notes, unchanged fleet reviews remain silent, and doubt escalates.
Its "PR identity: copy or abstain" section owns where a PR URL in a summary or tool argument may come from: the task's ready status or `pr=` metadata, verbatim, or else only the identifier the branch actually has.
Main can read the durable outcome store on demand through its `fm_branch_outcomes` tool.

## Heartbeat routing

The cheap bash-level heartbeat scan absorbs a genuinely no-op pass before it reaches Pi, unchanged from before.
Only a scan already flagged as possibly captain-relevant emits the bare `heartbeat` wake; `.pi/extensions/fm-primary-pi-watch.ts` flags that offer `heartbeat: true`, and the branch accepts it without a project only when every branch-ownable row observed in the unread-queue eligibility check is either heartbeat-kind or a resolvable task-local signal or stale event.

A heartbeat is never vetoed or ridden into main by a co-present check row or decision-owned signal/stale row.
Those rows are permanently main-owned in every mode: they are excluded from what the branch may claim and left queued for main, which is woken for each on its own watcher cycle, so nothing starves by being left behind.
Deferring the fleet review to main merely because some unrelated merge poll or Relay mention happened to be sitting unread put a routine review in the captain's chat for a reason that had nothing to do with the fleet, and that coupling is gone.
What all-or-nothing still guarantees is unchanged: the branch takes every branch-ownable unread row or none of them, and an unresolvable task-local row, an unknown row kind, or an unreadable queue still defers the whole review to main.
The branch runs its normal operating procedure for the wake (`bin/fm-branch-prompt.sh` "Handling a wake") and performs the deeper fleet review that main previously performed.
A review that found literally nothing worth reporting uses verdict `routine`, `task=fleet`, and `silent=true` so it has no rendered note, while a fleet-wide routine action omits `silent` and keeps its rendered sailboat note.
Only a captain-worthy finding reports verdict `captain` and appends a visible captain outcome entry.
Every other fleet-wide or unresolvable wake - including watcher-failure alarms, which are never offered to the branch - keeps today's wake-to-main path.

## Cost model and the byte-stable prefix

The captain accepted the normal provider prompt-caching strategy: a byte-identical branch prefix generated once per firstmate version, the same tool set in the same order on every request, and one shared `prompt_cache_key` per home for all branch sessions (set in a `before_provider_request` hook, and only for providers whose requests already carry that field); main keeps its own per-session key.
Budget roughly 60% cache hits on a new branch conversation's first call and 95% on later calls within that conversation; the shared per-home key is what carries the byte-identical prefix across the conversation each main session start opens, and reuse is best-effort, never guaranteed.
The branch can also run on a cheaper model and a shallower reasoning effort than main, both pinned with the Pi `/supervision-model` command; [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns those pins' operator-facing schema and unpinned behavior.
No caching machinery beyond this exists, deliberately: any later dynamic content in the branch prefix silently removes most of the cache benefit, which is why `bin/fm-branch-prompt.sh`'s header is the contract's single owner and `tests/fm-branch-supervision.test.sh` pins the output to byte identity.

## Away mode

Away mode carries over unchanged: while `state/.afk` exists the away daemon owns supervision, and the branch declines every wake offer for the duration.
What is new is only the attended path: outside away mode, the branch absorbs the routine majority that previously interrupted the captain's conversation, applying the same escalation etiquette the daemon applies while away.

## Verification

Portable regressions: `tests/fm-pi-branch-extension.test.sh` covers dispatch, signal and stale report scoping with unscoped heartbeat reports, the new branch conversation at every main session start with continuation inside one session, the mirror re-anchor that pairs with it, requested-versus-unsolicited delivery, exact visible entry content, no unkeyed model turn, the sequence-keyed processing request and its acknowledgement, re-presentation after an empty reply and after an unrelated prior answer, the triggered-then-next-turn pacing, session-start re-presentation, routine outcomes staying turn-free, the processed-marker migration, idle and busy main state, incident-shaped compaction and unrelated-assistant context, cold-start post-lock recovery, crash-before-cursor reload recovery, repeated-reload idempotency, mirroring, post-construction provider-error and no-report fallback, the consecutive-error latch, cooldown probe, exponential backoff, report-plus-settlement recovery, report-before-error re-latch, cache key, model and effort selection, and (in `test_branch_dispatch_classifies_main_only_rows_and_writes_the_eligible_snapshot`) decision-owned signal and stale rows' exclusion from `eligibleSeqs`, their presence in `needsDecisionKeys`, task alias resolution, reserved-key configuration, status-log race and symlink refusal, non-vetoing behavior for unrelated eligible rows, and decision-only queues reading as ordinary main-only absence.
`tests/fm-branch-supervision.test.sh` covers prompt stability, store append-only behavior, the captain cursor barrier, the processed marker's sequence bounds, leases, guards, and non-branch-home invariance.
`tests/fm-wake-drain-outcome-backstop.test.sh` covers keyless resurfacing, causal suppression, same-second ordering, one-shot presentation, first-drain index self-healing under the outcome lock, store-fault fail-closed behavior, bounded history cost and output, and the oversized-line limit.
`tests/fm-teardown.test.sh` covers removal of the retired task's outcome index and the append-side rule that a post-teardown report does not recreate it.
The branch-offer, heartbeat-offer, heartbeat-not-ridden-by-main-only-rows, main-only-check-class, captain-held-stale-stays-on-main, and mixed-signal-routing tests remain in `tests/fm-pi-watch-extension.test.sh` (the last two routing classes exercise `offerWakeToBranch`'s trigger-key cross-reference end to end), the recovery test remains in `tests/fm-session-start.test.sh`, and the per-actor consume regression remains in `tests/fm-wake-queue.test.sh`.
It also covers the off-thread delivery contract behaviorally: that a delivery leaves the event loop running rather than blocking it, that interleaved reports stay ordered and exactly once, that a session replaced mid-delivery neither loses nor duplicates an outcome, and that a failing store script surfaces without losing or doubling one.
`tests/fm-watch-triage.test.sh` covers `bin/fm-watch.sh`'s side of the contract end to end: needs-decision, no-verb captain-held, and pending-reply second-mate escalation signal rows are marked `needs-decision:`, a needs-decision whose key transition was rejected by the reserved-key vocabulary (`fm-classify-lib.sh`'s `reconciliation-required:` wrapper) is still marked, and ordinary blocked or captain-relevant signals stay unmarked.
Live guards: `FM_PI_BRANCH_LIVE_E2E=1 tests/fm-pi-branch-live-e2e.test.sh` exercises the real installed Pi SDK's immediate active-transcript appendEntry rendering, persistence, custom-entry model exclusion, branch-session surfaces, and watcher-owned fallback after rejected branch settlement.
`FM_PI_BRANCH_RESPONSIVENESS_E2E=1 tests/fm-pi-branch-responsiveness-live-e2e.test.sh` answers the question only a real TUI can: it types into an isolated Pi pane while outcomes are delivered and fails if keystroke echo leaves the class of the same machine's extension-free floor.
Record dated current results in [docs/verification/runtime-backends.md](verification/runtime-backends.md).
The strict typecheck in `tests/fm-pi-primary-types.test.sh` pins the extension against the installed Pi package.
