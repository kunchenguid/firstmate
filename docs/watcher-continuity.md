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

## Turn-settle input and reply recovery

Pi's own `AgentSession.prototype.prompt()` (`agent-session.js`) has no atomic check-and-set between reading its `isStreaming` flag and committing to a new run: it awaits several extension hooks (`input`, compaction and auth checks, `before_agent_start`) before setting `_isAgentRunActive = true` inside `_runAgentPrompt`.
Two `prompt()` calls that both observe "idle" - a captain message submitted through the interactive loop and a watcher wake delivered through `fm-primary-pi-watch.ts`'s `sendWake` via `pi.sendUserMessage(..., {deliverAs: "followUp"})` - can both fall through to a concurrent run against the same session state.
That is a genuine Pi SDK gap: no extension hook fires early enough, or atomically enough with the internal check, to reliably prevent it from firstmate's own tracked code without a full submission-serializing mutex, which was rejected as disproportionate new risk for a rare race (`docs/verification/pi-watch-extension-reply-recovery.md` records the reproduction and that decision).
The chosen mitigation detects the race's visible symptom instead of trying to prevent it: a turn that settles without ever producing a synthesized reply to its last conversational message, typically a dangling tool call (the `bin/fm-wake-drain.sh` run a wake instructs) or a message with no assistant response at all.
The race has a second, invisible outcome as well: the losing `prompt()` call never appends anything, because pi-agent-core's `Agent.prototype.prompt` throws "Agent is already processing a prompt." ahead of `normalizePromptInput`.
When the loser is the captain's own message, the winning wake turn answers normally and leaves a perfectly healthy transcript behind, so no inspection of the transcript can see that the captain was dropped.
Both outcomes are therefore covered, and captain-input loss is checked first because it is the one the transcript cannot reveal.

