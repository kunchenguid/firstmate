# Inference-gateway keep-alive

Firstmate agents run against an inference gateway that pools accounts.
When no pooled account is routable the gateway answers 503, the harness ends the turn with an API error, and the agent is left idle at its prompt with its work unfinished.
Nothing in the harness resumes it.
Before this keep-alive existed, that agent sat there until a human noticed and told it to carry on, and the supervisor read the same idle pane as a possible wedge.

This is the authoritative contract for how firstmate keeps agents working across those stalls.
`bin/fm-gateway-retry-lib.sh` is the single owner of the classifier, the durable stall record, and both bounds; its header owns the exact record format and tunables.

## Why the agent cannot fix this itself

Claude Code reports an API-error turn end through `StopFailure`, not `Stop`, and it executes `StopFailure` hooks outside its REPL loop and discards their result.
A `StopFailure` hook therefore has no way to block the stop or force a continuation, unlike the `Stop` hooks [`turnend-guard.md`](turnend-guard.md) describes.
The keep-alive is built on that fact rather than around it: the hook cannot resume the turn, but it can RECORD it, so an actor outside the session reads that record, confirms which error ended the turn, and delivers the nudge.
[`verification/gateway-keepalive.md`](verification/gateway-keepalive.md) records the live evidence.

## What counts as a transient gateway stall

The signal is the agent's own **turn-lifecycle record**, not its screen.
Two conditions are required, and a stall is declared only when both hold:

1. The task's busy record says its last turn ended on an API error - `event=stop-failure`.
   Claude Code closes such a turn through `StopFailure` and never `Stop`; `bin/fm-spawn.sh` wires that hook to `fm-busy-event.sh … --event stop-failure`, and `bin/fm-busy-lib.sh` owns the record it writes.
2. The pane tail shows one of the transient gateway errors.
   The match reads the last ten non-blank lines - a bounded footer window like the one the watcher's busy match reads, sized for where a turn-ending error renders - and matches only the harness's rendered `API Error: <5xx>` shape, never a bare word such as `overloaded`.

A turn that ended normally records `event=stop` and never enters the ladder, whatever is on its screen.
That is also the exit: a crew that takes the continue and finishes its turn records `stop`, so its record is dropped on the next idle poll without waiting for the old error to scroll off.

The second condition is not the detector on its own, and it is not asked to be.
The question this classifier asks is about a TURN, and a screen holds no turns - it holds rows.
This repository's own docs, tests and classifier carry the rendered error text verbatim, so an agent that merely read them ends its turn with the shape on screen, and four successive attempts to tell that agent from a stalled one by POSITION each failed in their own direction: an unanchored match caught prose, a physical-row anchor went blind on the wrapped error, a gutter-glyph join merged separate rendered lines, and a pane-width join missed the error whenever the harness word-wrapped, whenever the composer border sat one column off the wrap column, or whenever the capture still held wider rows from before a resize.
The turn end is not inferred from the screen at all: the crew records it itself.
The pane condition remains because the event says only THAT an API error ended the turn, never WHICH one - and some of those must never be retried (see the deny list below).

### Scope: the claude harness only

`event=stop-failure` is written in exactly one place, the `claude*` arm of `bin/fm-spawn.sh`'s busy wiring.
No other harness emits it, so this keep-alive covers claude-harness crewmates and scouts only.
A task whose record carries no event, an event the classifier does not name, or no readable record at all is deliberately **not** in the ladder: it is left to ordinary triage rather than re-rung on the strength of pane text alone.
That is the intended limit - the captain asked for claude workers, and the text patterns are Claude Code's own rendered shape - and it is a written-out refusal in `fm_gateway_turn_ended_on_api_error`, not a silent fall-through.

Re-ringing a healthy crew is not a harmless nudge - it spends the whole budget and stamps a false `paused [key=gateway-503]` on that crew's status log, which then routes a genuinely wedged pane onto the long declared-wait cadence instead of the wedge timer.

A deny list runs first, over the whole capture, and beats the transient match.
It exists because the non-retryable failures are the expensive mistakes: a prompt that is too long, an expired credential, or a spent usage limit cannot be improved by asking the agent to carry on, and one real failure this fleet produces (`Prompt is too long · automatic compaction failed: API Error: 503 ...`) carries a 503 inside a failure that is not the gateway's.
A gateway that is simply unreachable is deliberately outside the transient class too: that is the genuine outage, and it should surface rather than be papered over.

## How an agent is kept alive

1. **Detect.** On a poll that finds the agent idle, the watcher reads its turn-lifecycle record and the pane it already captured, and opens a durable stall record the first time both conditions hold.
   An agent whose last turn ended normally is a recovered agent, and its record is dropped so a later stall starts fresh.
   That reading only happens on a poll that finds the agent idle, so a record is also dropped once its pane has read busy continuously for `FM_GATEWAY_BUSY_CLEAR_SECS`: an agent that took the continue and then worked for that long has recovered, and must not carry a half-spent ladder and a stale horizon anchor into the next, unrelated stall.
   Busy alone is not the signal - the continue this ladder sends makes the pane busy until the turn ends, and a turn that dies on the next error is busy for the harness's whole internal retry, about four minutes on the version verified in [`verification/gateway-keepalive.md`](verification/gateway-keepalive.md), so ending the record there would wipe the attempt count mid-ladder and no genuine outage could ever be declared.
   The threshold is therefore set well past that verified retry, so the ladder's own retry can never reach it, and it is held in seconds and converted to whatever cadence the watcher actually polls at - a poll-denominated bound would shrink back under the retry on a home that polls faster.
