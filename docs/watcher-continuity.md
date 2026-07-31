# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

`bin/fm-watch-arm.sh` owns the harness-independent floor: on an actionable close it arms and verifies one detached successor BEFORE it delivers the wake, so a home that still needs supervision is never blind for the handling turn no matter which adapter sits above it.
The adapters below layer their own restoration on top of that floor rather than being the only thing standing between a delivered wake and no supervision at all.

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
While supervision is still needed and away mode remains inactive, an actionable close or typed failure wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook still starts its own arm at the next Stop after the handling turn rather than before notification, but that is no longer what covers the turn: the arm layer has already armed a detached successor before the wake reached the model, and the next Stop's arm attaches to it instead of starting cold.
This matters most where the hook cannot run at all - a forked session leaves `state/.lock` naming the still-live pre-fork harness, so the forked session's hook stays inert by design and no adapter re-arm ever happens.
The durable wake queue preserves actionable events during the residual active-turn window, and the unchanged bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
No PreToolUse hook denies fleet commands based on watcher status.
The model no longer re-arms after ordinary wakes.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.
The arm layer's own successor is not that pattern: it is deliberately double-forked so it outlives the arm that delivers the wake, and it is then verified through the same live-process-plus-fresh-beacon gate as an owned child, so it is never reported off a process that is already dying.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.
An attached cycle that closes on a genuine wake is not that case: the successor writes its one reason to `state/.watch-successor-output.<pid>` before releasing the singleton, and the attached arm claims and delivers it, arming the next successor first.
A successor is armed only for a delivered actionable wake in a home that still needs supervision and is not away, so a typed failure stays loud and unarmed and an idle home is never left with a detached watcher.

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
The same suite proves the arm layer's own floor: a delivered wake has a live successor holding the singleton at the moment it is delivered, an attached arm delivers its successor cycle's wake instead of a false empty-close failure, an idle home is left with no detached watcher, and the preserved 499-record capture in `tests/fixtures/watch-cycle-exits/cycle-exits.log` still shows the `successor=none` defect that a fresh cycle no longer reproduces.
`tests/fm-watch-triage.test.sh` proves the parked check-in cadence: overdue lanes batch into one wake per window, a fresh cycle inside that window no longer dies on them, the cadence still comes due, and a lane whose declared wait has actually cleared surfaces at once regardless.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
