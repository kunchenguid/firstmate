# Pi supervision branch

![Multi-brain agent architecture: one agent, two branches of attention, events are commits](pi-supervision-branch-poster.svg)

The poster is the visual of the idea.
This document stays the owner and the contract.

Fleet supervision on the Pi primary harness runs on a second, persistent conversation - the supervision branch - inside the same `pi` process as the captain's chat.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch handles eligible task-local rows from ordinary actionable wakes plus heartbeat scans that the cheap bash-level scan flags as possibly captain-relevant, then merges each outcome back by appending a short note to the captain conversation's tail.
Ordinary main-only rows remain on main even when eligible task-local rows share their queue.
An unresolvable row makes the scan unsafe and returns the whole wake to main, and every watcher-failure alarm also stays on main.
Only captain-relevant branch outcomes open a turn on main - that follow-up turn is itself the captain-visible outcome, so Pi never separately prints or renders a captain-facing merge note.
The design source is the captain-approved forked-supervision architecture board, a captain-private fleet record (a self-contained HTML explainer with the measured cache and judgment evidence); this document records the shape it landed as, and the delivering PR cites the board artifact itself.

This feature is Pi-only by construction and changes nothing anywhere else:

- The branch lives in `.pi/extensions/fm-branch-supervision.ts`, which only a Pi primary ever loads; no other harness gains or loses behavior.
- The bash-side additions (leases, the outcome store, session-start recovery) are inert in a home that never runs the branch: no lease files exist, no actor variable is set, every guard passes silently, and no new state appears (`tests/fm-branch-supervision.test.sh` holds this).
- It does not change which harness is primary and never moves a home to Pi.

## Components and their owners

