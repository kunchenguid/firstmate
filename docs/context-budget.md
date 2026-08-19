# Primary context-budget guardrail

This is the authoritative current contract for the context ceiling referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-context-budget.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the turn-end supervision guard in [`turnend-guard.md`](turnend-guard.md) and the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).

This guard is a sibling of the turn-end supervision guard, not part of it.
Both run on the same `Stop` event and both scope through the same shared predicate, but they own different contracts: the supervision guard owns "no turn ends blind", and this one owns "no session runs past the context ceiling".
Do not infer one guard's thresholds, loop safety, or degradation behavior from the other.

## What this is for

Firstmate sessions run toward roughly 800,000 tokens before Claude's own auto-compaction fires.
This guard fires far earlier, at an absolute 180,000 tokens, and reports it so a handover happens before the balloon forms.

That makes it a deliberate cost and reasoning-quality policy, not overflow prevention.
Nothing crashes at 180,000 tokens on a 1M-context session.
What degrades is answer quality and token spend, and both degrade long before the harness would intervene on its own.

The ceiling is an absolute token count and never a fraction of a detected window.
The window is not inferable from the transcript: a 1M session records `message.model` as `claude-opus-5` with the `[1m]` marker stripped, so a proportional ceiling has nothing trustworthy to be proportional to.

## Current invariant

At every primary turn end, the guard measures the live session's context.
Below the advisory point it is completely silent.
Between the advisory point and the ceiling it prints one non-blocking notice per episode.
At or above the ceiling it prints one visible ceiling notice per episode pointing at the handover, and by default allows the turn end.
Entering a stage also appends one line to a durable trip record, one line per crossing rather than one per turn end.

**The shipped default warns and does not block.**
Enforcement is fully implemented and switched on with `FM_CONTEXT_BUDGET_ENFORCE=1`; with enforcement off, nothing in this guard can ever return a blocking exit status.

That default is deliberate, and is not an unfinished enforcement path.
A 180,000 ceiling on a million-token session will trip repeatedly in a normal working day, and every trip costs a handover.
The real frequency of those crossings has to be observed before the mechanism is allowed to interrupt anyone, so the first release stays out of the way and only reports.

**The default reports to the captain, not to the session.**
Reaching the session at all requires enabling enforcement.
Every default-path notice is a `systemMessage`, which is a user-facing channel: only the blocking exit-2 path delivers text to the model, and a session asked in the next turn about a `systemMessage` it had visibly received answered that it had not seen it.
So under the default the guard tells the captain that a crossing happened; nothing instructs the session, and nothing acts.

Whether that notice is even rendered is outside this repo's control.
A controlled experiment confirmed 30 emissions with zero renders, and the earlier renders that motivated the channel choice remain unexplained; [`verification/context-budget.md`](verification/context-budget.md) records both.
The durable trip record below, not the notice, is the reliable way to observe how often the ceiling is crossed.

## Measurement

No hook payload on any harness carries a token, usage, or context field, so the number comes from the transcript.

`transcript_path` is read from the hook payload and never derived from `$HOME`.
A non-default Claude config directory puts the transcript somewhere `$HOME` cannot predict; [`verification/context-budget.md`](verification/context-budget.md) records a live path under `~/.claude-work` that proves this.

