# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts`, omp's `.omp/extensions/fm-primary-omp-watch.ts`, and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`: an owning `session_start` arms the replacement generation without waiting for a model turn, and a state-scoped replacement handoff carries every actionable close whose delivery overlapped `session_shutdown`, including a main follow-up Pi accepted but had not yet consumed, branch handling, and a retiring child that reports after the bounded shutdown wait.
A main follow-up counts as delivered once Pi accepts it, never once the model reads it, because a follow-up queued while main is streaming joins the running run without a `before_agent_start`; the extension header owns how consumption is observed and why it only decides what a replacement replays.
omp's replacement follows the same generation-owner contract in `.omp/extensions/fm-primary-omp-watch.ts`, whose header owns the one difference: omp reports no shutdown reason, so every shutdown with a pending actionable close persists the handoff for the next owning `session_start` to replay.
Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its Pi-host stand-down, loop bounds, and supersession baton.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher commits one last-resort notice for the continuous failure episode; a refused notice commit stays silent for a later retry, and after a successful notice later Stop cycles exit 2 without repeating it until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns that notice commit contract, the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi, omp, or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It confirms the handling handoff against that successor before scheduling the follow-up, retries once against the current generation and successor, and treats a failed confirmation as a restoration failure: it classifies the error, retires a successor that is no longer alive, and surfaces exactly one typed message.
A failed confirmation is never swallowed.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi, omp, and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher is live and no open generation claim is still deciding, so a finished, hung, or identity-mismatched claim cannot suppress it ([`turnend-guard.md`](turnend-guard.md#harness-integrations) owns that boundary).
The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce; it enters its poll loop immediately and keeps scanning signals, stale panes, and checks.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
The foreground checkpoint reports a watcher that yields ownership and exits without a wake as a failed wait, preserving the replacement lock and all unhandled queue rows.
Unknown harnesses without a verified background wake mechanism use the same checkpoint entry point; [`supervision-protocols/unknown.md`](supervision-protocols/unknown.md) owns their operating instructions.
`tests/fm-watch-checkpoint.test.sh` exercises real watcher self-eviction, quiet deadlines, singleton contention, durable actionable delivery, and the operating rule each emitted terminal outcome routes to.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Recovery episode acknowledgement

A recovery episode is one generation of `state/.watcher-down`, and it is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
An unacknowledged downtime generation is announced at most once: the first recovery marks that generation announced, and later arms wait until a new down stretch mints a new generation.
A non-successor watcher start after an announced-but-unacked episode is a new down stretch and mints a fresh generation so buried decisions still resurface once.
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one, and an already-announced generation stays announced.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence (further scoped per actor - see "Per-actor acknowledgement" below), while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Per-actor acknowledgement

`bin/fm-wake-drain.sh` consumes the queue per actor, not per whole-queue cutoff, using `bin/fm-lease-lib.sh`'s existing `fm_lease_actor` identity (`FM_SUPERVISION_ACTOR`, unset or `main` for every non-Pi harness and Pi's own main session; `branch` only inside the Pi supervision branch's own bash tool calls, injected deterministically by the extension - never agent memory).
Every presented row is claimed to exactly one actor under the durable queue lock.
An ordinary presentation drain bounds both its initial queue-lock acquire and its later status-presentation-lock acquire at the deadline owned by the script header.
A live initial queue-lock holder produces one PID-naming advisory and skips the whole drain before any claim or mutation, while a live status-presentation-lock holder produces one such advisory after raw wake presentation and leaves status annotations, sections, and cursors retriable on the next drain.
Acknowledgement invocations and every other mutation-critical queue-lock acquire retain blocking semantics, so acknowledgement atomicity is unchanged.
Main records its presented set in `state/.main-eligible-rows`.
A branch grant is published through `bin/fm-wake-grant.sh` under that same lock in `state/.branch-eligible-rows`, bound to the live branch process and extension generation recorded in `state/.branch-eligible-owner`, and publication is refused if main already claimed any requested row.
A main drain validates that owner evidence under the queue lock and reclaims the grant when its process is gone or its identity no longer matches.
A main drain claims every currently unclaimed row and excludes an active branch grant from both presentation and acknowledgement.
Its `--ack-through <SEQ>` deletes only claimed main rows at or below the cutoff, while a branch acknowledgement deletes only claimed branch rows at or below its cutoff.
Every settled branch prompt releases any residual grant, so an omitted or failed acknowledgement leaves the durable row available to a later main drain; a successful acknowledgement has already removed it.
An acknowledgement whose cutoff removes none of the actor's rows while a presented row above the cutoff still waits is reported as having acknowledged nothing, together with the exact `--ack-through` and `--recovery-generation` command for that presented row; the presented set is read before any re-claim, so a row that arrived after presentation is never named for unseen acknowledgement.
If a branch offer loses the claim race to main, it rejects its settlement so the watcher retains the actionable close until Pi accepts its main follow-up.
[`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners) owns branch eligibility, mixed-queue dispatch, the pre-drain recheck, and heartbeat's all-or-nothing rule.
A check-kind row is main-owned in every mode, including a heartbeat review, so it is never part of a branch claim and never defers one; main is woken for it on that check's own triggering close.
`fm-wake-drain.sh` never reclassifies a row itself: it filters the queue to the current actor's opaque claim before same-key deduplication, then presents and acknowledges only that actor-local view.
A missing or empty branch snapshot is refused loudly rather than read as "nothing eligible", because reaching the drain without the non-empty handoff promised by the extension is a wiring bug.
Because branch claims contain no check-kind rows, a branch acknowledgement skips check-specific receipt scans.
`tests/fm-wake-queue.test.sh`'s mixed-queue actor, stale-acknowledgement remedy, and presentation-deadline tests drive the real scripts: branch acknowledgement cannot swallow a main row, a concurrent main turn cannot present or acknowledge an active branch grant, a no-op stale acknowledgement names the current presented wake's exact command, live-holder presentation contention stays bounded and retriable, and acknowledgement locking remains blocking.
`tests/fm-pi-branch-extension.test.sh` pins extension-side classification, claim publication and release, and the pre-drain recheck.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after its durable wake was handled and acknowledged, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, `/fork`, and reload, same-instance shutdown-plus-start, automatic re-arm before any model turn, a fresh extension-module rebind carrying all in-flight actionable closes exactly once, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, and the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
`tests/fm-watch-recovery-loop.test.sh` covers the once-per-generation announcement bound with the real Pi extension against a refused handling handshake, and a handling successor that must surface a real crew event instead of going blind.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
It also covers generation-claim single-flight, stuck-claim supersession, superseded-owner silence, notice-marker refusal and retry, ownership-atomic episode reset, and the legacy upgrade shim; [`turnend-guard.md`](turnend-guard.md) owns those behavior contracts.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset; [`turnend-guard.md`](turnend-guard.md#regression-coverage) lists that suite's full generation and legacy claim coverage.

## Active limits and verification

The goal is continuity without a Pi, omp, or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