2. **Re-ring.** The watcher (`gateway_stall_check` in `bin/fm-watch.sh`) sends the agent one continue instruction, delivered through the steering inbox as a fire-and-forget record: durable and rung with the constant doorbell, but excluded from the inbox's own re-ring ladder, because during a real outage the crew cannot acknowledge anything and an ordinary steer left unhandled would be escalated into stuck-crewmate recovery, the wedge treatment this keep-alive exists to avoid.
   An ordinary steer that was already waiting in the inbox when the gateway failed is protected the same way: the watcher classifies a poll for a stall before it runs the inbox ladder, and that ladder stands down for the task - no doorbell, no attempt counted - for as long as the stall record is open, resuming with its own bookkeeping intact once the record drops.
   The watcher is the only actor that re-rings, and it reads crewmates and scouts: a session firstmate runs in itself has no watcher reading its pane, so a stalled primary is not kept alive by this or anything else.
3. **Bound.** Every re-ring is charged against a record bounded twice: an attempt count and a wall-clock horizon.
   Either bound alone is insufficient, because one stops a fast loop and the other stops a slow one spread across a real outage.
   The gateway ladder owns every re-ring and both bounds; nothing else re-rings the record.
4. **Declare.** When either bound is spent, the stall stops being re-rung and is declared once as an external wait (`paused [key=gateway-503]: ...`), so the pane takes the long declared-wait cadence instead of a wedge escalation.
   This is the one declared-wait shape that needs no `until HH:MMZ` wake time: the OPEN DECISIONS fold exempts exactly this key, so the line stays a declared external wait instead of folding as a blocker, and every other time-less `paused:` note still folds as blocked.
   That declaration is closed (`resolved [key=gateway-503]: ...`) when the record that declared it is dropped, which happens only once the agent is working again - its next turn ended on something other than an API error, or it has been busy for `FM_GATEWAY_BUSY_CLEAR_SECS` - so a crew that carries on is not left reported as still waiting on the gateway.
   Neither of those transitions re-reads the pane, so the close deliberately claims only that the agent is working again and never that the error has left the screen.

A successful re-ring is silent.
An agent that carries on is not news, and the whole point is that the captain stops being the retry mechanism.

## Watcher backstop

The watcher's check runs on every idle recorded window and costs one read of the task's busy record plus one classification of a pane it already captured.
It is deliberately not gated on the wedge timer's "nothing changed for two polls" rule: the evidence here is a recorded API-error turn end, not an absence of change, so an agent is re-rung promptly rather than after the stale bookkeeping has accumulated.
Because it lives in the watcher, every agent already running gets the behaviour without being relaunched.

Secondmate endpoints are outside it.
An idle secondmate pane is healthy by design and is admitted to the stale path only to serve a declared wait, so it is never classified for a stall; `gateway_stall_check` refuses a secondmate outright rather than piggybacking on that admission.
A secondmate's own home runs its own watcher for its crews, and that is where they are kept alive.

## Tuning

`bin/fm-gateway-retry-lib.sh`'s header owns the full list.
The ones worth knowing: `FM_GATEWAY_RETRY_MAX` (default 8 attempts), `FM_GATEWAY_RETRY_HORIZON` (default 2700 seconds), `FM_GATEWAY_RETRY_BACKOFF` (default `30 60 120 300`, last step repeating), and `FM_GATEWAY_BUSY_CLEAR_SECS` (default 600 seconds of continuous busy end a record, at any poll interval).

## Regression coverage

`tests/fm-gateway-keepalive.test.sh` covers the event gate against records written by its real writer - a recorded API-error turn end plus the matching text entering the ladder, a normal turn end quoting the same text staying out of it, a recorded API-error turn end with no matching text staying out, and an absent, unreadable or unknown-event record staying out, which pins the claude-harness-only scope; the text classifier against the exact rendered strings this fleet's transcripts contain, bare and above the idle composer and footer; the deny list beating a transient code inside a permanent failure and matching anywhere while the transient match stays bounded; a recovered agent whose scrollback still holds the old error and repository text naming the errors both staying out of the ladder; each bound independently; and the anchor stability that keeps a frequently polled stall from being absorbed forever.
`tests/fm-watch-triage.test.sh` drives a real watcher over a stalled pane and asserts the continue instruction lands in the steering inbox as a fire-and-forget record without a wake, that a spent budget declares the external wait and stops re-ringing, that an ordinary steer already waiting when the stall began is neither rung nor counted by the inbox ladder while the stall record is open - through the re-ring and through the declared wait after the budget is spent - and is rung once the record drops, that a window whose pane cannot be captured is served on its live classification - a gone endpoint still has its unread steer escalated whatever its stale busy record says, while a live busy crew whose capture blipped is waited on - that the harness's own internal 503 retry keeps the record and still reaches a declared outage while a busy stretch reaching the threshold drops it so a later transient error starts a fresh ladder, and that a paused secondmate whose pane shows the error is re-surfaced as a paused mate and never re-rung.
`tests/fm-busy-adapter-wiring.test.sh` pins that the spawn-written Claude settings register the busy writer alone on `StopFailure`.
`tests/fm-teardown.test.sh` pins that a retired task leaves no stall record behind to poison the next task reusing its id.