The context total is the sum of `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, and `output_tokens` on the last non-sidechain `type=="assistant"` entry.
That formula reproduces Claude Code's own accounting exactly rather than approximating it.

Three correctness rules the measurement implements:

- **Last, never max and never a sum.** Compaction resets the running total.
  A `max` implementation would latch the pre-compaction peak and disable the guard permanently after the first compaction, and a sum would report a multiple of the real total and fire the guard far too early.
- **Exclude sidechains.** `isSidechain == true` marks subagent turns, which must never inflate the primary's measurement.
  The exclusion is applied to the whole pass rather than to the token total alone, so it also covers the compaction tally below: a subagent's compaction is no evidence that the primary's context reset.
- **Ignore zero-total entries.** Claude Code writes synthetic assistant entries - main chain, `model` of `<synthetic>`, all four usage fields `0` - whenever a turn ends abnormally, which is exactly when this hook fires.
  One is the last assistant entry at that moment, so counting it would read a long session as empty and that false zero would then look like proof the context had reset.
  The reader takes the last *positive* total instead.

Taking the last entry also handles a multi-block assistant turn, with no separate dedupe step.
Every JSONL line of one such turn carries that turn's own cumulative usage rather than a slice of it, so the last line already is the turn's total.
There is deliberately no `requestId` grouping in the reader: an earlier draft had one, and it was provably equivalent to taking the last entry.

The whole measurement is one streaming pass that filters and projects as it reads and keeps only the last matching total.
Nothing is slurped into memory, so its **memory** is constant in transcript size rather than proportional to it.
Its **time** is still linear, roughly 0.7 s per 80 MB of transcript on the measured host, and that cost is paid at every primary turn end including far below the advisory.

Malformed transcript lines are dropped rather than aborting the pass, so a half-written final line degrades to the last line that parsed.
A line that parses to a valid JSON scalar or array rather than an object is skipped by an explicit type check.
That check is not abort protection, and the earlier claim that it was has been corrected: with `jq -R` every line is its own input, so an error on one line is reported and the next line still runs.
What the check buys is that such a line is skipped deliberately rather than by way of a suppressed per-line error, which keeps the pass's diagnostics meaningful.
A measurement that comes back absent, non-numeric, or zero leaves the turn completely inert: it is a missing number, not evidence about the session's size.

The same pass also counts compaction boundaries, which are `type == "system"` entries with `subtype == "compact_boundary"`.
They are not part of the token measurement; they are the second proof of a genuine reset described under durable records below.
A boundary marked `isSidechain` is excluded from that count like any other sidechain entry, because a boundary now clears a record and a subagent's compaction would otherwise re-arm a spent stand-down.

## Thresholds

The ceiling is the policy point and the only policy number, whether or not enforcement is switched on.
The advisory point is derived as `ceiling - headroom`, so there is never a second threshold to keep in sync.

| Stage | Default | Behavior |
| --- | --- | --- |
| Advisory | 150,000 (`ceiling - headroom`) | One visible non-blocking notice per episode. Prefer cheap actions, avoid large reads. |
| Ceiling, enforcement off (default) | 180,000 | One visible notice per episode naming the valve. The turn end is allowed. |
| Ceiling, enforcement on | 180,000 | Block the turn end and require the valve, bounded, then stand down for the session. |

`FM_CONTEXT_BUDGET_ENFORCE=1` switches enforcement on; any other value, including unset, leaves the shipped warning-only default in place so a typo cannot start blocking sessions.
`FM_CONTEXT_BUDGET_CEILING` overrides the ceiling and defaults to 180000.
`FM_CONTEXT_BUDGET_HEADROOM` overrides the headroom and defaults to 30000, about two worst-case turns on top of the valve's own cost.
`FM_CONTEXT_BUDGET_BLOCK_BUDGET` overrides the consecutive-block bound and defaults to 3, well below Claude Code's own consecutive-block override cap recorded in [`verification/context-budget.md`](verification/context-budget.md).

For `FM_CONTEXT_BUDGET_CEILING` and `FM_CONTEXT_BUDGET_BLOCK_BUDGET`, a non-numeric or zero value falls back to the default rather than disabling the guard.
`FM_CONTEXT_BUDGET_HEADROOM` differs on purpose: only a non-numeric value falls back, and a zero is honoured.
`FM_CONTEXT_BUDGET_HEADROOM=0` collapses the advisory point onto the ceiling, which simply removes the advisory stage and leaves the ceiling stage exactly as it was.

Each notice prints once per episode and re-arms on either of the two genuine-reset proofs under durable records below: a positive measurement back below the advisory point, or a compaction boundary newer than the one the notice record was written with.
Printing once per episode is the same shape `bin/fm-guard.sh` uses.
The advisory notice and the warning-only ceiling notice are separate stages, so crossing from one into the other still produces exactly one new notice.

The notice record carries several independent keys, not one: the threshold stage, whether the count-not-recorded degrade under durable records below has been reported, and whether an unparseable record has been traced.
They are independent flags rather than a ranking, because those are different messages and a single key meant whichever fired first silenced the others for the whole episode.

One known case is deliberately left unfixed: a session oscillating across the ceiling notices on every turn end, because the recorded stage alternates and each crossing back looks new.
Replayed twice over real transcripts, across 41,244 and then 41,353 measured turns, the condition occurred zero times, since sessions that reach the ceiling climb past it rather than hover.
The measurement is also effectively monotonic inside an episode by arithmetic, and the obvious fixes would make the independent-key case above strictly worse.
`bin/fm-context-budget.sh` records the reasoning and the numbers where the next reader will be, and the test suite pins the current behavior so it is not "fixed while someone is there".

## Where the notices appear

Claude Code discards a successful `Stop` hook's stderr.
The hook's output is recorded as a `hook_success` attachment whose renderer returns nothing, and hook output reaches model context only for the `SessionStart` family of events; [`verification/context-budget.md`](verification/context-budget.md) records both readings and the interactive capture that confirms them.

So the channel is chosen by what the guard is doing, not by convenience:

| Path | Exit | Channel |
| --- | --- | --- |
| Advisory notice | 0 | `{"systemMessage": ...}` on stdout |
| Warning-only ceiling notice | 0 | `{"systemMessage": ...}` on stdout |
| Sticky stand-down notice | 0 | `{"systemMessage": ...}` on stdout |
| Blocking ceiling banner | 2 | stderr, which exit 2 delivers to the model |

Under the shipped warning-only default every visible thing this guard does is a `systemMessage`, so that channel is the whole rendered behavior of the feature rather than a detail.
`tests/fm-context-budget.test.sh` asserts the two streams separately and never merges them, because a merged capture cannot tell a rendered notice from a discarded one.

Two limits of that channel are worth stating plainly, because together they decide what the default release actually delivers:

- `systemMessage` is described by the harness's own hook-response schema as a warning shown to the *user*.
  It is not fed to the model, and a live session asked about one it had visibly received answered that it had not seen it.
  So the default reports to the captain and instructs nobody; only the blocking exit-2 path reaches the session.
- Rendering is not guaranteed.
  A controlled experiment over eight trials, varying the number of emitting `Stop` hooks and single-line against multi-line bodies, confirmed 30 emissions and zero renders, while the same shape had rendered twice in that project earlier.
  That earlier behavior is unexplained and is recorded as an unproven property, not resolved.

## The trip record

Because rendering cannot be relied on, and because observing how often the ceiling is actually crossed is the whole point of shipping warning-only first, entering a stage also appends one line to `state/.context-budget-trips`:

```
2026-07-29T09:14:02Z stage=ceiling total=204118 ceiling=180000 advisory=150000 enforce=0 session=<session_id>
```

That is enough to answer how often the guardrail fires and at what size, without depending on a display behavior this repo does not control.

One line per crossing, not per turn end.
A crossing means entering a threshold stage the session was not already in, so a long stretch above the advisory at a steady measurement records one line rather than one per turn.
That is the difference between how often the guard fires and how long a session lingered: measured before this was corrected, 12 turn ends at a steady 160,000 wrote 12 lines.
The line is written exactly where the stage is recorded, so the enforcing path records its crossing once too even though it prints its banner on every blocked turn.
A genuine re-crossing after dropping back below the advisory point is a second crossing and adds one more line.
A session below the advisory writes nothing at all.

A failure to parse the block record is recorded here as well, under `stage=record-unparseable`.
That is the one trace a corrupt record leaves, and it is why treating it as no record is not a silent decision.
It is written once per episode, like a notice: a record that is corrupt and also cannot be rewritten is re-read at every turn end, and a line each time would crowd the crossing history out of the bounded file.

A block count that could not be written is recorded the same way, under `stage=ceiling-unrecorded`, and also once per episode.
That case loses the bound on blocking, so the same argument applies: reporting it only through a notice would leave the guard's own malfunction to a channel that may never render.

A stand-down flag that could not be written is recorded under `stage=standdown-unrecorded`, once per episode.
The block budget is exhausted either way, so the turn is never blocked on it, but claiming the guard "now stands down for the rest of the session" is false the moment the flag does not land, and every later turn end would repeat that false claim with nothing to show for it.
The session-facing message says the stand-down could not be persisted and may recur instead.

A notice write that could not be written is recorded under `stage=notice-unwritable`, once per episode, closing the narrower gap below.

The record is write-only by contract, and that contract is what keeps it outside the loss-path class the durable records below belong to:

- Nothing ever reads a decision out of it.
  The only thing read back is its own size, to keep it bounded.
- Deleting, truncating, or corrupting it mid-session changes no behavior whatsoever, which `tests/fm-context-budget.test.sh` pins by replaying one identical session three ways and comparing every exit status and both streams.
- It is bounded at roughly 128 KiB and trimmed back to its most recent 500 entries, so it cannot grow without limit.
- It spans sessions rather than being keyed to one, and it is deliberately excluded from the 30-day prune that reaches the per-session records.

## Durable records

Two records live under `state/`, both named per session: `.context-budget-blocks-<session_id>` and `.context-budget-notice-<session_id>`, with a third fallback file, `.context-budget-notice-degraded-<session_id>`, used only when the notice record itself cannot be written.

`session_id` is the identity of the context accumulation itself, since the transcript file is literally `<session_id>.jsonl`, so a record keyed to it disappears exactly when the context genuinely resets.
Naming the files per session also means two primary sessions in one home - the case the home session lock reports rather than prevents - cannot alias onto one record and wipe each other's stand-down.
A payload with a missing, empty, or non-filename-token `session_id` makes the turn inert rather than merging distinct sessions under a placeholder identity.

Every rule about these records biases toward keeping them.
Losing a stand-down means repeated forced handoffs that grow the context this guard exists to cap; keeping a stale one costs at most one missed warning in one session.
Concretely:

- Exactly two things clear them, and both are evidence of a genuine reset: a positive measurement below the advisory point, and a compaction boundary newer than the one the record itself was written with.
  An absent, non-numeric, or zero measurement never does.
- The compaction clause exists because compaction does not change `session_id`.
  Without it a session-keyed record would stay stood down across a real reset whose post-compaction total is still above the advisory.
  A record whose own boundary count is missing or unreadable is kept, not cleared, and a boundary already accounted for never clears the record twice.
- An existing block record whose count cannot be parsed is read as **no record**, leaving the guard active, and the parse failure is recorded in the trip record above.
  The retention bias protects a stand-down the session was actually told about; an unparseable record is evidence of nothing, and reading it as a spent stand-down would let a corrupt file impersonate that dismissal and silence the guard for the whole session.
  The asymmetry settles it: this guard only ever warns, so a spurious warning costs one printed line while a suppressed one costs a session blown past the ceiling with nothing to explain why.
  Leaving the guard armed does not cost the block bound, which matters because unbounded blocking is the one thing this guard may never do: a writable record is rewritten on the first blocked turn and counts normally from there, and an unwritable one degrades to the visible warning instead of blocking.
- The stand-down is recorded as a flag rather than a clamped count, so raising `FM_CONTEXT_BUDGET_BLOCK_BUDGET` mid-session cannot re-arm a budget that was already spent.
- The state directory is canonicalized once per run, so a symlinked or relative path cannot split one session's records across two locations.
- A block count that cannot be written is not swallowed.
  Blocking on a count that does not survive the turn could not be bounded, so that turn degrades to the visible warning instead.
  That warning carries its own notice key, so a ceiling notice already shown this episode cannot silence the guard's report that it is malfunctioning.
  It still prints once per episode rather than at every turn end, because a repeated report of a condition that is not clearing is noise.
  When the whole state directory is unwritable nothing can be deduped, so it repeats; repeating a visible warning is the acceptable end of that trade, and going silent about a broken safety mechanism is not.
- Records are pruned only when older than 30 days, and a stood-down session refreshes its own record on every turn end, so pruning can never reach a session that is still running.
  The prune glob covers every `.context-budget-notice-*` prefixed file, so the fallback marker below prunes on the same schedule without a separate rule.
- The block-budget-exhausted stand-down flag is the same kind of write as the block count it neighbors: if the flag itself cannot be written, that failure is recorded under `stage=standdown-unrecorded` above rather than let the guard claim a durability it did not achieve.
- The notice record's own write can fail on a narrower shape than a wholly unwritable state directory: the directory, the trip record, and the block record can all stay writable while `.context-budget-notice-<session_id>` specifically does not.
  Without a fix that failure would silently drop the per-episode dedup key, and `stage_enter` would call `trip_record` on every single turn end above a threshold instead of once per crossing - reopening the per-turn-end trip-file inflation the crossing-not-turn-ends fix above closed.
  The fix keeps the trip record write-only: nothing here reads a decision back out of it.
  Instead, a dedicated fallback marker, `.context-budget-notice-degraded-<session_id>`, records the same dedup fields independently of the primary notice file.
  Reads check the primary file first and fall back to the marker only for a field the primary file does not have, so a value once recorded to the fallback continues to dedupe normally even while the primary file stays unwritable.
  The fallback write itself is traced once per episode under `stage=notice-unwritable`, so the malfunction leaves its own bounded trace rather than resting on a notice that may never render.

## This guard does not own the valve

The handover mechanism owns it, through the `handover` skill and `bin/fm-handover.sh`; AGENTS.md states the precedence.
This guard reports a crossing earlier than the 250,000 handover threshold and stops there.
It never stalls the session: report it, keep working, and tell the captain at the next natural reply.

Running `/stow` first is still worth doing, because it writes durable knowledge, decisions, and unfinished work to disk and `.agents/skills/stow/` tracks it on every machine.
That is a step inside a handover, not a second valve standing beside it.

The guard instructs and nothing more.
It never types into a pane, never injects `/compact`, `/clear`, or any other command, and never spawns a replacement agent.
Compacting in place and spawning a replacement are not offered as alternatives.

## Clearing is not what closes it

A session cannot clear its own context.
Clearing is a local user action with no tool surface, and a live session confirmed it directly, replying "I can't clear my own context; that's yours to do" ([`verification/context-budget.md`](verification/context-budget.md)).

That measurement still holds and no longer constrains anything here, because a handover does not clear a context.
It releases the helm, and a successor session picks the work up from disk.
So nothing in this guard waits on a captain keystroke.

## Away mode

While away mode is active nobody is there to read the report, so under the shipped default the crossing goes to the trip record and the session keeps running.
With enforcement switched on it blocks up to `FM_CONTEXT_BUDGET_BLOCK_BUDGET` times and then stands down for the rest of that session.

That is accepted, deliberate behavior rather than an open defect.
Nothing in firstmate may type a command into a live session, and a guard that nagged an unattended session every turn would grow the very context it exists to cap while doing nothing useful.
The cost is worth stating plainly: this guard is close to inert while away, which is exactly when sessions run longest and a ballooning context is most expensive.

## Never wedge a session

Every measurement failure is a silent exit 0: absent `jq` or `awk`, missing or unreadable `transcript_path`, a missing, empty, unreadable, or corrupt transcript, a transcript with no assistant usage, a measurement that comes back zero, a payload with no usable `session_id`, and empty or malformed stdin.
A bare or unsupported-harness invocation is also inert rather than a blocking usage error.

Under the shipped default the guard never blocks at all, so the ceiling can never contribute to a wedged session.

With enforcement on, blocking is bounded and the stand-down is sticky.
After `FM_CONTEXT_BUDGET_BLOCK_BUDGET` consecutive blocks in one session the guard allows the turn end with a visible `systemMessage` that still names the valve, then stays stood down for the rest of that session and says nothing further.
Two things re-arm it, and only those two, exactly as they re-arm the notices: a positive measurement back below the advisory point, and a compaction boundary newer than the one the record was written with.
A compaction is a genuine reset that does not change `session_id`, so leaving it out would strand a session that had actually cleared.

That is deliberately different from the turn-end supervision guard in [`turnend-guard.md`](turnend-guard.md), which resets its block budget on every allow.
The asymmetry is the point.
A blind turn end is a repairable condition and a forced continuation is itself the repair prompt, so blocking again on a later turn is useful pressure.
The measurement does not fall on its own inside an episode, so a guard that reset its budget would oscillate between blocking and allowing forever, and each forced continuation would add tokens to the context it exists to cap.
Standing down is the correct end state here; it is not the correct end state there.

While the stand-down holds, this guard contributes nothing to the harness's shared consecutive-block accounting, so stacking it alongside the other `Stop` hooks does not drive the union of blockers toward the harness's own override.
That is not a whole-session guarantee.
The stand-down clears on either genuine-reset proof above, and after that this guard can block again and count again, up to its own bound each time.
What is bounded is each armed stretch, not the session total.

## Scope

The guard binds primary firstmate sessions: the main home and every secondmate's own home.
A secondmate runs its own primary session and is measured and enforced exactly like the main primary, whether its home is a treehouse-leased linked worktree or a plain clone.

Crew subagent turns are inert, by two independent mechanisms:

- The guard is registered on `Stop`, which fires for the primary turn only.
  A subagent's completion fires `SubagentStop`, which the guard is not registered on.
- Claude Code 2.1.220 writes subagent turns to a separate `<session-id>/subagents/agent-<id>.jsonl` file.
  The `transcript_path` in the payload points at the parent transcript, which contains none of them, and the `isSidechain` filter excludes them regardless of layout.

Crewmate and scout task worktrees are outside scope through the shared primary predicate, because their git dir differs from their git common dir and they never carry the secondmate marker.

## Per-harness support

This slice supports claude only.
Nothing here claims universal coverage.

| Harness | Status | Reason |
| --- | --- | --- |
| claude | **Supported** | `transcript_path` on every hook payload, measurement cross-validated against the harness's own accounting. |
| codex | Later | Forwards a full `Stop` payload, but whether it carries a transcript pointer is unverified. Needs its own probe. |
| opencode | Later | Plugin runtime with an SDK session object; the usage route is unverified. Needs its own probe. |
| pi | Later | Sessions persist on disk, so a transcript equivalent exists. Needs its own probe. |
| grok | **Not deliverable** | Project-hook stdout does not reach model context, so even a correct measurement cannot be delivered as an instruction. |
| kimi | **Not supported** | The `Stop` payload carries no transcript pointer at all, so the session cannot self-measure. A turn-count proxy spans a 119x range and would not defend the number. |

Each remaining harness needs the harness installed and its own probe, and lands as its own change.

## Registration

Claude registers three `Stop` hooks in `.claude/settings.json`, all anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, `bin/fm-context-budget.sh --claude`, then `bin/fm-claude-stop-autoarm.sh`.
Stacking a third `Stop` hook is the established pattern, not a new mechanism.

The harness's consecutive-block override counts a stop where *any* hook blocked, so it is shared across all registered hooks rather than per hook.
[`verification/context-budget.md`](verification/context-budget.md) records the decompiled cap, its default, and the environment variable that raises it; do not restate the number from memory.
What this guard contributes to that shared count, and the limit of that claim, is stated once under "Never wedge a session" above.

The guard is deliberately not folded into `bin/fm-turnend-guard.sh`, which owns exactly one predicate, and it deliberately does not use `PreToolUse`, which would run many times per turn for no extra safety and cannot act at a safe boundary.

Neither native knob can do this job.
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is ignored on a 1M model, which short-circuits to its own limit before the variable is read, and is honoured only when `DISABLE_COMPACT` removes the mechanism that would respect it.
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` is an internal test knob that did not trigger compaction when set far below the live baseline.
Firstmate measures and enforces this itself.

