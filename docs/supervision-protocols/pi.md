Mode: Pi extension persistent background-wake cycle with observable custom-message delivery and direct-exchange compaction continuity.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi`, after approving project trust once per clone); if not, restart with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. Arm supervision once with the `fm_watch_arm_pi` tool.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and owns the single-child cycle after that arm.
5. On every actionable child exit, the extension starts the successor immediately without waiting for a model or tool turn, then sends a visible context-participating `firstmate-watcher-wake` custom follow-up.
6. The wake carries a stable delivery identity.
   Pi's `message_end` custom-message event or the matching `custom_message` session entry proves admission.
   The extension marks each fire-and-forget handoff in flight before calling Pi and does not retry it while asynchronous admission remains possible.
   Pi's `agent_settled` event is the concrete non-admission boundary: if the matching wake was not observed by then, capped exponential retry continues while the durable queue remains undrained.
   A synchronous handoff failure also permits retry; observed admission or queue drainage clears the pending delivery and cancels its retry timer.
7. The follow-up delivery mode preserves Pi's steering priority for direct captain input, and one pending delivery plus one arm child prevents message floods and duplicate watchers.
8. After a watcher wake, drain and handle the queue, but do not call the arm tool again because the extension already owns the successor.
9. If the extension says the watcher is already healthy, do not start another cycle.
10. Session shutdown, process exit, session-lock loss, or away-mode entry stops the extension-owned child and retry state.
    After lock reacquisition or away-mode exit, the same arm tool resumes the cycle.
11. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart Pi with both extensions loaded if needed.
    Non-actionable exits and spawn failures schedule automatic child restarts with capped exponential spacing; failure notifications without a queue requirement stop after three unadmitted attempts.
12. Never use shell `&` for watcher supervision.
    The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running Pi session has not loaded both required extensions.

## Input provenance and compaction continuity

This document owns the Pi-specific boundary between direct captain input, automated supervision prompts, pending input, and rebuilt post-compaction model context.
The watcher and turn-end extensions use Pi's context-participating `sendMessage()` custom-message path with distinct `firstmate-watcher-wake` and `firstmate-turnend-guard` types, `deliverAs: "followUp"`, and `triggerTurn: true`.
The admission checks in the cycle above do not infer success from `sendMessage()` returning because the extension API intentionally returns `void` and reports asynchronous rejection separately.
They never use `sendUserMessage()` for automation, so supervision remains visible to the model without becoming a human-authored `role: "user"` turn.

The watcher extension observes Pi's `input` event and records `interactive` or `rpc` submissions as provisional non-context `firstmate-direct-input-observation` entries before Pi queues or delivers them.
Each provisional record carries the exact text-and-image content from that boundary, including image data and MIME type, so compaction before delivery cannot reduce an attachment to a count.
Only exact user content delivered by `message_end` becomes a fresh admitted and delivered exchange.
The delivery boundary never associates a user message with an observation or an older exchange by content, order, or fallback, so a consumed observation followed by an identical accepted retry remains unambiguous.
Global queue state and later lifecycle events never promote or match a provisional observation because they cannot identify which input Pi accepted.
Unadmitted provisional records never become reply obligations.
Each exact user delivery joins an in-process logical reply cohort awaiting the next completed answer.
A retry `agent_start` retains that cohort until Pi delivers another human message, so a successful retry can close the original exchange without another user `message_end`.
The first human delivery after an `agent_start` replaces a retained cohort, and additional human deliveries before the answer join it, so an answer to a newer request cannot close an older failed request.
It records an exact completed assistant answer only for the active cohort, on `stopReason: "stop"`, when no custom message intervened after delivery, then clears the answered cohort.
These append-only records survive compaction and session resume without changing Pi's queue ordering.
A queued submission remains owned by Pi until exact delivery, so continuity metadata never bypasses the steering or follow-up queue.
Queue disappearance without an exact user delivery remains durable observation evidence but never creates an exchange or reply obligation.

Before each model request, the extension compares Pi's compaction-aware message list with the full active branch.
When compaction omitted the latest completed direct exchange, the hook injects one hidden `firstmate-direct-exchange-continuity` custom message containing the exact JSON user content, the exact JSON assistant answer, and `ANSWERED`.
Every delivered input without a completed answer is included distinctly as `OPEN_REPLY_OBLIGATION`.
The continuity message identifies itself as extension-generated metadata and states that watcher and guard prompts are custom messages rather than captain-authored requests.
It is inserted before the current human user message, preserving that user message as the final prompt and avoiding tool-call or tool-result adjacency changes.
The mechanism does not cancel compaction, enlarge `keepRecentTokens`, alter the cut point, or refuse a turn; malformed or absent continuity state simply leaves Pi's ordinary context unchanged.

### 2026-08-25 incident evidence

The source was the live Pi 0.84.2 JSONL session `2026-08-24T12-45-47-533Z_01a033ce-368d-7c69-9c34-acd78d33130d.jsonl` under the primary's Pi session directory.
The captain's input carried message timestamp `2026-08-25T03:28:00.086Z` and was persisted as entry `e5eafcbb` at `03:28:06.116Z`, a 6.030-second steering delay while the current tool turn finished.
The exact assistant answer was persisted as `f2a84da7` at `03:28:48.884Z`.
An extension watcher input had been generated earlier at `03:27:33.185Z` but was persisted as `85a87db6` at `03:28:48.886Z`, a 75.701-second follow-up delay and two milliseconds after the direct answer.
This ordering proves that the submitted human steering input was delayed but neither omitted nor starved: both its exact user entry and exact assistant answer exist before the older extension follow-up was delivered.
The JSONL contains no additional submitted human entry between that answer and the watcher follow-up; editor text that was never submitted is outside session evidence and is not claimed either way.
Compaction `d4b4f008` followed at `03:29:11.300Z` with `firstKeptEntryId=85a87db6`, so the exact direct exchange remained only inside a lossy summary while the automated follow-up and later supervision turns occupied the live tail.

### 2026-08-25 regression evidence

Deterministic command: `tests/fm-pi-watch-extension.test.sh`.
Observed output included `ok - Pi compaction continuity preserves exact human exchange across automated custom prompts`.
The regression uses Pi 0.84.2's installed `Agent` with a controlled assistant event stream to prove a later human image steer receives its own provider turn before an older automation follow-up, then uses installed `SessionManager` to build the actual compaction-aware context after an exact human question and answer, a custom watcher prompt, an assistant supervision response, and a compaction whose first-kept entry is the watcher custom message.
It then delivers a referring human follow-up and proves the chained context hook adds the exact prior question and answer as `ANSWERED`, adds the follow-up as `OPEN_REPLY_OBLIGATION`, keeps both records custom rather than user-authored, and leaves still-pending steering submissions under Pi's ownership.
A compaction-before-delivery fixture records text plus an image provisionally, cuts at a later custom watcher entry before any user message exists, proves the durable session contract retains exact image data and MIME type without injecting it into context, then delivers the exact input and proves a later compaction restores it as `OPEN_REPLY_OBLIGATION`.
It also proves a consumed steer does not become continuity metadata while unrelated automation is pending or after that automation drains.
A separate compaction fixture cuts an unanswered direct question behind a custom watcher turn and proves the exact question returns as `OPEN_REPLY_OBLIGATION` rather than being inferred from summary prose.
`tests/fm-pi-retry-continuity.test.sh` exercises the installed-Pi proof that an error followed by a retry without another human delivery closes the retained exchange, while a new human delivery on the retry replaces the retained cohort so its answer cannot close the older failed exchange.

### 2026-08-28 persistent-cycle regression evidence

The observed failure sequence was an armed Pi child, an actionable watcher exit with a durable queued wake, no persisted `firstmate-watcher-wake`, no successor child, and a stale beacon until later captain input caused a manual re-arm.
The cycle protocol above owns the recovery contract exercised by the following proofs.

Deterministic command: `tests/fm-pi-watch-extension.test.sh`.
Observed output included `ok - Pi watcher avoids duplicate in-flight admission, retries after settlement, survives two wakes, and stops on ownership changes`.
The fixture reproduces arm, durable queue append, actionable exit, a delayed asynchronous admission that arrives after the former retry timer would have fired without a duplicate handoff, custom-message admission and triggered turn, successor with a fresh beacon before queue drain, a second actionable exit whose first handoff reaches settlement without admission, stable-identity retry and admission, another successor, away-mode stop and resume, lock-loss stop and resume, and session-shutdown cleanup.

Live command: `FM_PI_LIVE_E2E=1 FM_PI_LIVE_AUTH_DIR='/Users/dongkeun/.pi/firstmate-local' tests/fm-pi-primary-live-e2e.test.sh`.
Observed output: `ok - Pi 0.84.2 live E2E persisted two custom wakes, self-rearmed both successors, and cleaned up on exit`.
The isolated smoke used installed Pi, a cloned project, a private tmux socket, isolated Pi and Firstmate homes, copied credential input, the real watcher and arm scripts, and two consecutive durable status wakes.
It proved each actionable exit gained a distinct live successor with a fresh beacon that remained live after model queue handling, each wake persisted as a visible custom message and triggered a model turn that drained the queue, no second arm-tool call occurred, and `/quit` left neither watcher nor arm child alive.

Live command: `FM_PI_COMPACTION_LIVE_E2E=1 FM_PI_LIVE_AUTH_DIR='/Users/dongkeun/.pi/firstmate-local' tests/fm-pi-primary-compaction-live-e2e.test.sh`.
Observed output: `ok - Pi 0.84.2 live compaction rebuilt the exact answered captain exchange across a custom watcher turn (firstKeptType=message)`.
The smoke used a cloned project, private tmux socket, isolated `PI_CODING_AGENT_DIR`, isolated `FM_HOME`, copied read-only credential input, synthetic isolated watcher arm, real Pi `/compact`, and a later model turn.
The isolated session proved the compaction cut after the direct exchange, captured the provider-bound rebuilt context with the exact question, exact answer, `ANSWERED`, and custom-message provenance, and observed the resumed model identify the prior direct question and report that it had been answered.
It did not touch the live primary session, home, session file, lock, wake queue, or watcher.

Verification on 2026-07-09 used Pi 0.80.5, an isolated `PI_CODING_AGENT_DIR`, an isolated `FM_HOME`, and the dedicated tmux socket `fm-pi-q6-lab`.
The command `Use the fm_watch_arm_pi custom tool now. Do not use bash.` rendered `watcher: started Pi extension arm child 1`, then the model returned `DONE` without the prior `result.content.filter(...)` crash.
The extension tool returned Pi's required text `content` plus structured `details` and used `Type.Object({})` for its parameter schema.
The human command `/fm-watch-arm-pi` notified through `ctx.ui.notify(...)` and returned no value.
The clean-exit probe ran `/quit`, printed `PI_EXIT=0`, and confirmed that both the attached arm process and watcher child were gone.
That cleanup is owned by a one-shot process `exit` listener because Pi 0.80.5 did not reliably emit `session_shutdown` for `/quit`; the listener is removed when `session_shutdown` does run.
Command run for the complete interactive regression: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed output: `ok - Pi 0.80.5 live E2E rendered the tool, guarded once, woke, re-armed, and cleaned up on exit`.
Command run for the installed-type contract: `tests/fm-pi-primary-types.test.sh`.
Observed output: `ok - Pi primary extensions pass strict no-emit typecheck against Pi 0.80.5`.