- Wake dispatch: `.pi/extensions/fm-primary-pi-watch.ts` stays the dispatcher; `.pi/extensions/lib/fm-branch-dispatch.ts` owns the offer handshake and row eligibility, while [`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the per-actor consume contract.
  A successful row grant transfers ownership of exactly the currently branch-eligible rows to the branch; a check-kind triggering close (merge-confirmation polls, Relay mentions, credential/auth failures, and every other legitimately main-only class) is never offered even when other rows are eligible, no acceptor (extension absent, away mode, branch broken) keeps today's wake-to-main path for that close, and watcher-failure alarms always go to main because only main can repair the watcher cycle.
  A fleet-wide heartbeat keeps its own all-or-nothing rule (see "Heartbeat routing" below): it takes every branch-ownable unread row or none of them.
  A co-present main-owned check row no longer defers that review to main, because it is not fleet context the branch is missing and main is woken for it on its own triggering close.
- The branch itself: `.pi/extensions/fm-branch-supervision.ts` creates and reopens the persistent branch session, serializes wakes, mirrors dialog, and merges outcomes.
  It checks the current extension generation and `state/.lock` ownership before each guarded branch side effect so replacement or lock loss cannot let an old continuation mutate the new session.
  Every path that cannot reach a working branch falls back to delivering the wake to main - a broken branch degrades to today's behavior, never to a lost wake.
- Branch model and effort selection: the same extension registers `/supervision-model`, which picks the branch's model and then its reasoning effort, and applies both at the branch-session creation boundary; [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns the operator-facing schema and behavior.
- Branch system prompt: `bin/fm-branch-prompt.sh`; its header owns the byte-stable-prefix contract (no timestamps, no fleet snapshot, no per-wake content).
- Outcome store: `bin/fm-branch-outcome.sh`; its header owns the append-only format and the read cursor.
  Outcomes are written to the store before any note is handed to Pi, and rows that never reach that handoff replay once through the next locked session-start digest.
- Consistency: `bin/fm-lease-lib.sh` owns the per-task lease contract, the main-only role partition, and the deliberate CONFUSED-AGENT-GRADE threat model these guards target (captain-decided; adversarial-grade separation is out of scope and tracked as follow-up design work); `bin/fm-lease.sh` is the command surface.
  The guards are wired into `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` (overlap, lease-checked, with claim serialization retained through the mutation) and `fm-pr-merge.sh`, `fm-merge-local.sh`, and `fm-spawn.sh` (main-owned, branch refused; a relaunch through `fm-control` stays branch-legal recovery).
- Autonomy: supervision is default-on for every task once a Pi primary session owns the fleet lock (docs/configuration.md "Pi supervision branch"); no captain grant file is required.
  A fleet-wide heartbeat is separately eligible only when every non-check row in the unread queue is a heartbeat row or a resolvable task-local row (see "Heartbeat routing" below); every other fleet-wide or unresolvable wake, and every watcher-failure alarm, stays on main.
  The branch recomputes eligibility immediately before prompting the branch to drain and publishes the exact eligible row set to `state/.branch-eligible-rows` through `writeEligibleRowsSnapshot`.
  A newly-arrived main-owned row observed at that recheck no longer defers the whole queue to main: it is excluded from the eligible set, so whatever else is currently eligible still reaches the branch, and the main-owned row stays queued for main's own later drain.
  [`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the consume-side guarantee that neither actor can present or acknowledge the other's claim.
  Heartbeat keeps its own all-or-nothing recheck over the rows it can claim: it takes every branch-ownable unread row or none of them, and an unresolvable task-local row still defers the whole review to main.
  A producer can still append a row in the instant between that final check and drain startup; this accepted residual follows the confused-agent-grade boundary above rather than claiming adversarial queue isolation.
  Away mode and a broken branch keep today's wake-to-main behavior.

## How the branch knows what the captain said

Main's captain and assistant text - never tool calls, tool results, operational injections, or the branch's own merged notes - is mirrored into the branch as read-only `fm-main-mirror` messages at main's turn end, before the next wake is handed over.
The mirror cursor is durable (`state/.branch-mirror-cursor`), so a restart replays only the not-yet-mirrored dialog from main's session file, and a replacement main session re-anchors from its start.
The branch prompt frames mirrored text as context for judgment, never as instructions addressed to the branch; an authorization addressed to main (for example "you may merge when green") does not relax the branch's role limits.

## Two-stage noise filter

Stage one is unchanged: the bash watcher absorbs everything provably fine at zero token cost.
Stage two is the branch's verdict on each handled event, reported through its `fm_branch_report` tool: `routine` merges without a follow-up turn, while `captain` merges with exactly one follow-up turn.
The follow-up turn a `captain` verdict opens is itself the captain-visible outcome, so its merge note is delivered silently and never printed or rendered in Pi.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is also delivered silently with no rendered note, while every other `routine` outcome stays rendered with its sailboat prefix.
The verdict criteria in the branch prompt mirror the captain-etiquette escalation list; doubt escalates.
Main can read the durable outcome store on demand through its `fm_branch_outcomes` tool.

## Heartbeat routing

The cheap bash-level heartbeat scan absorbs a genuinely no-op pass before it reaches Pi, unchanged from before.
Only a scan already flagged as possibly captain-relevant emits the bare `heartbeat` wake; `.pi/extensions/fm-primary-pi-watch.ts` flags that offer `heartbeat: true`, and the branch accepts it without a project only when every non-check row observed in the unread-queue eligibility check is either heartbeat-kind or a resolvable task-local signal or stale event.

A heartbeat is never vetoed or ridden into main by a co-present check row.
A check row is permanently main-owned in every mode: it is excluded from what the branch may claim and left queued for main, which is woken for it on that check's own watcher cycle, so nothing starves by being left behind.
Deferring the fleet review to main merely because some unrelated merge poll or Relay mention happened to be sitting unread put a routine review in the captain's chat for a reason that had nothing to do with the fleet, and that coupling is gone.
What all-or-nothing still guarantees is unchanged: the branch takes every branch-ownable unread row or none of them, and an unresolvable task-local row, an unknown row kind, or an unreadable queue still defers the whole review to main.
The branch runs its normal operating procedure for the wake (`bin/fm-branch-prompt.sh` "Handling a wake") and performs the deeper fleet review that main previously performed.
A review that found literally nothing worth reporting uses verdict `routine`, `task=fleet`, and `silent=true` so it has no rendered note, while a fleet-wide routine action omits `silent` and keeps its rendered sailboat note.
Only a captain-worthy finding reports verdict `captain` and opens a main turn.
Every other fleet-wide or unresolvable wake - including watcher-failure alarms, which are never offered to the branch - keeps today's wake-to-main path.

## Cost model and the byte-stable prefix

The captain accepted the normal provider prompt-caching strategy: a byte-identical branch prefix generated once per firstmate version, the same tool set in the same order on every request, and one shared `prompt_cache_key` per home for all branch sessions (set in a `before_provider_request` hook, and only for providers whose requests already carry that field); main keeps its own per-session key.
Budget roughly 60% cache hits on a fresh branch session's first call and 95% on later calls of the persistent session; reuse is best-effort, never guaranteed.
The branch can also run on a cheaper model and a shallower reasoning effort than main, both pinned with the Pi `/supervision-model` command; [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns those pins' operator-facing schema and unpinned behavior.
No caching machinery beyond this exists, deliberately: any later dynamic content in the branch prefix silently removes most of the cache benefit, which is why `bin/fm-branch-prompt.sh`'s header is the contract's single owner and `tests/fm-branch-supervision.test.sh` pins the output to byte identity.

## Away mode

Away mode carries over unchanged: while `state/.afk` exists the away daemon owns supervision, and the branch declines every wake offer for the duration.
What is new is only the attended path: outside away mode, the branch absorbs the routine majority that previously interrupted the captain's conversation, applying the same escalation etiquette the daemon applies while away.

## Verification

Portable regressions: `tests/fm-pi-branch-extension.test.sh` (dispatch, default-on eligibility, main-only classification, eligible-row claim lifecycle, partial pre-drain recheck, fallback, filter, mirror, cache key, persistence, model pin, effort pin), `tests/fm-branch-supervision.test.sh` (prompt stability, store append-only, leases, guards, non-branch-home invariance), the branch-offer, heartbeat-offer, heartbeat-not-ridden-by-a-check, and main-only-check-class tests in `tests/fm-pi-watch-extension.test.sh`, the recovery test in `tests/fm-session-start.test.sh`, and the per-actor consume regression in `tests/fm-wake-queue.test.sh`.
Live guard: `FM_PI_BRANCH_LIVE_E2E=1 tests/fm-pi-branch-live-e2e.test.sh` exercises the real installed Pi SDK with no user credentials and no provider call; run it after every Pi upgrade and record the dated result in [docs/verification/runtime-backends.md](verification/runtime-backends.md).
The strict typecheck in `tests/fm-pi-primary-types.test.sh` pins the extension against the installed Pi package.
