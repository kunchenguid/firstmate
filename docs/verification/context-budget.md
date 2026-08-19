# Context-budget guardrail verification

Audience: maintainer verification.

This record supports the current context-ceiling guarantees in [`../context-budget.md`](../context-budget.md).
Operator behavior and active limits remain in that guide.
Task-specific chronology and delivery transcripts remain in private reports or PR evidence.

All runs below used Claude Code 2.1.220 on 2026-07-28.
Every live session run happened in a throwaway git-initialised project under the task scratchpad, never in a firstmate checkout.
The reader measurements and the block-cap reading are read-only observations over an installed harness and existing transcripts, and mutate nothing.

## Payload carries no token data

A `Stop` payload recorded from a live session carries these keys and no token, usage, or context field:

```
background_tasks,cwd,effort,hook_event_name,last_assistant_message,permission_mode,
prompt_id,session_crons,session_id,stop_hook_active,transcript_path
```

Measurement must therefore come from the transcript the payload points at.

## transcript_path is not derivable from $HOME

The same payload resolved `transcript_path` under this shape, with the home prefix elided here:

```
~/.claude-work/projects/<slugified-project-path>/<session-uuid>.jsonl
```

The config directory is `~/.claude-work`, not `~/.claude`.
A guard that reconstructed the path from `$HOME` would have missed the transcript entirely and degraded to silence on every turn.
`bin/fm-context-budget.sh` reads the path from the payload only.

## Live measurement matches the transcript

A baseline session measured through the shipped reader:

```sh
FM_CONTEXT_BUDGET_CEILING=900000 bash bin/fm-context-budget.sh --claude < last-stop-payload.json
```

Result: exit 0, silent.
Independently summing the last non-sidechain assistant entry's four usage fields over the same transcript returned `30454`, the same number the guard computed.

## End-to-end block proof, with enforcement driven on

This run exercised the ENFORCEMENT path, which is off in the shipped default.
It proves the enforcement path works end to end in a real session; it is not a demonstration of default behavior, and the default never reaches a blocking exit status at all.

The run predates the warning-only default: at the time the guard blocked unconditionally at the ceiling, which is exactly the behavior `FM_CONTEXT_BUDGET_ENFORCE=1` now selects.
Reproducing it today needs that variable added to the invocation below.

The guard was registered as a real `Stop` hook in the scratch project's `.claude/settings.json`, then driven with the ceiling set below the session's own baseline:

```sh
FM_CONTEXT_BUDGET_CEILING=20000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 \
  claude -p 'Reply with exactly: LIVEPROOF3_OK' </dev/null
```

Observed: the hook ran three times in the single run and recorded exit status 2, 2, then 0.
The two blocking invocations emitted:

```
●  CONTEXT BUDGET CEILING REACHED - HAND OFF AND CLEAR
●  This session measures 32633 tokens, over the 20000 ceiling.
●  Take the valve now, before any other work:
●    1. Run /stow to write durable knowledge, decisions, and unfinished work to disk.
●    2. Write a handoff note naming what you were doing and the exact next step.
●    3. Clear the context and resume from the stowed record.
```

The third invocation allowed the turn end once the block budget was spent.
The `claude` process exited 0.
This confirms both halves of the enforcement guarantee: the ceiling blocks a real session and names the valve, and bounded blocking releases the session rather than wedging it.

The stand-down that follows a spent budget is now sticky, so a fourth and later invocation over the ceiling stays allowed and silent.
That behavior postdates this run and is covered by fixtures in `tests/fm-context-budget.test.sh` rather than by a live capture.

## An exit-0 Stop hook's stderr is discarded

The earlier block proof above exercised only the enforcement exit-2 path.
Under the shipped warning-only default the guard never exits 2 at all, so the feature's entire observable behavior had never been proven visible.
It was not: both non-blocking notices were written to stderr, where nothing renders them.

