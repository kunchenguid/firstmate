# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`: an owning `session_start` arms the replacement generation without waiting for a model turn, and a state-scoped replacement handoff carries every actionable close whose delivery overlapped `session_shutdown`, including a main follow-up Pi accepted but had not yet consumed, branch handling, and a retiring child that reports after the bounded shutdown wait.
A main follow-up counts as delivered once Pi accepts it, never once the model reads it, because a follow-up queued while main is streaming joins the running run without a `before_agent_start`; the extension header owns how consumption is observed and why it only decides what a replacement replays.
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

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It confirms the handling handoff against that successor before scheduling the follow-up, retries once against the current generation and successor, and treats a failed confirmation as a restoration failure: it classifies the error, retires a successor that is no longer alive, and surfaces exactly one typed message.
A failed confirmation is never swallowed.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher is live and no open generation claim is still deciding, so a finished, hung, or identity-mismatched claim cannot suppress it ([`turnend-guard.md`](turnend-guard.md#harness-integrations) owns that boundary).
The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce; it enters its poll loop immediately and keeps scanning signals, stale panes, and checks.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
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

Every non-zero cycle must be reportable from its failure line alone.
`bin/fm-watch.sh` tracks the phase it is in and prints `watcher: FAILED - watcher cycle exited <rc> during <step>[ after SIG<name>]` on any non-zero exit, including a pre-lock refusal, a trapped signal, and a `set -u` abort.
The arm captures the watcher's stderr, replays it on its own stderr, and quotes a bounded tail of it in the failure line; when the watcher could not print its own reason, the arm synthesizes one carrying the exit code, signal, lock and beacon state, queued-wake count, and that stderr tail.
An arm torn down by HUP, INT, or TERM tears its watcher down too, so it replays the watcher's `watcher: FAILED` lines from the captured stdout, and its captured stderr, on its own stderr before deleting either file.
That replay is filtered to `watcher: FAILED` because the arm's stdout is what the adapters and `bin/fm-claude-stop-autoarm.sh` classify, and an unfiltered replay would surface a wake reason line for a cycle that is being torn down on purpose.
The other typed failures carry the same class of evidence: the attached-cycle failure names the target's liveness, the beacon age, the queued-wake count, and the last lifecycle row recorded for that watcher, and the unconfirmable-watcher failure names the lock pid, its liveness, whether it matches this home's watcher identity, and the beacon age.

## Attach verification

`watcher: attached pid=<N>` claims a live cycle, so it is not decided by a single read.
A fresh beacon proves the watcher was alive recently, not that it is alive now: a beacon inside the grace has been observed with no watcher process left at all.
Each attach candidate must keep verifying as this home's live watcher - process alive, lock identity unchanged, beacon fresh - for the whole `FM_ARM_ATTACH_VERIFY` window (2 seconds by default) before the attached line is printed, and the line reports the window it survived plus `beacon advanced` when the beacon moved inside it, which is the only positive proof of progress rather than of recent existence.
A candidate that stops verifying inside that window is a failed attach, never a healthy one: the arm re-executes itself as `--restart` so supervision is genuinely restored, bounded by `FM_ARM_RESTART_MAX` (one restart per arm, tracked through `FM_ARM_RESTART_DEPTH`) so a watcher that dies on every launch reports the failure instead of looping.
A lock that moves inside the window to a different pid which passes that same gate is not a failed attach: that successor is a verified healthy watcher, and `--restart` would TERM it, so the arm retargets onto the successor and verifies it from scratch, bounded by `FM_ARM_ATTACH_RETARGET_MAX` (two retargets per attach) so a flapping lock still ends in an honest failure instead of looping.
Restart is reserved for a target that actually stopped verifying - a dead process, an identity mismatch, or a stale beacon.
`--restart` re-reads the lock immediately before it acts and refuses to signal a pid that satisfies `fm_watcher_healthy` at that moment, reporting `watcher: restart declined - <why>` and following that watcher instead of starting a second one behind it.
That check is keyed on current state rather than on having observed a holder as healthy, because a guard keyed on observation leaves a hole for every path that reaches the stop without it, and each hole is another way to end a running watcher.
It cannot strand a wedged watcher: `fm_watcher_healthy` also requires the liveness beacon fresh within `FM_GUARD_GRACE`, and only the watcher process touches that beacon, so a wedged holder stops satisfying the predicate and stays replaceable.
The judgement and the stop are separate operations on state another process owns, so the stop is made conditional rather than trusted: the arm captures the beacon value it judged and re-checks, at the instant of stopping, that the lock still names the same pid and that its beacon has not advanced.
A holder that changed or resumed beating in between is declined instead of stopped.
This does not eliminate the window in the general case and is not claimed to: no check placed before a stop can, because the check and the stop cannot be made one operation while the beacon is an unguarded write by the watcher itself.
What it changes is the outcome, from stopping a watcher that had come back to declining because it came back.
The residual is the interval between that final re-check and the signal itself, which is a pair of adjacent reads rather than a window any external delay widens.
Publishing the lock identity at claim time, below, removes the settling state and every path that reached this stop through a lock the arm could not verify, but it does not close this residual and is not claimed to: the beacon remains an unguarded write by the watcher, so the final re-check and the signal stay two operations.
Exhausting the retarget budget is never one of those, because the lock still names a pid that passed the health gate on the sample that ended the window, and `--restart` opens by sending TERM to exactly that pid.
A verification that ends with a healthy watcher holding the lock therefore refuses to restart and reports `watcher: attach abandoned - <why> (a healthy watcher holds the lock)`, which names that refusal apart from a spent restart budget.
A self-triggered restart that TERMs a live holder which has not exited by the time its bounded wait ends does not fall through into re-verifying that pid either.
The watcher runs its TERM trap only when its current foreground wait returns, and that wait is bounded by `FM_POLL` rather than by the verification window, so the pid would pass every sample and be announced as a verified attach while already doomed.
That arm reports the honest failure instead; an operator-initiated `--restart` keeps its established behavior of attaching to a healthy holder that outlived the TERM.
A watcher's lock is verifiable from the instant it exists.
`fm_lock_try_acquire` writes `fm-home`, `watcher-path`, and `pid-identity` into the lock's owner directory before creating the symlink that publishes the lock, and readers reach the lock only through that symlink, so a claim is never observable without the records that identify it.
Writing those records after the claim instead left the lock naming a live pid and nothing verifiable for as long as the claiming watcher took to get back to them, which included two unbounded waits on the wake-queue lock that `bin/fm-wake-drain.sh` is entitled to hold for ten seconds, and no reader can tell that state apart from a lock left behind by a dead watcher.
A lock the arm cannot verify is therefore genuinely unhealthy rather than merely new, and needs no tolerance in the verification window; a live holder it cannot identify is still never signalled, because `--restart` acts only on a lock that identifies its holder as this home's watcher.
With the restart budget spent the arm reports `watcher: attach abandoned - <why> (no restart budget left)` and starts its own watcher rather than claiming the dead one.
One owner in `bin/fm-watch-arm.sh` handles every failed attach, so the restart budget and the line it prints are identical at the entry attach, the in-loop attach, and the owned-child attach.
Past the verification window the attached poll re-checks the same three facts every `FM_ARM_ATTACH_POLL`, so a later death is caught within one poll and never silently inherited.
A replacement candidate that fails verification is re-evaluated on that same cadence rather than announced, and that re-evaluation is bounded by `FM_ARM_ATTACH_REPLACEMENT_MAX` consecutive failures, reset by any candidate that does verify.
Each attempt starts a fresh verification with a fresh retarget budget, so a lock held in a flapping-but-sampled-healthy state could otherwise keep an arm re-attempting forever and never reach a terminal result, which is the same quiet failure as a cycle that exits without saying why.

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
It also holds a lock with a fresh beacon through a holder that dies only after the arm has demonstrably read it, proving the arm never reports that attach as healthy and instead restarts (or, with no restart budget, abandons the attach and starts its own watcher), hands the lock to a second genuinely healthy holder mid-window to prove the arm retargets onto that successor and leaves it alive, and it terminates a running watcher and refuses a pre-lock start to prove a non-zero exit names its step, its signal, and the stderr the cycle produced.
It also TERMs an arm that owns a live watcher to prove the interrupted arm replays that watcher's own failure line from the captured stdout before deleting it, and that a non-`watcher: FAILED` line in the same capture is not replayed.
It exhausts the retarget budget against two live identity-matched holders to prove the arm abandons that attach rather than restarting over the healthy holder.
It claims the watcher lock through the production library and proves the home, watcher path, and identity are already published and already satisfy the health gate, holds the wake-queue lock while a real watcher starts to prove that identity is visible in the same instant as the lock rather than after the contention clears, and strips the identity from a live holder's lock to prove `--restart` leaves a holder it cannot identify running instead of stopping it.
It also runs a self-triggered restart against a TERM-resistant identity-matched holder, differing from the operator-restart case in `FM_ARM_RESTART_DEPTH` alone, to prove that arm reports the unfinished stop instead of announcing a verified attach to the pid it just signalled.
It hands the lock to a healthy successor before a restart acts, to prove the signal-time check declines and then follows that watcher, and it pins the matching hazard by proving a holder whose beacon has gone stale is still replaced.
It also refreshes a stale beacon between the health judgement and the stop, ordered by the lock read the precondition itself performs rather than by timing, to prove the stop is declined rather than issued against a holder that came back.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
It also covers generation-claim single-flight, stuck-claim supersession, superseded-owner silence, notice-marker refusal and retry, ownership-atomic episode reset, and the legacy upgrade shim; [`turnend-guard.md`](turnend-guard.md) owns those behavior contracts.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset; [`turnend-guard.md`](turnend-guard.md#regression-coverage) lists that suite's full generation and legacy claim coverage.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
