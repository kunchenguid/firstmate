# Pi turn-settle reply recovery verification

Audience: maintainer verification.

This record supports the turn-settle input and reply recovery guarantee in [`watcher-continuity.md`](../watcher-continuity.md#turn-settle-input-and-reply-recovery).
Mechanism, contract, and active limits remain in that linked guide.
Task-specific chronology and the captain decision that chose detection-and-recovery over a submission-serializing mutex remain in private task evidence.

## Root-cause reproduction

Reproduced 2026-09-01 against the installed `@earendil-works/pi-coding-agent` v0.84.3 (Node v22.23.2) with `docs/verification/pi-agent-session-toctou-repro.mjs`, tracked alongside this record.
The script drives the real, unmodified `AgentSession.prototype.prompt` from the installed package against a minimal stub `this` exposing only the fields and methods that method touches, so the method under test is production code, not a reimplementation.

Command:

```sh
SDK_PATH=/home/vsole/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/agent-session.js \
  node docs/verification/pi-agent-session-toctou-repro.mjs
```

Observed output:

```
2134.05ms watcher wake: prompt('FIRSTMATE WATCHER WAKE...') START
2134.44ms captain call: prompt('bitte den Stand zusammenfassen') START
2134.71ms emitBeforeAgentStart (simulating a real extension awaiting a child process)
2134.90ms emitBeforeAgentStart (simulating a real extension awaiting a child process)
2155.86ms _runAgentPrompt ENTER (concurrent=1) messages=[{"role":"user","content":[{"type":"text","text":"FIRSTMATE
2156.02ms _runAgentPrompt ENTER (concurrent=2) messages=[{"role":"user","content":[{"type":"text","text":"bitte den
2156.07ms _runAgentPrompt EXIT -> _emitAgentSettled()
2195.55ms _runAgentPrompt EXIT -> _emitAgentSettled()

maxConcurrentRunAgentPromptCalls = 2
extension event order: before_agent_start -> before_agent_start -> agent_settled(runsStillLive=1) -> agent_settled(runsStillLive=0)
settlesWhileAnotherRunWasLive = 1

captain input seen by the "input" event: true
captain text present in the transcript: false
transcript tail looks healthy: true
REPRODUCED: two concurrent prompt() calls both reached _runAgentPrompt() concurrently.
REPRODUCED: a spurious agent_settled fired while another logical run was still live.
REPRODUCED: the captain's message was lost entirely while the transcript tail stayed healthy.
exit=1
```

`exit=1` is the script's own "reproduced" signal (documented at the top of the script), not a test failure.
Two `prompt()` calls - one modeling a captain's interactive message, one modeling `fm-primary-pi-watch.ts`'s `sendWake` delivering a watcher wake via `pi.sendUserMessage(..., {deliverAs: "followUp"})` - both observed `isStreaming` as false and both reached `_runAgentPrompt` concurrently, each setting `_isAgentRunActive = true` and invoking the underlying agent run against the same session state.
The losing call does not merely run concurrently: its inner `agent.prompt()` rejects at once with pi-agent-core's "Agent is already processing a prompt.", yet `_runAgentPrompt`'s `finally` block still clears `_isAgentRunActive` and emits `agent_settled` while the winning turn is mid-flight.
The recorded extension event order is therefore `before_agent_start -> before_agent_start -> agent_settled(runsStillLive=1) -> agent_settled(runsStillLive=0)`: a settle is not proof the session is idle, and `_isAgentRunActive`/`isIdle()` cannot disambiguate because the race corrupts that same flag.
`.pi/extensions/fm-primary-turnend-guard.ts` therefore counts logical runs in flight from `before_agent_start` and evaluates only the settle that drains that count.
The same run drives the captain's own call into the losing position, which is the second, invisible outcome: `capturedCaptainInput` is true because `prompt()` emits its `input` event before the `isStreaming` check, yet `captainTextInTranscript` is false and the transcript tail is a healthy `stop` assistant reply.
That is the documented BEFORE state for captain-input-loss recovery - the captain's message is simply gone, and no tail inspection can detect it.
The AFTER state is asserted in `tests/fm-turnend-guard.test.sh`, which drives the real `agent_settled` handler through exactly this event order and transcript: exactly one resubmission fires, it carries the lost text, it is never repeated on later settles, and an ordinary delivered captain message produces none.
The `emitBeforeAgentStart` delay in the stub (20ms) models a real, not contrived, async gap: `.pi/extensions/fm-primary-turnend-guard.ts`'s own `before_agent_start` handler spawns and awaits `bin/fm-sessionstart-run.sh` on session-start-classified generations, and any `before_agent_start` extension handler doing real async work opens the same window.

## Considered and rejected: prevention at the extension layer

An earlier iteration of this fix (`fm/firstmate-captain-input-haenger`, since reverted) gated `fm-primary-pi-watch.ts`'s `sendWake` on a `before_agent_start`/`agent_settled`-tracked busy flag, deferring delivery while a turn was known to be in flight.
An automated review caught that this does not close the reproduced race: `before_agent_start` fires only after `prompt()` has already passed its `isStreaming` check (agent-session.js `prompt()`, the branch at `if (this.isStreaming) { ... return; }` runs before any extension hook in that call), so a call already past that check sees the SAME state the busy-tracking gate would only start protecting later.
The two calls in the reproduction above never see `owner.busy` as true until after both have already committed to `_runAgentPrompt` - the gate protects an already-safe mid-turn window (where Pi's own native `followUp`/`steer` queueing already works correctly) while leaving the actual idle-vs-idle race it was built for fully open.
Closing the race with certainty would require serializing every `prompt()`-triggering call - interactive and extension-sourced alike - through Pi's earliest hook (`input`, which fires before the `isStreaming` check itself) with a real mutex held until each call's outcome commits.
That was rejected as disproportionate new risk (a novel synchronization primitive with its own deadlock/regression surface) for a rare race, in favor of the detection-and-recovery mechanism this record supports.

## Regression coverage

`tests/fm-turnend-guard.test.sh`'s `test_pi_input_recovery_*` and `test_pi_reply_recovery_*` tests exercise `.pi/extensions/fm-primary-turnend-guard.ts`'s `input`, `before_agent_start`, `session_start` and `agent_settled` handlers directly against a mocked `pi`/`ctx`, covering the captain-input loss case (including a short message that a longer later one contains) and its attachments, with its delivered-message, extension-wake, withdrawn-queued-message, resent-after-submission-failure, unrelated-turn-start and manual-resend-after-the-race negative controls, a run that opens while the supervision guard's child process is still running, two settles overlapping across that same await, the per-generation attempt-budget reset, the dangling-tool-call and fully-unanswered detection cases (including the common shape where the same assistant message carries a text preamble beside the unresolved call), the healthy no-op case, the idempotent bounded-retry-then-notice sequence and its reset after a healthy settle, the session-start digest and flushed inline-bash exclusions, the captain-abort exclusion against a still-nudged error stop, the latch interleaving where a settle claimed by the supervision guard must not swallow the next unanswered episode, and the spurious mid-turn settle above - replayed as the exact recorded event order - which must be left entirely unevaluated whether the still-running winner ends up hanging or answering.
Run: `bash tests/fm-turnend-guard.test.sh` (or `no-mistakes`-invoked `bin/fm-test-run.sh tests/fm-turnend-guard.test.sh`).