## Regression coverage

`tests/fm-context-budget.test.sh` covers the three measurement correctness rules and the multi-block property that subsumes dedupe, the derived advisory and its per-episode dedup and re-arm, the absolute 180,000 default, the warning-only shipped default and the exact enforcement opt-in, the channel each notice lands on with stdout and stderr captured separately, the sticky stand-down and its advisory-level re-arm, the compaction-boundary re-arm, its clear-once property, and its exclusion of a sidechain-marked boundary, the trip record's content, its size bound, its inability to influence any decision, and its one-line-per-crossing granularity under both the default and enforcement, the deliberately unfixed ceiling straddle, the count-not-recorded degrade's own notice key and its once-per-episode bound, an unparseable block record leaving the guard active without unbounding the block budget and tracing the parse failure once per episode, record durability against a trailing zero-usage synthetic entry, two sessions in one home, a missing or unsafe `session_id`, an unwritable record and a wholly unwritable state directory, a raised mid-session block budget and long-dead record pruning, the full degradation matrix including valid-JSON non-object lines, main and secondmate primary scope, crewmate and secondmate-child worktree exclusion, the bounded block budget and its per-session keying, claude-only mode gating, the tracked `Stop` registration, and the one-owner and no-injection boundaries.
[`verification/context-budget.md`](verification/context-budget.md) records the live measurements, the end-to-end block proof, and the secondmate and subagent characterization.
