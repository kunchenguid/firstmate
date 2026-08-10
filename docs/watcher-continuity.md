# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher emits one last-resort notice for the continuous failure episode; later consecutive Stop cycles exit 2 to guarantee another Stop-owned retry without repeating the notice until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

## Away-mode parking

Continuity above transfers to the away-mode daemon while `state/.afk` exists, and this section is the single owner of that boundary.
The daemon (`bin/fm-supervise-daemon.sh`) runs its own `bin/fm-watch.sh` child and classifies every wake in bash, so a primary adapter that keeps arming takes the watcher singleton away from it - and an arm run with `--restart` kills the daemon's watcher outright.
A stolen singleton is worse than a duplicate: the watcher deliberately one-shots and forwards everything while away mode is on, so every routine wake then reaches the primary pane and spends the firstmate turn away mode exists to save.

Three layers hold the boundary, and each is independently sufficient for the case it covers.

`bin/fm-watch-arm.sh` is the deterministic layer: it rechecks `state/.afk` before restart signaling or lock cleanup, attachment, and the watcher fork; while the flag exists it arms nothing, emits nothing, holds no watcher lock, and parks at its configured away-mode poll cadence.
It applies the same recheck at the two points where an arm returns a wake to its caller - its own child's actionable close, and the durable delivery record an owned or attached arm resolves - so an arm that was already running when away mode began exits successfully with `watcher: stood-down` instead of handing that wake back.
That boundary is what covers a caller with no adapter of its own, where arm completion itself is the wake: a Grok tracked background task converts completion into a synthetic user message, and a manual recovery probe prints the reason.
An arm that reaches an arming gate instead remains interruptible, and after the flag clears it replaces itself with a normal arm cycle under the same process id so the tracked task resumes supervision without a model turn.
Those checks cover every established-away-state case, but one deliberately accepted AFK-entry race remains across the arm layer and the Pi and OpenCode final-delivery paths.
If `state/.afk` is created in the instant after the final flag check and before the immediately following completion or delivery, at most one spurious wake can reach firstmate during that away-mode transition.
This fails safe toward one extra wake, never a missed wake: `state/.wake-queue` still retains every record and `bin/fm-wake-drain.sh` remains its sole consumer.
Point-in-time checks cannot close that transition race by construction; fully closing it requires the deliberately deferred cross-component AFK-transition handshake.
Every established-away-state case remains covered: an arm or adapter that observes the flag before its decision parks or suppresses delivery.

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` are the adapter layer: while away mode is active they start no arm child, deliver no ordinary wake, and start no continuity retry, whether away mode began before the decision or while a cycle was already live.
If a close or pending retry observes away mode during the AFK-entry window, the adapter records an owner-scoped parked resume and polls with an unreferenced timer until the flag clears.
The live generation or lock owner then re-arms automatically without replaying the suppressed wake; a retired Pi generation and an OpenCode session that no longer owns the lock discard their parked resume.
An explicit Pi `fm_watch_arm_pi` call returns a successful stand-down message rather than arming.
An adapter that observes away mode before spawning still returns its own benign `watcher: stood-down` result, while an arm process that reaches an arming gate parks and one that reaches a wake-return boundary stands down.
A genuine arm or spawn failure still surfaces once with no retry loop behind it, because the daemon owns the watcher and a retry storm would be the same wasted turn.
Nothing is lost: the watcher enqueues each wake to `state/.wake-queue` before advancing its suppression markers, housekeeping classifies each unseen record without consuming it, and the next `bin/fm-wake-drain.sh` remains the sole consumer.

Claude's Stop auto-arm (`bin/fm-claude-stop-autoarm.sh`) already exits before claiming the home while `state/.afk` exists, and Codex's foreground checkpoint protocol is model-driven with no adapter injection at all.
Grok has no automatic watcher adapter, so the arm layer is its whole boundary: a new tracked background arm parks before arming, and one already live after the flag becomes observable stands down after preserving its wake.
Away mode ends by clearing the flag, after which a parked arm resumes ordinary supervision itself and adapters return to ordinary behavior.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after the durable wake queue was drained, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
