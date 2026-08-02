# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Exactly one component owns arming per home, and that owner is a property of the primary harness rather than of the moment.
Nothing outside that owner may be told to arm unless a caller has established that the owner did not claim the home; `bin/fm-supervision-instructions.sh --owner-absent` is how a caller states that it has, and only `bin/fm-turnend-guard.sh` passes it.
A second arm beside a live owner does not create a second watcher, because the watcher singleton lock still admits one process, but it does create a second relay whose close the owning arm's reason line never reaches.

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
While supervision is still needed and away mode remains inactive, an actionable close, typed followed-cycle close, or typed failure wakes the idle session through exit 2.

## Session-owner fence

Normal-mode supervision belongs to the live verified harness process recorded in the home's `state/.lock`.
The shared fence in `bin/fm-session-lock-lib.sh` is enforced before watcher startup and every watcher cycle, and before an arm may start, restart, retain, or attach to a watcher.
If a different live harness owns the session lock, the old watcher stands down within one poll and releases the singleton, while arm operations return a typed nonzero `watcher: FAILED - session-owner fence: ...` result without disturbing the new owner's watcher.
Restart serializes the ownership recheck with watcher termination through `state/.lock.acquire`, so a session handoff cannot race a stale arm into stopping the successor session's watcher.
Missing, malformed, dead-owner, and non-harness session locks remain recovery cases rather than fences, and stable process identity prevents a reused owner PID from being trusted.
While `state/.afk` exists, the fence is intentionally bypassed because the away-mode daemon owns supervision without descending from the interactive harness.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The watcher is therefore parked for the whole handling turn by design, so a mid-turn guard warning on a Claude primary reports a parked cycle and names that owner instead of asking for a manual arm.
The durable wake queue preserves actionable events during the residual active-turn window, and the unchanged bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
No PreToolUse hook denies fleet commands based on watcher status.
The model no longer re-arms after ordinary wakes.
Terminal arm-output classification remains defense in depth for the manual recovery path; [Arm-layer cycle contract](#arm-layer-cycle-contract) owns the exact status semantics.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty return from an OWNED child rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and, when that chain ends without one, emits the separate typed `watcher: cycle-ended - the followed watcher cycle closed with no successor; drain the wake queue` and exits nonzero.
The two typed closes are distinct because only the arm that forked a watcher can see that watcher's reason line: a followed cycle's reason went to the owning arm and reaches this arm only through the durable queue, so reporting that close as a supervision failure alarmed on every wake-delivering cycle and pushed the model into arming a second relay.
Consumers that interpret the arm-layer status line must therefore classify a followed close as a drain-and-handle event and reserve the raw supervision-down alarm for `watcher: FAILED`; `bin/fm-claude-stop-autoarm.sh` does exactly that, and both closes stay nonzero so no adapter can read either as a clean empty completion.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, the typed followed-cycle close, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
Its `test_second_arm_does_not_alarm_when_the_owned_cycle_delivers_a_wake` runs the previously-false-alarming sequence end to end - two arms, one watcher, one real wake - and requires the owning arm to relay the reason, the following arm to emit the typed followed-cycle close rather than a failure, and the queue to hold exactly one record.
Its `test_guard_warnings` requires the mid-turn guard banner on a Claude primary to name the Stop-owned arming owner and to mention no manual arm command.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, and exit-2 translation, including that a followed-cycle close rewakes for a drain without the supervision-down alarm.
`tests/fm-supervision-instructions.test.sh` covers the `--owner-absent` split between the mid-turn parked line and the turn-end manual-recovery line.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
The Pi and OpenCode adapters deliberately treat any arm child that did not own wake delivery as a continuity failure to retry, so they classify the typed followed-cycle close by its nonzero exit rather than by its own line; that is their existing owning-delivery contract and is unchanged here.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