Headless `claude -p` cannot decide this, because it emits no `Stop` hook response event to distinguish the two streams.
The repeatable method is interactive:

1. In a throwaway git-initialised project, register two `Stop` hooks. One prints a marker to stderr and exits 0; the other prints `{"systemMessage":"<marker>"}` to stdout and exits 0.
2. Have both hooks append to their own log file, so hook execution is confirmed independently of what the UI shows.
3. Drive a real Claude TUI under tmux, let one turn end, then capture the pane.

Observed: the stdout `systemMessage` rendered in the pane as a visible `Stop ... says:` system line, while the stderr marker appeared zero times, with both log files proving both hooks had run.

Corroborating reading of the bundled JavaScript in the installed 2.1.220 executable, re-run for this record:

```sh
strings -a "$(command -v claude)" | grep -o 'case"hook_success".\{0,220\}'
```

Two expressions decide it:

```js
case"hook_success":{return null}
case"hook_success":if(e.hookEvent!=="SessionStart"&&e.hookEvent!=="UserPromptSubmit"&&e.hookEvent!=="UserPromptExpansion")return[];
```

The first is the UI renderer for a successful hook's output; the second is the model-context mapper, which passes hook output through only for those three events.
A `Stop` hook that exits 0 is neither rendered nor fed to the model.
`systemMessage` is the documented channel that is: the same binary's hook-response schema describes it as a "Warning message shown to the user".

`bin/fm-context-budget.sh` therefore emits the advisory notice, the warning-only ceiling notice, and the sticky stand-down as `systemMessage` objects on stdout, and keeps stderr for the blocking path only.
`tests/fm-context-budget.test.sh` captures the two streams separately for exactly this reason; the earlier suite merged them with `2>&1` and so could not have caught an invisible notice.

## The default notice is captain-facing, and may not render at all

Two separate limits, established after the channel move.

**It is not delivered to the model.** The hook-response schema quoted above describes `systemMessage` as a "Warning message shown to the user", and the model-context mapper passes hook output only for the `SessionStart` family.
Probed directly: a session was asked in the turn after a `systemMessage` had visibly rendered whether it had received it, and answered `DID_NOT_SEE_IT`.
The blocking exit-2 path is separately proven to reach the model by the block proof above, where the session read the banner and answered its instruction.
So under the shipped warning-only default nothing instructs the session, and the automatic handoff needs `FM_CONTEXT_BUDGET_ENFORCE=1`.

**It may not render either.** A bounded one-axis experiment ran eight trials in a project where `Stop` hooks are known to fire, with hook execution confirmed from the transcript on every trial.

