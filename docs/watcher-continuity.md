# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its loop bounds and supersession baton.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing away-mode and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher emits one last-resort notice for the continuous failure episode; later consecutive Stop cycles exit 2 to guarantee another Stop-owned retry without repeating the notice until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and no live away-mode daemon owns this home, an actionable close wakes the idle session through exit 2.

## Away-mode stand-down

Away mode transfers watcher ownership to `bin/fm-supervise-daemon.sh`, so every native continuity mechanism stands down for it: the Claude Stop auto-arm, the Cursor stop-hook park, and the OpenCode plugin all stay inert rather than running a second supervision cycle against the daemon's.
`bin/fm-watch.sh` stands down in the same sense from the other side: it drops its own triage and goes one-shot, handing every wake to the daemon that batches and classifies them.

That stand-down is conditioned on the DAEMON, never on the `state/.afk` flag.
The flag is a durable declaration that the captain stepped away; it is written before any daemon exists on the harness-native launch path, it survives a restart by design, and nothing removes it when the host kills the daemon.
Standing down on the flag alone therefore produces the one state no home may reach: no supervision and no alarm at the same time, silently, for as long as the flag remains.

`fm_afk_supervision_state` in [`../bin/fm-wake-lib.sh`](../bin/fm-wake-lib.sh) is the single owner of that distinction and the only vocabulary any caller uses:

| state | meaning | effect |
| --- | --- | --- |
| `off` | no flag | normal harness supervision applies |
| `daemon` | flag plus a live, identity-matched daemon holding `state/.supervise-daemon.lock` | native mechanisms stand down; exactly one supervision cycle, the daemon's |
| `armed-no-daemon` | flag with no daemon behind it | native mechanisms stay armed AND name the broken away mode; the watcher keeps its ordinary triage |

Liveness is proven by the same recorded process identity the lock already carries, so a reused pid never passes as the daemon.
`bin/fm-afk-launch.sh status` exposes the state to callers that cannot source bash, and takes no lock so a concurrent launch never delays the answer.
`bin/fm-afk-launch.sh down-notice <cover>` exposes the alarm sentence itself the same way, so the JavaScript plugin and the TypeScript extension print the one wording `fm_afk_daemon_down_notice` owns rather than each keeping a copy that drifts.
`<cover>` names the mechanism supervising in place of the dead daemon, the only part that differs per harness - and per call, not per adapter.
A banner that has just reported its own mechanism broken passes an EMPTY cover, and the sentence then says nothing is covering the home: an alarm that claims a supervisor in the same breath as its failure is the same "supervision that does not exist" this contract exists to stop.
That empty cover still produces the whole sentence, never a blank answer and never a truncated one, because a message that merely omits the claim would read as a cover to anyone skimming it.
Omitting the argument altogether stays a caller error and exits 2, so a caller that forgot the clause is caught rather than silently promoted to "nothing covers this home".

In `armed-no-daemon`, supervision is restored by the ordinary mechanism - the whole ordinary mechanism, including the watcher's own triage.
A re-armed watcher that still one-shot every benign signal, every distinct stale hash, and every heartbeat would hand them to a daemon that is not there to absorb them, and each handoff costs a model turn; the ordinary triage absorbs them exactly as it does outside away mode.
The failure is named where the session will see it, and every adapter that re-arms by itself names it on its own wake surface: the Stop auto-arm's rewake and failure banners, the Cursor park's wake follow-up, the OpenCode plugin's wake prompt, and the Pi extension's wake follow-up.
Those four carry it because arming is what keeps the watcher healthy, and a healthy watcher silences both the turn-end guard and the pull guard - so without it the state would wait for the next session start.
It is also named by the turn-end guard's block reason (which the Cursor park's repair follow-up carries), the pull guard's banner, and the session-start digest and supervision block.
The repair line diagnoses that state and then gives the harness's own repair instruction unchanged, because only claude, cursor, pi, and opencode re-arm by themselves: telling codex or grok that supervision "stays armed" would withhold the checkpoint or tracked background task that actually restores it.
No mechanism ever clears `state/.afk`: leaving away mode is the captain's decision, and a home that silently dropped it would start injecting per-wake instead of batching.
A home in `armed-no-daemon` with nothing in flight raises nothing, because supervision need is unchanged by this contract - the alarm appears with the first real supervision need, and at the next session start.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
For every supported arm path, a successor that observes an accepted down stretch emits `check: rearm-resurface` through the ordinary durable handling path before settling into its live wait.
That recovery presentation includes all unacknowledged queue rows, the cursor-folded OPEN DECISIONS set, and still-unread informational status lines, so a still-open decision or a buried `note:` answer reappears even when recovery has no queue row of its own.
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
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence, while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

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
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, and the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
It covers both away-mode states with the same flag on disk: a live daemon keeps the hook inert, while a flag with no daemon arms and names the broken away mode in its banner.
`tests/fm-afk-launch.test.sh` covers the state vocabulary itself, including a live pid whose identity does not match, proves a harness-native entry never reads as supervision before its daemon lands, and covers the shared alarm sentence speaking in `armed-no-daemon` only.
`tests/fm-cursor-primary.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-session-start.test.sh` cover the same two states for the Cursor park, the OpenCode plugin, and the session-start digest.
`tests/fm-pi-watch-extension.test.sh` also drives both adapters against the real launcher and asserts that their delivered wake names the broken away mode when the daemon is gone and says nothing about away mode otherwise.
`tests/fm-watch-triage.test.sh` covers the watcher's own half of the stand-down over a real watcher process: with a live daemon a benign signal and a first-sighting declared pause are handed off one-shot, and with the same flag and no daemon the benign signal, the no-change heartbeat, and that pause all go back through the ordinary triage.
`tests/fm-supervision-instructions.test.sh` covers the `armed-no-daemon` repair line naming the broken away mode while still rendering the harness procedure and its queue-pending and x-mode prefixes, including for the harnesses that have no automatic re-arm.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