`.pi/extensions/fm-primary-turnend-guard.ts`'s `agent_settled` handler owns this contract, alongside its existing supervision-guard `followUp`.
Not every `agent_settled` is terminal, though: the losing side of that same race still reaches `_runAgentPrompt`, has its inner `agent.prompt()` reject at once with "Agent is already processing a prompt.", and its `finally` block emits a settle while the winning turn is still streaming.
`_isAgentRunActive` and `isIdle()` cannot recognise that settle, because the race corrupts exactly that flag.
The handler therefore counts logical runs in flight - incremented on `before_agent_start`, which Pi emits only for a genuinely new run and never for a message queued into an active one - and returns without evaluating anything while that count is still above zero, so the checks below are judged only on the settle that drains it.
The same count is re-checked after the supervision guard's child process returns, because Pi clears its run flag before emitting the settle and a fresh prompt can open a new run during that await; a run that appeared in the meantime suppresses this settle's judgement entirely rather than letting it read the new turn's mid-flight tail.
Pi's extension runner awaits handlers only within one emit, so two settles can reach this handler at once across that same await; one evaluation runs at a time, and a settle arriving mid-evaluation is dropped rather than judging the same state a second time with its own stale latch snapshot - both latches are consumed before that claim, so a dropped settle still never leaves one behind.
Captain-owned input is recorded from Pi's `input` event, which fires at the very start of `prompt()` - before the `isStreaming` check - and therefore also for the call that goes on to lose.
On a genuine settle the handler first resolves every recorded input that did reach the transcript; the first one that did not is resubmitted exactly once through a follow-up that quotes it - together with any images it carried, so an attachment the question depends on is not lost - and identifies it as a captain message that never arrived, and it is dropped from the pending list at that moment, so no repetition can produce a second copy.
Only one follow-up fires per settle, so that resubmission takes priority over reply recovery, whose own turn settles and is judged normally afterwards.
Tracking is deliberately narrow: only genuine captain sources are recorded (never `extension`, which is how watcher wakes and this guard's own follow-ups submit), and text starting with `/` or `!` is skipped because Pi expands it after the event, which would make the appended message no longer contain the recorded text and an ordinary command look lost.
A message Pi is queueing into an already-active run is skipped too - it reports that by setting `streamingBehavior` on the event - because that path is Pi's own correct handling, not what the idle-vs-idle race loses, and because a queued message is appended only when the run consumes it: pressing Escape clears the queue back into the editor, so its absence from the transcript is a withdrawal rather than a loss and must never be replayed.
A recorded input is judged only once its own `prompt()` call reached `before_agent_start`, the boundary that separates a call which committed to a run from one that died earlier - `prompt()` still throws for an unselected model or failed auth well before that hook, appending nothing while the captain sees the error and resends, and judging that phantom would replay an instruction the resend already carried out.
That hook's own event carries the prompt it is starting and expansion is a no-op for a tracked recording, so a recording is committed only by a start that quotes it back verbatim - an unrelated run's start leaves it alone.
A new recording drops any uncommitted predecessor, and a recording still uncommitted when a settle arrives is dropped unjudged, because a call that was going to commit reaches the hook well before any settle.
A recording is superseded outright when the captain submits the same text again: losing the race is not silent for them, because the loser's rejection escapes `prompt()` into the interactive loop and is printed as a chat error, so a resend is the natural reaction and recovering the earlier recording too would execute one instruction twice.
Equivalence is exact text, the only signal the events carry, so a reworded resend is not recognised as the same instruction.
That supersession only reaches a resend submitted before a settle picked the recording up, and the captain reaction is not bound to arrive that early: it can just as well land after recovery already went out, while the recovered copy is still being carried out, and by then the recording it would have superseded is gone.
Recovery therefore keeps the text it just resubmitted, and a captain submission of exactly that text is claimed by the `input` event and not delivered to the model at all (`action: "handled"`).
Delivering it - even behind a note that states the duplication and asks for a single execution - would put a second executable copy of that instruction in front of the model, and prose cannot enforce idempotence, so a destructive instruction could still run twice.
Nothing is lost by that: the identical text is already in the conversation verbatim and is being carried out, which is exactly what the resend was meant to achieve.
Suppressing it silently would be the lost input this whole mechanism exists to prevent, so the captain is told through `ctx.ui.notify` - a chat line the model never reads - that the instruction is already running and that a reworded submission is the way to send a genuinely new one; the notice is best effort, because a headless or RPC context may carry no UI, and the suppression rather than the notice is the safety property.
A suppressed resend is not tracked either, because it never reaches the transcript and tracking it would let the next settle judge it lost and resubmit the very copy that was just withheld.
The window closes on the settle that ends the recovery turn: once an answer to the recovered instruction exists, an identical submission after it is a deliberate repeat and reaches the model untouched.
The comparison against the transcript is exact rather than by containment: a tracked recording never starts with `/`, so Pi's skill-command and prompt-template expansion return it unchanged and the appended message carries it verbatim - containment would let a longer later message silently absorb a genuinely lost short one.

On every settle where the supervision guard itself found nothing to say, it reads `ctx.sessionManager.getEntries()` and inspects the last conversational message entry, skipping everything that carries no reply expectation of its own - non-message entries such as the session-start digest, and message entries whose role is bookkeeping rather than conversation (Pi flushes an inline `!cmd` bashExecution message into the session right before `agent_settled`).
The turn is healthy only when that entry is an assistant message that both carries genuine text and leaves no tool call unresolved, so a short preamble alongside the tool call that never came back still counts as unanswered; anything else - a dangling tool call, a bare user or watcher-wake message with no reply, an errored assistant message with no visible text - triggers exactly one recovery `followUp` instructing the model to check the transcript, finish any unresolved tool call, and answer the pending message without repeating an answer already given.
A turn the captain stopped by hand is the one exception: an assistant message with stopReason `aborted` is a deliberate human decision, counts as healthy, and is never auto-restarted. An `error` stop still earns its nudge, because nothing confirms the captain saw it and no human chose to stop there.
A `orphanedReplyFollowupActive` latch, mirroring the existing `guardFollowupActive` pattern, absorbs the settle produced by that same recovery turn so repetition of an unchanged stuck state never creates a second turn; it is consumed on the very next settle whichever branch handles it, so a settle claimed by the supervision guard can never leave a stale latch behind to swallow a later, genuinely unanswered episode.
A per-generation bounded attempt counter (`ORPHANED_REPLY_ATTEMPT_LIMIT`, currently 3) stops the retry loop after repeated distinct failures and commits one loud, once-only "recovery gave up" notice instead of retrying forever; a later healthy settle resets both the counter and the notice, and `session_start` resets them along with the in-flight count and the pending captain-input list, so neither a fresh, unrelated unanswered episode nor a new generation ever inherits an exhausted budget.
Only one `followUp` is ever sent per settle: the pre-existing supervision guard takes priority, and reply recovery runs only once that guard is clean, so the two mechanisms can never race each other's delivery.

One known gap is left open deliberately: a recovered captain message reaches the model inside a `turn-end-guard` operational envelope, so it begins with the U+2063 `FIRSTMATE_OP:` prefix that the [`ahoy`](../.agents/skills/ahoy/SKILL.md) skill excludes from captain-boundary detection, while the captain's original submission is by definition absent from the transcript.
A recovered instruction therefore establishes no captain boundary at all and `/ahoy` recaps from an older one.
Closing it would change either that skill's boundary rules or this envelope's kind, so it is recorded here rather than fixed alongside the recovery mechanism.

This remains a detection-and-recovery backstop, not a fix for the underlying SDK race, and is currently Pi-only because that is where the race was reproduced and where `agent_settled`/`sessionManager.getEntries()` are available to an extension; Claude, Codex, OpenCode, Grok, and Cursor are unaffected by this specific gap because none of them deliver an autonomous wake through the same in-process `sendUserMessage` primitive.
`tests/fm-turnend-guard.test.sh` covers the captain-input loss case (including a short message a longer later one contains) with its attachments, and its delivered-message, extension-wake, withdrawn-queued-message, resent-after-submission-failure, unrelated-turn-start and manual-resend-after-the-race negative controls, the resend that races the recovery it already sent (suppressed rather than delivered a second time, reported to the captain exactly once, never resubmitted as a lost input of its own, and delivered untouched again once the recovery was answered), the run that opens during the supervision check, overlapping settles, the per-generation budget reset, and reply-recovery cases for the dangling-tool-call and fully-unanswered detection cases (including a tool call beside a text preamble), the healthy no-op case, the idempotent bounded-retry-then-notice sequence and its reset after a healthy settle, the session-start digest and flushed inline-bash exclusions, the captain-abort exclusion against a still-nudged error stop, and the latch interleaving where a supervision-claimed settle must not swallow the next unanswered episode.

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
If a branch offer loses the claim race to main, it rejects its settlement so the watcher retains the actionable close until Pi accepts its main follow-up.
[`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners) owns branch eligibility, mixed-queue dispatch, the pre-drain recheck, and heartbeat's all-or-nothing rule.
A check-kind row is main-owned in every mode, including a heartbeat review, so it is never part of a branch claim and never defers one; main is woken for it on that check's own triggering close.
`fm-wake-drain.sh` never reclassifies a row itself: it filters the queue to the current actor's opaque claim before same-key deduplication, then presents and acknowledges only that actor-local view.
A missing or empty branch snapshot is refused loudly rather than read as "nothing eligible", because reaching the drain without the non-empty handoff promised by the extension is a wiring bug.
Because branch claims contain no check-kind rows, a branch acknowledgement skips check-specific receipt scans.
`tests/fm-wake-queue.test.sh`'s mixed-queue actor and presentation-deadline tests drive the real scripts: branch acknowledgement cannot swallow a main row, a concurrent main turn cannot present or acknowledge an active branch grant, live-holder presentation contention stays bounded and retriable, and acknowledgement locking remains blocking.
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

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
