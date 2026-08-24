# Pi supervision branch

![Multi-brain agent architecture: one agent, two branches of attention, events are commits](pi-supervision-branch-poster.svg)

The poster is the visual of the idea.
This document stays the owner and the contract.

Fleet supervision on the Pi primary harness runs on a second, persistent conversation - the supervision branch - inside the same `pi` process as the captain's chat.
The branch absorbs ordinary actionable wakes that pass the watcher's unchanged first-stage classifier and resolve wholly to captain-granted projects, handles them with real tools, and merges each outcome back by appending a short note to the captain conversation's tail; fleet-wide, unresolvable, and out-of-scope wakes stay on main, and only captain-relevant branch outcomes open a turn.
The design source is the captain-approved forked-supervision architecture board, a captain-private fleet record (a self-contained HTML explainer with the measured cache and judgment evidence); this document records the shape it landed as, and the delivering PR cites the board artifact itself.

This feature is Pi-only by construction and changes nothing anywhere else:

- The branch lives in `.pi/extensions/fm-branch-supervision.ts`, which only a Pi primary ever loads; no other harness gains or loses behavior.
- The bash-side additions (leases, the outcome store, session-start recovery) are inert in a home that never runs the branch: no lease files exist, no actor variable is set, every guard passes silently, and no new state appears (`tests/fm-branch-supervision.test.sh` holds this).
- It does not change which harness is primary and never moves a home to Pi.

## Components and their owners

- Wake dispatch: `.pi/extensions/fm-primary-pi-watch.ts` stays the dispatcher; `.pi/extensions/lib/fm-branch-dispatch.ts` owns the offer handshake.
  An accepted offer transfers wake ownership to the branch; no acceptor (extension absent, branch disabled, away mode, branch broken) keeps today's wake-to-main path, and watcher-failure alarms always go to main because only main can repair the watcher cycle.
- The branch itself: `.pi/extensions/fm-branch-supervision.ts` creates and reopens the persistent branch session, serializes wakes, mirrors dialog, and merges outcomes.
  It acts only for the current extension generation while that Pi session owns `state/.lock`, rechecking both immediately before branch side effects so replacement or lock loss cannot let an old continuation mutate the new session.
  Every path that cannot reach a working branch falls back to delivering the wake to main - a broken branch degrades to today's behavior, never to a lost wake.
- Branch system prompt: `bin/fm-branch-prompt.sh`; its header owns the byte-stable-prefix contract (no timestamps, no fleet snapshot, no per-wake content).
- Outcome store: `bin/fm-branch-outcome.sh`; its header owns the append-only format and the read cursor.
  Outcomes are written to the store before any note is handed to Pi, and rows that never reach that handoff replay once through the next locked session-start digest.
- Consistency: `bin/fm-lease-lib.sh` owns the per-task lease contract, the main-only role partition, and the deliberate CONFUSED-AGENT-GRADE threat model these guards target (captain-decided; adversarial-grade separation is out of scope and tracked as follow-up design work); `bin/fm-lease.sh` is the command surface.
  The guards are wired into `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` (overlap, lease-checked, with claim serialization retained through the mutation) and `fm-pr-merge.sh`, `fm-merge-local.sh`, and `fm-spawn.sh` (main-owned, branch refused; a relaunch through `fm-control` stays branch-legal recovery).
- Captain autonomy grant: `config/pi-supervision-branch` (docs/configuration.md "Pi supervision branch"). Grants are explicit `project=<task-metadata project>` lines; the branch accepts a wake only when every unread row resolves wholly inside the listed projects, so sharing a home never broadens authority. Absence, malformed grants, fleet-wide wakes, and mixed-project drains stay on main.

## How the branch knows what the captain said

Main's captain and assistant text - never tool calls, tool results, operational injections, or the branch's own merged notes - is mirrored into the branch as read-only `fm-main-mirror` messages at main's turn end, before the next wake is handed over.
The mirror cursor is durable (`state/.branch-mirror-cursor`), so a restart replays only the not-yet-mirrored dialog from main's session file, and a replacement main session re-anchors from its start.
The branch prompt frames mirrored text as context for judgment, never as instructions addressed to the branch; an authorization addressed to main (for example "you may merge when green") does not relax the branch's role limits.

## Two-stage noise filter

Stage one is unchanged: the bash watcher absorbs everything provably fine at zero token cost.
Stage two is the branch's verdict on each handled event, reported through its `fm_branch_report` tool: `routine` merges silently (an idle main gets the appended note immediately, a busy main after the captain's next prompt), `captain` merges with exactly one follow-up turn.
The verdict criteria in the branch prompt mirror the captain-etiquette escalation list; doubt escalates.
Main can read the durable outcome store on demand through its `fm_branch_outcomes` tool.

## Cost model and the byte-stable prefix

The captain accepted the normal provider prompt-caching strategy: a byte-identical branch prefix generated once per firstmate version, the same tool set in the same order on every request, and one shared `prompt_cache_key` per home for all branch sessions (set in a `before_provider_request` hook, and only for providers whose requests already carry that field); main keeps its own per-session key.
Budget roughly 60% cache hits on a fresh branch session's first call and 95% on later calls of the persistent session; reuse is best-effort, never guaranteed.
No caching machinery beyond this exists, deliberately: any later dynamic content in the branch prefix silently removes most of the cache benefit, which is why `bin/fm-branch-prompt.sh`'s header is the contract's single owner and `tests/fm-branch-supervision.test.sh` pins the output to byte identity.

## Away mode

Away mode carries over unchanged: while `state/.afk` exists the away daemon owns supervision, and the branch declines every wake offer for the duration.
What is new is only the attended path: outside away mode, the branch absorbs the routine majority that previously interrupted the captain's conversation, applying the same escalation etiquette the daemon applies while away.

## Verification

Portable regressions: `tests/fm-pi-branch-extension.test.sh` (dispatch, gating, fallback, filter, mirror, cache key, persistence), `tests/fm-branch-supervision.test.sh` (prompt stability, store append-only, leases, guards, non-branch-home invariance), the branch-offer test in `tests/fm-pi-watch-extension.test.sh`, and the recovery test in `tests/fm-session-start.test.sh`.
Live guard: `FM_PI_BRANCH_LIVE_E2E=1 tests/fm-pi-branch-live-e2e.test.sh` exercises the real installed Pi SDK with no credentials and no provider call; run it after every Pi upgrade and record the dated result in [docs/verification/runtime-backends.md](verification/runtime-backends.md).
The strict typecheck in `tests/fm-pi-primary-types.test.sh` pins the extension against the installed Pi package.
