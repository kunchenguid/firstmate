# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
While supervision is still needed and away mode remains inactive, an actionable close or typed failure wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue and the PreToolUse continuity gate cover the residual active-turn window.
The gate allows wake drain, arm recovery, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight, no identity-matched live watcher holds the home lock, and that missing watcher is unexplained.

A watcher that closed because it had a wake to deliver is explained, not missing.
That close is the design working: the arm's exit is the notification, so the home is deliberately unwatched for the whole handling turn - the one turn on which the model must read crew state, merge, tear down, and dispatch.
Refusing there does not restore supervision; it only blocks the handling of the wake and leaves the recovery-only manual arm as the sole way forward, which manufactures the very condition the arm layer's cycle-end alarm exists to report.
So the gate allows fleet commands while the ledger shows the most recent cycle closed for a delivered wake within `FM_CONTINUITY_GAP_GRACE`, and the turn-end guard remains what keeps a turn from ENDING in that gap.
Past that window, or for any other close, the refusal and its recovery guidance stand.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
The model no longer re-arms after ordinary wakes.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one, unless the ledger proves the owning arm delivered that cycle's wake.

Only the arm that OWNS a watcher child reads that cycle's wake output, so an arm merely attached to the same watcher cannot tell a delivered wake apart from a watcher that vanished.
Two arms following one watcher is ordinary whenever a manual recovery arm and the Stop-owned auto-arm overlap.
Before an attached arm calls a close unexplained it reads the owner's own ledger record for that exact watcher PID, anchored at the moment it began following so a reused PID cannot answer for the cycle.
Proof of a delivered wake ends that arm quietly with `watcher: cycle closed with a delivered wake pid=<N> (reported by its owning arm)`, because the owner already reported the reason and a second report would be a duplicate wake.
No proof still fails loudly.
Claude's Stop hook reads that quiet close as a clean cycle and stays silent rather than rewaking for an already-delivered wake, and Grok's protocol names it so a model-driven home re-arms instead of acting on it.
Pi's and OpenCode's adapters are unchanged by it: their close classifiers already treat every non-actionable close as a failure that triggers continuity restoration, which is what those homes did with the previous typed failure too.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
`bin/fm-watch-cycle-lib.sh` owns that record format and every read of it, including the attached-close and continuity-gate queries above; `bin/fm-watch-arm.sh` owns the write side and the arm lifecycle state machine.
A reason carrying the `actionable-` prefix means the cycle closed because the watcher had a real wake to deliver; every other reason means the observer could not account for the close.
Every query fails toward "not explained", so a missing or truncated ledger can never silence an alarm or open the gate.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
It also drives two real arms against one real watcher and holds each to its honest verdict: a real wake closing the cycle must leave the attached arm quiet rather than alarming, and the same two-arm shape with the watcher killed instead must still produce the typed cycle-end failure.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state, allows the recorded post-wake gap while refusing an absent, superseded, stale, or non-delivering close, and preserves the registered Stop hooks.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, identity, AFK, need, single-flight, and exit-2 translation.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