| Axis | Values tried | Result |
| --- | --- | --- |
| A: emitting `Stop` hook count | 1, 2, 3 (three is firstmate's real primary) | identical |
| B: message body | single-line, multi-line | identical |

Across the eight trials: 30 confirmed emissions and zero renders, captured after turn 1 and again after a completed second turn.
All three candidate causes are ruled out, and the premise that two emitting hooks are somehow special is false.

**Unproven, and deliberately not explained away:** why the same single-line exit-0 `systemMessage` rendered twice in that same project earlier could not be established.
The honest statement of the shipped default's behavior is therefore that the notice may not appear at all, and that the file-based trip record is the channel the feature relies on.

## The trip record

`state/.context-budget-trips` exists because of the section above: how often the ceiling is crossed is the question the warning-only first release is meant to answer, and a display behavior this repo does not control cannot be the answer's source.

Its constraints are structural rather than measured, and each has a fixture in `tests/fm-context-budget.test.sh`:

| Constraint | How it is pinned |
| --- | --- |
| Write-only, never read for a decision | One identical scripted session replayed three ways - record kept, deleted before every turn end, corrupted with NUL bytes before every turn end - comparing every exit status and both streams. All three are byte-identical, and the replay reaches both the blocking path and the stand-down. |
| Bounded | A 4,000-line, 444 KB fixture is trimmed on the next turn end to under the 128 KiB cap and at most the most recent 500 entries, keeping the newest and dropping the oldest. |
| Records each crossing, with size | Asserted on the exact line shape, including stage, measured total, ceiling, advisory, enforcement state, and session. |
| Silent below the advisory | No file is created at all for an ordinary session. |
| One line per crossing, not per turn end | 12 turn ends at a steady 160,000 write one advisory line; dropping below the advisory point and climbing back adds exactly one more. Six enforcing turn ends across two blocks, the stand-down, and three stood-down turns write one ceiling line. |
| A parse failure is traced | An unparseable block record writes one `stage=record-unparseable` line naming the session. |
| A lost block bound is traced | A block count that could not be written writes one `stage=ceiling-unrecorded` line, even when the ceiling notice was already spent, and six such turn ends still write one line. |
| That trace is bounded too | A record that is corrupt *and* cannot be rewritten is re-read at every turn end; six such turn ends write one line, not six. |

Granularity was measured before it was corrected: 12 turn ends at a steady 160,000, with the measurement never changing, produced 12 trip lines and exactly one notice.

```
2026-08-04T04:27:51Z stage=advisory total=160000 ceiling=180000 advisory=150000 enforce=0 session=tripsess
2026-08-04T04:27:51Z stage=advisory total=160000 ceiling=180000 advisory=150000 enforce=0 session=tripsess
```

That answers how long a session lingered above the advisory point rather than how often the guard fired, and the two differ by the length of every episode.
The line is now written where the stage is recorded, so entering a stage is what emits it.
The enforcing path prints its banner on every blocked turn and so cannot dedupe through the notice; it records its crossing separately, which is why the six-turn row above exists.

**Unproven:** the retention and garbage-collection question raised by the attachment-durability work is not answered here.
How long a harness keeps a `hook_success` attachment, and whether anything reclaims it, was not established, and nothing in this guard depends on it.

## Zero-usage synthetic entries are real

A real 81 MB session transcript on this host carries 32 assistant entries whose four usage fields are all `0`:

```sh
jq -c 'select(type=="object")
  | select(.type=="assistant" and (.message.usage|type)=="object")
  | {m: .message.model, t: ((.message.usage.input_tokens//0)+(.message.usage.cache_creation_input_tokens//0)+(.message.usage.cache_read_input_tokens//0)+(.message.usage.output_tokens//0))}' <transcript>
```

Every one of them reports `{"m":"<synthetic>","t":0}` on the main chain.
Claude Code writes them when a turn ends abnormally, such as a login or API error or an interrupt, which is precisely when a `Stop` hook fires, so one is the last assistant entry exactly when the guard measures.

Counted, it would read a long session as `0` tokens.
That false zero then looks like proof of a reset: it takes the below-advisory branch, which is one of the two places the sticky stand-down is cleared.
The reader now takes the last *positive* total, and a non-positive measurement leaves the turn inert instead of clearing anything.

## Compaction boundaries are the other proof of a reset

A compaction does not change `session_id`, and the transcript file is named after the session, so a session-keyed record survives one.
The drop-below-advisory rule usually covers that, but not when the post-compaction total is still above the advisory: the record would then stay stood down for the rest of a session that had genuinely reset.

The marker is already in the transcript the reader walks:

```json
{"type":"system","subtype":"compact_boundary","compactMetadata":{"preTokens":318961,"postTokens":18947}}
```

Those `preTokens` and `postTokens` are real observed values across one boundary.
The reader counts boundaries in the same streaming pass as the token measurement, so proving a reset costs no second read, and each record stores the count it was written with.
A record is cleared only when the current count is strictly greater, so a boundary already accounted for cannot clear it twice, and a record whose own count is missing or unreadable is kept - the same retention bias as everywhere else in the file.

Because a boundary now clears a record, the tally is part of the measurement and obeys the sidechain rule with it.
The sidechain exclusion sits above the branch rather than inside the token arm, so a boundary carrying `isSidechain` counts for nothing.
This is defensive rather than observed: Claude Code 2.1.220 writes subagent turns to a separate `<session-id>/subagents/agent-<id>.jsonl`, so no sidechain line of any kind reaches the parent transcript today, and none was found in any transcript on this host.
It is guarded anyway because that layout is version-dependent, and the earlier feasibility scout got exactly this wrong by expecting sidechain entries inline.
Left unguarded, an inflated tally would delete both records and put a spent stand-down back into service, which is the loss-path class the sticky record exists to close.

## A per-line jq error does not abort the streaming pass

The streaming reader carries `select(type == "object")`, and the earlier records here and in the operator guide justified it as preventing a hard `jq` error from aborting the whole measurement.
That justification was wrong for the streaming reader and has been corrected.

With `jq -R` every line is a separate input, so an error on one input is reported to stderr and jq continues with the next input:

```sh
printf '"a bare string"\n{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":100,"output_tokens":5}}}\n' \
  | jq -R -r '(fromjson? // empty) | select(.type == "assistant") | .message.usage | (.input_tokens // 0) + (.output_tokens // 0)'
```

On jq 1.7.1-apple that prints the error for line 1 and then `105` for line 2.
The abort risk was real only in the original slurped `jq -s` reader, where the whole transcript is one input and one error kills everything; that reader was replaced by the streaming pass recorded below.

The clause is kept, because skipping a non-object line deliberately is better than skipping it by way of a suppressed error, but it is no longer described as abort protection.
The colocated test was rewritten with it: it now pins the observable contract - non-object lines before and after the entry that must be measured, the later entry still measured, the earlier one not latched, and no diagnostic on the hook's own stderr - and says in its own comment that it cannot distinguish the clause's presence from its absence, because nothing observable does.

## The consecutive-block override cap

`docs/context-budget.md` previously repeated Claude Code's 8-consecutive-block override as bare fact.
It was unverified folklore at the time.
It is now substantiated by reading the bundled JavaScript out of the installed 2.1.220 executable:

```sh
strings -a "$(command -v claude)" | grep -o '.\{280\}CLAUDE_CODE_STOP_HOOK_BLOCK_CAP.\{280\}'
```

The relevant expression:

```js
let Kt = Rue(process.env.CLAUDE_CODE_STOP_HOOK_BLOCK_CAP, 8);
if (Kt > 0 && _o > Kt) return ... `A hook blocked the turn from ending ${_o} consecutive times - overriding and ending turn.`
```

Three facts follow, and they are what the guard's own bound is set against:

- The cap defaults to 8 and is adjustable through `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`.
  The same binary's user-facing text confirms it: "For Stop/SubagentStop hooks, check `stop_hook_active` in the input and return success while it's true. Set `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` to raise this limit."
- The counter it is compared against is incremented once per stop where *any* hook blocked, guarded by `blockingErrors.length > 0`.
  It is therefore session-wide and shared across every registered `Stop` hook, not per hook.
- A cap of `0` or less disables the override entirely.

Because the counter is shared, per-hook block budgets do not compose: several independently-budgeted blockers firing out of phase can keep consecutive stops blocked past the cap even though no single hook exceeds its own budget.
`bin/fm-context-budget.sh` answers that by standing down stickily once its budget is spent, which removes it from the shared count for as long as the stand-down holds.
The stand-down record is keyed to `session_id` and is only ever cleared by evidence of a genuine reset - a positive measurement below the advisory, or a compaction boundary newer than the one the record was written with - so a second session in the same home, a raised block budget, or a zero measurement cannot put this guard back into that shared count.
Each of those two proofs can occur mid-session, so what is bounded is each armed stretch and not the session total; an unparseable count is read as no record at all and likewise leaves the guard armed, bounded by its own budget again.

## The session cannot clear itself

In the blocked run above the session answered the instruction with:

> I can't clear my own context; that's yours to do.

Clearing is a local user action with no tool surface.
Steps 1 and 2 of the valve are autonomous; step 3 requires the captain.
[`../context-budget.md`](../context-budget.md) records the resulting away-mode consequence.

That same run also reported `/stow` missing, because the bare scratch project carried no skills directory.
`/stow` is tracked at `.agents/skills/stow/` with `user-invocable: true`, and `.claude/skills` symlinks to it, so it resolves in every real firstmate home and secondmate home.
The lab was re-provisioned with the tracked skills tree to confirm this, and the absence was a property of the bare lab, not of the valve.

## Secondmate primary sessions are bound

A genuine linked worktree was created and marked as a secondmate home:

```
git-dir       : .../ctxlab/.git/worktrees/ctxlab-sm
git-common-dir: .../ctxlab/.git
```

The two differ, so this has the exact shape of a treehouse-leased secondmate home and would be exempt under the linked-worktree test alone.

Controlled pair, same worktree, same transcript, same ceiling, marker as the only variable:

| `.fm-secondmate-home` | Guard exit | Banner |
| --- | --- | --- |
| present | 2, then 0 past the budget | `CONTEXT BUDGET CEILING REACHED` |
| absent | 0 | none |

A secondmate's own primary session is measured and enforced exactly like the main primary.
The same worktree without the marker has the shape of a crewmate or scout task worktree and stays inert whatever its context size.

## Subagent context is separate and never counted

A live session was driven to spawn one general-purpose subagent through the `Task` tool.

`SubagentStop` fired once; the primary `Stop` hook fired once.
Both payloads carried the same `transcript_path`, pointing at the parent transcript.

Entry census of that parent transcript:

```json
{ "total": 14, "assistant_total": 3, "assistant_sidechain": 0, "assistant_mainchain": 3 }
```

The subagent's turns are not in the parent transcript at all.
Claude Code 2.1.220 writes them to a separate file:

```
<project>/<session-id>/subagents/agent-<id>.jsonl
```

Census of that file: 7 entries, all 7 carrying `isSidechain: true`, last assistant total `24461`.

Meanwhile the guard measured the primary at `33217`.
The subagent's 24,461 tokens never reached the primary's number.

The guardrail is therefore inert for crew subagent turns by two independent mechanisms: the guard is registered on `Stop`, which a subagent's completion does not fire, and the payload's `transcript_path` points at a parent transcript that contains no subagent entries.
The `isSidechain != true` filter remains in the reader as defence in depth, and is verified against synthetic fixtures in `tests/fm-context-budget.test.sh` because the current on-disk layout no longer produces inline sidechain entries to exercise it.

This partially corrects the feasibility scout, which expected subagent turns to appear inline in the parent transcript marked `isSidechain: true`.

## Correctness rules

Summing every assistant usage object in the subagent run's parent transcript returned `99407` against a correct measurement of `33217`.
That is the concrete cost of a naive implementation that adds turns instead of taking the last one.

The last-not-max compaction reset and sidechain exclusion are each covered by a fixture in `tests/fm-context-budget.test.sh`, as is the multi-block turn.

The reader has no `requestId` grouping, and deliberately so.
An earlier draft carried one, of the form `(.[-1].requestId) as $rid | [ .[] | select($rid == null or .requestId == $rid) ][-1]`.
That expression is provably equal to `.[-1]`: the last element of an array is a member of every subsequence that contains it, so filtering and then taking the last element returns that same element whether the variable was null or matched.
It was removed as dead code.

A real 81 MB session transcript confirms the field could not have carried that mechanism anyway.
Of its 14,691 assistant entries with a usage object, 14,669 have no `requestId` key at all and 22 do, and the 22 are the API-error entries.
Grouping by that field would have grouped essentially the whole transcript under `null`.

Multi-block dedupe is instead a property of taking the last entry, because each JSONL line of a multi-block turn carries that turn's own cumulative usage rather than a slice of it.
The same transcript shows the property directly: its longest run of consecutive assistant entries reporting one identical total is 13 lines at `159799`.
Summing a run like that would report thirteen times the real number; taking the last reports it exactly.

## One streaming measurement pass

The reader was originally two `jq` processes with the second slurping every parsed line into one array before filtering.
That cost landed on every single turn end, including the common case far below the advisory.

Both readers over the same 81 MB transcript, same host:

| Reader | Result | Wall | Max RSS |
| --- | --- | --- | --- |
| two passes, slurped | `444729` | 2.77 s | 299 MB |
| one streaming pass | `444729` | 0.64 s | 5.9 MB |

The measured number is identical.
The streaming pass filters and projects per line and keeps only the last emitted total, so MEMORY is constant in transcript size rather than proportional to it.

Time is not constant, and the table above says so: 0.64 s for the reader alone at 81 MB, and a separately measured 0.41 s over a 65 MB synthetic transcript.
The shipped hook end to end over that same 81 MB transcript, in a primary-shaped scratch home, measured 0.67 s and 0.72 s across two runs and returned `444729`, the same total as the table.
The cost is linear in transcript size, roughly 0.7 s per 80 MB on this host, and it is paid at every primary turn end including far below the advisory.
That tradeoff is accepted at these magnitudes; only the claim needed narrowing from "constant cost" to "constant memory".

## The test bar for this change, and one machine-local exception

The suites this change is required to keep green are the ones it touches: `tests/fm-context-budget.test.sh` in full, plus `bin/fm-lint.sh` and `bin/fm-doc-audience-check.sh`.

`bin/fm-test-run.sh --all` reports one failure on the development host used here, in `tests/fm-kimi-harness.test.sh`:

```
not ok - Kimi hook install refused a realistic config
```

The cause is the machine's `python3`, an asdf shim that needs `$HOME/.asdf` to resolve a tool version:

```sh
$ HOME=$(mktemp -d) python3 -c 'print("ok")'; echo "exit=$?"
exit=126
```

That test deliberately overrides `HOME` and links the shim into a fake `PATH`, so the shim cannot resolve and exits 126.

It is pre-existing and unrelated to the context budget.
Reproduced on untouched base `1672d95`, which predates this work, by two workers on two dates, with the same single failing assertion.
Every other file in that run passes: 102 files, that one failure.

It is deliberately not repaired here, because a change that also fixes an unrelated machine-local environment failure stops being reviewable.
It is tracked separately as `fm-kimi-harness-test-env`, which owns it.

## Which regression rows could show a failing-before state

Not every row in `tests/fm-context-budget.test.sh` can demonstrate one, and claiming otherwise would overstate the coverage.
Stated per change:

| Change | Failing-before state |
| --- | --- |
| Compaction boundary re-arms a spent stand-down | Yes. Against the previous script the row reports `expected exit 2, got 0`. |
| The trip record captures each stage firing | Yes. Against the previous script the record does not exist. |
| The trip record stays bounded | Yes. Against the previous script the 444 KB fixture is still 444 KB afterwards. |
| The enforce opt-in row's `'1 '` value | Yes, but only against a mutated subject. Both the old and new rows pass against the shipped script. Loosening the enforce check to accept a trailing space makes the new row fail with `expected exit 0, got 2` while the old row still passes, which is the concrete demonstration that the old row was inert. |
| Only a *new* boundary re-arms | No. The mechanism it bounds did not exist before, so it cannot fail against the previous script. It guards over-clearing in the new code. |
| A sidechain boundary never re-arms a stand-down | Yes. Against the script as of `822781b` the row reports `a sidechain boundary must not re-arm the stand-down on turn 1: expected exit 0, got 2`, and it passes once the sidechain exclusion is hoisted above the branch. |
| The trip record writes nothing below the advisory | No, for the same reason: there was no writer to be over-eager. |
| The trip record cannot influence a decision | No. It pins a constraint on new code rather than repairing old behavior. |
| Non-object transcript lines are skipped | No, and deliberately so. The reader is unchanged; the correction was to a wrong rationale and a vacuous assertion, and nothing observable distinguishes the clause's presence from its absence. |
| The trip record counts crossings, not turn ends | Yes. Against the previous script the row reports `12 turn ends at one steady measurement must record ONE advisory crossing, got 12`. |
| An enforced ceiling crossing is recorded once | Yes. Against the previous script the row reports `six enforcing turn ends over one ceiling crossing must record ONE line, got 6`. |
| The count-not-recorded degrade has its own notice key | Yes. Against the previous script, with the `ceiling` key already spent by a warning-only turn, the row reports `a spent ceiling notice must not silence the count-not-recorded degrade: stdout carried no systemMessage:` with an empty stdout. |
| An unparseable block record leaves the guard active | Yes. Against the previous script the row reports `an unparseable record must leave the guard active, not stand it down: expected exit 2, got 0`. |
| An unparseable block record records the parse failure | Yes. Against the previous script the row reports `the parse failure must name itself in the record`. |
| That trace is one line per episode | Yes, twice over. Against the previous script the row reports `got 0`, since nothing traced a parse failure at all; against the first cut of this round's own fix, with the trace unconditional, it reports `six turn ends on one stuck corrupt record must trace it ONCE, got 6`. |
| An unparseable record does not unbound blocking | Yes. Against the previous script the row reports `an unparseable record must leave the guard armed enough to block at least once, blocked 0 times`, which is the silenced guard this round removes. The upper half of the row - at most two blocks against a budget of two - passes against both, and is what proves leaving the guard armed did not cost the bound. |
| The straddle stays a known unfixed case | Partly. The three behavioral assertions pass against the previous script, because the behavior is deliberately unchanged. Only the two assertions on the recorded reasoning fail before this round: `the straddle must be recorded in the code as a known unfixed case`. The row's purpose is to fail on a later *removal* of that record or a silent change to the behavior, not to repair anything now. |
| The degrade prints once per episode | No. The previous script already deduped it, under the wrong key. This row exists to reject the unconditional variant, which would repeat at every turn end while the record stays unwritable. |
| An unwritable state directory never blocks and never goes silent | No. It passes against both scripts. It is coverage of a named failure mode rather than a repair, added because nothing previously pinned the harsher shape where neither record can be written. |

Two rows in this round are therefore green before and after, and neither is claimed as a fix.
The redirection-ordering correction below was found by one of the new rows and is a real defect fix with a failing-before state.

## A failed record write leaked the shell's error onto stderr

Every record write in `bin/fm-context-budget.sh` suppressed its own failure with a trailing `2>/dev/null`.
Bash applies redirections left to right, so on an unwritable record the output redirection fails while stderr is still the inherited one, and the shell's own message escapes.

```
$ printf 'x\n' > f && chmod 400 f
$ bash -c "printf 'y\n' > f 2>/dev/null"
bash: line 1: f: Permission denied
$ bash -c "printf 'y\n' 2>/dev/null > f"
$
```

That matters beyond tidiness: the blocking path uses stderr precisely because exit 2 delivers it to the model, so a stray `Permission denied` would land in the same channel as the banner.
All five record writes now place `2>/dev/null` first.
Found by `test_unrecorded_degrade_is_its_own_notice_key`, which asserts the degrade leaves stderr empty.
That row reaches the stderr assertion only once the notice-key fix is in place, so the leak surfaced on the first green of the key fix and not against the previous script, where the row fails earlier on the silenced notice.
With the key fix in and the ordering uncorrected it reports `the degrade must not use the discarded stderr channel:` followed by the record path and `Permission denied`.

## The ceiling straddle is latent, not live

A session oscillating across the ceiling re-notices on every turn end, because the recorded stage alternates and each crossing back looks new.
The defect is real in code and was measured for reachability rather than fixed.

| Replay | Sessions | Measured turns | Ceiling down-crossings |
| --- | --- | --- | --- |
| First | 189 | 41,244 | 0 |
| Second, independent | 190 | 41,353 | 0 |

Both replays used the shipped measurement and stage logic over real transcripts.
Downward moves above the advisory point do exist - 155 of them, p90 13,581 - so the mechanism is reachable in principle, but sessions that reach the ceiling climb past it rather than hover.

The measurement is also effectively monotonic inside an episode by arithmetic: each total is the previous prompt plus that turn's output plus whatever else arrived, so it can only fall on a reset, and a compaction boundary already ends the episode.

An earlier argument for reachability was withdrawn as wrong.
A p90 turn-to-turn delta of 6,710 is a magnitude, not a direction, and those deltas are growth, so a band argument does not establish that the condition is reached.

The case is left unfixed deliberately.
Making the stage monotonic, or recording the highest stage reached, would close it and make the independent-key case strictly worse, because a recorded `ceiling` could then never be superseded by the count-not-recorded degrade.
If it ever does occur the failure mode is a notice at every turn end: noisy, harmless, and self-announcing within one session.

**Unproven:** whether the shared-key case that needed a writable notice record beside an unwritable block record arises naturally.
It was produced deliberately with a read-only record file; no natural cause was found on this host.

## The inline measurement is kept on purpose, and the lib is behind it

A review of this branch asked it to source `bin/fm-context-measure-lib.sh` and delete the inline `measure_context`, on the grounds that the lib's own header names this branch and `docs/scripts.md` calls it the single owner of the turn-end measurement.

**That was declined by standing decision, twice, and this record exists so the refusal reads as reasoned rather than skipped.**
The adoption is not refused in principle - one owner is the agreed end state - but a straight swap today would delete working behavior.

A review of this branch also found a gap that made the lib's own caller wrong rather than merely differing: the lib did not drop a synthetic zero-usage entry the way this guard's rule 3 does.
One transcript of a 300,010-token turn followed by the synthetic zero-usage entry Claude Code writes when a turn ends abnormally used to measure:

```
lib   -> 0        (exit status 0, so a caller read it as a real measurement)
guard -> 300010
```

That was reachable in `bin/fm-session-pulse.sh`, which measures through the lib: a `0` is below its 250,000 threshold, so it took the under-threshold branch and removed the once-per-session `state/.handover-due` marker, wiping a handover that was already due whenever a turn ended abnormally.
That defect in the sibling hook, not in this guard, is tracked as `fm-session-pulse-false-zero` and is now fixed: the lib excludes a zero-total candidate from the pool before choosing the last entry, matching this guard's rule 3, so this same transcript now measures `300010` in the lib too.

Three ways the lib is still behind this implementation remain open, tracked as `fm-context-measure-lib-adoption`:

| Behavior | This guard | `fm-context-measure-lib.sh` |
| --- | --- | --- |
| Memory over a huge transcript | One streaming pass, constant memory | Slurps with `jq -s` |
| Compaction-boundary tally | Returned alongside the total, and `record_predates_a_compaction` needs it for genuine-reset detection | Absent, and cannot supply it |
| Multi-block turns | Takes the last usage entry | Dedupes by `requestId` |

The agreed end state is still the reverse move: put this streaming implementation, with the compaction tally, into the lib and have both callers adopt it.
That changes behavior for the other caller, so it carries its own tests and its own review, tracked as `fm-context-measure-lib-adoption`.

## Native knobs remain unusable

Neither `CLAUDE_CODE_MAX_CONTEXT_TOKENS` nor `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` can enforce this ceiling; the feasibility scout recorded the decompiled reason for each.
No dependency on either is present in `bin/fm-context-budget.sh`.
