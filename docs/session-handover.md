# Session handover and the helm

This is the authoritative current contract for replacing a Firstmate session whose context has grown past the point where it reasons well, and for deciding when a fresh session may take the helm from the one already holding it.
AGENTS.md section 8 carries the operating stub; the `handover` skill carries the procedure; each script's header and `--help` own exact flags and mechanics.

Two problems it closes:

- A session keeps working long past the point where its answers get worse, because nothing measures that or offers a clean replacement.
- A fresh session cannot take over when the previous one is alive but doing nothing, and it is told only that "another session holds the lock".

## The threshold

The threshold is a flat **250,000 tokens**, set in `bin/fm-session-pulse.sh` and overridable with `FM_HANDOVER_THRESHOLD` for tests and live proof.

It is deliberately not a share of the context window.
A percentage of a one-million-token window would park a session around 700,000 tokens, deep inside the degradation the threshold exists to avoid.
This is a thinking-quality line, not a capacity line: nothing overflows at 250,000, and nothing is blocked there either.

Crossing it produces one non-blocking notice per session.
Falling back below it - after a handover, or after the harness compacts - re-arms the notice for a later episode.

## Measuring the context

No turn-end hook payload carries a token count, so the number comes from the transcript the payload points at.
`bin/fm-context-measure-lib.sh` is the single owner of that measurement and of two rules every caller keeps: read `transcript_path` from the payload rather than deriving it from `$HOME`, and never write a second formula.

The total is `input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens` on the last non-sidechain `assistant` entry, with four correctness rules: dedupe a multi-block turn by `requestId`, take the last entry rather than the maximum (compaction resets the running total), exclude sidechains so a subagent's context never counts against the primary, and ignore a synthetic all-zero-usage entry - the shape Claude Code writes whenever a turn ends abnormally - so an interrupted turn is never misread as a reset to zero.

Per-harness support is `claude` only.
No other verified adapter's turn-end payload carries a transcript pointer, so the pulse requires `--claude` and is inert otherwise.
The activity marker below would work on any harness, but shipping half of the pulse elsewhere would create a second contract to keep in sync, so the fan-out lands with its measurement.

Every unmeasurable input - absent `jq`, a missing or unreadable transcript, a corrupt transcript, no assistant usage, empty stdin - is a silent exit 0.
The pulse runs as a `Stop` hook and must never wedge a session.

The cost is one pass over the whole transcript at every primary turn end: measured at 1.6 seconds on a real 45 MB transcript, and nothing on a crewmate turn end because the scope check runs first.
Reading only the tail would be cheaper, since the formula needs the last turn, but a tail window that cuts the only assistant entry in half degrades to unmeasurable and silently disables the notice.
That optimization is deliberately not taken here: this runs inside the machinery that supervises live work, and the current pass is the one already proven correct.

## The handover is captain-triggered

A watcher cannot respawn the interactive session in the captain's terminal, so nothing here replaces a session by itself.
Firstmate detects the threshold, prepares, verifies, and reports; the captain decides.

Past the threshold the session keeps working.
It does not stall the fleet waiting for an answer, accepting degraded reasoning in the meantime, because a stalled fleet is worse than a slower one.

## The record points, it does not assert

`data/handover.md` is durable, never a temp file, and the previous record is kept as `data/handover-prev.md`.

It is explicitly advisory: the durable records win every disagreement with it.
A session at its threshold is exactly the session whose recollections should not be trusted, so the only content it asserts is the content that exists nowhere else - the concrete next step, and what each live worker is mid-way through.
Everything else is a pointer the replacement can check.
Live fleet state is deliberately absent, because `bin/fm-session-start.sh` prints it fresh.

## The refusal

`bin/fm-handover.sh release` verifies before it frees anything, and refuses with the exact missing item.
Once the outgoing session is gone a bad handover cannot be redone, so this refusal is the most important behaviour in the feature.

It requires all of:

- a present, non-empty record carrying a `Next step:` line;
- a note for every live worker in `state/*.meta`, saying what it is mid-way through;
- a durable record behind every live thread - a backlog item for a task, a registry entry for a direct report;
- every pointer in the record resolving to a file that still exists and is non-empty.

`prepare` applies the worker half of that list too, so an unaccounted worker fails early rather than at release time.
Everything is re-checked at release even when `prepare` just passed, because a task can appear, and a record can be edited or truncated, in between.

Nothing here discards anything: it never stops a session, never touches unlanded work, and never drains the durable wake queue.

`prepare`, `release`, and `consume` all require this session to hold the helm.
A session refused the lock still reads the record and is shown it in full at session start, but it may not rotate it away or mark it picked up: a `prepare` from a session with no authority would replace the outgoing holder's record with one it composed, and a `consume` from one would leave the session that actually takes the helm told nothing is waiting.
Information is never withheld from a refused session; only its ability to mutate is.

## The gap

Monitoring stops when the outgoing session ends and resumes when the replacement arms it.
That gap is accepted and made visible rather than hidden: queued wakes survive it on disk, `release` reports how many are waiting, and the replacement drains them at session start.

## Taking the helm from an idle holder

The session lock used to test only whether the holder's process was alive.
A forked or resumed background window stays alive indefinitely while doing nothing, and because watcher continuity is repaired at turn end, a holder that never ends a turn never repairs it either - so supervision can stay dead for hours behind a lock that looks healthy.

`bin/fm-helm-lib.sh` owns the replacement decision, and it requires **two independent proofs**:

- **Silence.** The newer of two mtimes, and nothing else: the turn-end activity marker `state/.helm-activity`, which must be readable, non-empty, stamped with this holder's own pid, and naming a transcript file that still exists, and that transcript itself. The transcript grows during a turn, so a holder working through one long turn reads as busy rather than idle. `FM_HELM_IDLE_TAKEOVER` sets the required silence and defaults to 1800 seconds.
- **Unattended.** The holder has no controlling terminal at all, read from `ps -o tty=`.

The session lock's own mtime is **not** evidence of anything.
`bin/fm-lock.sh` writes `state/.lock` once when a session claims the helm and nothing ever refreshes it, so its age is the session's age rather than its quietness: a live, busy holder measured as 7200 seconds silent through it.
Measuring silence that way over-estimates it, and over-estimating silence is the direction that permits a takeover, so the lock was dropped as a source entirely.

A timer alone is never sufficient.
An attended holder keeps the helm however long it has been quiet, and every unprovable input refuses rather than proceeding: a terminal `ps` will not report, and equally a holder with no pid-matched marker, or one whose marker names no usable transcript, whose silence is simply unmeasurable.
The rule is fail-closed by design - no proof of work means no takeover - and the accepted cost is that a holder which cannot prove it is working keeps the helm until someone clears it by hand.

The READ path is the single authority on what counts as evidence: `fm_helm_silence_seconds` requires a marker that is readable, non-empty, pid-matched to this holder, and names a transcript file that still exists, and it returns unmeasurable when any of those fails.
A marker that names no usable transcript is not evidence, so the takeover is refused rather than decided on the marker's own mtime, which proves a turn ended once rather than that the session is working now.
The check cannot live where the marker is written, because a marker is a persisted claim that outlives the file it names: it may predate any write-time rule, and the transcript can be deleted, rotated, or moved afterwards.
The refusal says which part was missing - no marker for this holder, a marker naming no transcript, or a marker naming a transcript that is gone - because a person debugging a refused takeover needs to know which.

`fm_helm_stamp` therefore always writes, even when the turn end has no transcript to name.
Refusing to write would leave the PREVIOUS marker standing: a turn that stamps a good transcript, followed by one that resolves nothing, would leave the reader measuring silence from the earlier turn while the holder works on a turn nothing observes.
Overwriting with this turn's truth, including "no transcript this time", makes that case fail closed.

The pulse records why a transcript could not be resolved in `state/.helm-activity-declined`: the holder's pid, the time, and the reason - no transcript path in the payload, a path that was named but does not resolve, or `jq` unavailable to read the payload at all.
It is diagnostics, not a gate: it explains a refusal and never causes one.
It is one record, overwritten rather than appended, cleared by a turn end that does resolve a transcript and wherever the helm changes hands, and it is read back pid-matched so a dead session's reason is never attributed to the current holder.
When `bin/fm-lock.sh` refuses a takeover because silence is unmeasurable, it quotes that reason, because the person asking "why did this not take the helm" reads the refusal and not a file they do not know exists.

So with `jq` unavailable or the transcript unresolvable, silence stays unmeasurable, an automatic takeover never happens, and the operator's path is the printed refusal plus `bin/fm-lock.sh clear --pid <holder>`.
The same is true on a primary running codex, opencode, pi, grok, or kimi, because only the `claude` pulse stamps the marker today.
Giving those harnesses the stamp is a separate follow-up slice, not a gap being ignored.

The tradeoff in using "no controlling terminal" as the unattended proof: a session the captain is using owns a terminal device, while a session its own harness forked inherits none.
A named terminal always means refuse, even when the process-group flag suggests the session is in the background, because handing the helm away from a session someone is using is worse than one extra refusal.
[`verification/session-handover.md`](verification/session-handover.md) records the measurement behind that choice.

A takeover is reported loudly, says which session it took the helm from, states plainly that the other session was not stopped, and appends an auditable line to `state/.helm-takeover`.

When acquisition refuses instead, it prints the holder, its terminal, how long it has been quiet, why the takeover was refused, and `bin/fm-lock.sh clear --pid <holder>` - the one command that clears the helm.
`clear` refuses any pid that is not the recorded holder, and never claims to have stopped anything.
`bin/fm-lock.sh release` gives up the helm only for the session that holds it.
`bin/fm-lock.sh status` reports the caller's own helm as held rather than printing a takeover verdict about it, because "takeover: available" about your own session reads as an invitation to take the helm from itself.

## What waits on the captain, and what is already answered

Two lists sat hundreds of lines into the session-start digest and were skipped, so answered questions were escalated again and standing preferences were missed.
The fix is not more text earlier.

`bin/fm-awaiting-captain.sh` prints a short block near the top of the digest: decisions held for the captain, work recorded as waiting to land, any released handover, and one line pointing at the captain's standing preferences.
It reads only local records - no network, no forge calls - so it stays cheap enough that nobody skips it.
What counts as a decision held for the captain, and where a task's pull request is recorded, are the canonical snapshot definitions shared through `bin/fm-backlog-record-lib.sh`; the block renders them and never re-derives them, so a hold that is blocked or already in flight is not listed as waiting.
A task's meta survives from merge until teardown removes it, so the pull-request list drops the records that same shared model already calls done or merged, and says plainly that the rest are recorded locally rather than verified: a false entry there spends the captain's attention on work he has already finished, and buying the verification with a forge call would cost the local-only property that justifies the block.
When the digest prints a released handover in full, the block points at what was printed instead of telling the reader to open the record.
A session refused the helm is shown the same handover and told not to consume it, rather than being shown less.
Each list has a hard cap (`FM_AWAITING_MAX`, default 20) and says how many entries it dropped, because a silently truncated list reads as "nothing else is waiting".
For the same reason a failed read is never rendered as absence anywhere in that block: a missing `jq`, an unreadable record model, a task whose records cannot be read, or a failed pending-handover test each prints an explicit unknown marker instead of an empty list, and an unreadable record model also says that the already-landed entries could not be filtered out.

Answered decisions are **searched, not preloaded**.
A preloaded list of every answered decision does not scale, is mostly irrelevant to any one session, never shrinks, and competes with the wake queue for the same first-read slot - which is how the wall of text that hid those answers got built.
So the digest carries one line - how many answers exist and the instruction to search - and `bin/fm-decided.sh search <terms>` makes the lookup at the moment of asking a single cheap command.

The search covers `data/decided.md`, the index `bin/fm-decided.sh record` appends to, plus every other decision log already in the home's `data/` directory, so existing logs are searchable with no migration.
`data/NEED_DECISION.md`-style open views are excluded: mixing unanswered items into an answered-decision search is how a pending question gets treated as settled.
Output is capped by `FM_DECIDED_MAX_LINES` (default 40) and names what it dropped.

The accepted limit: a searchable record only helps when the search happens, and plain chat cannot be intercepted to force it.
It is a habit backed by a one-line reminder in the digest and a rule in AGENTS.md section 9.
If a settled question is escalated again, that is the evidence the reminder failed and a heavier check is warranted then.

## Not covered here

- Automatic respawn of crewmates at a context ceiling. The handover machinery is deliberately shared, but nothing drives it for a worker yet.
- Cross-provider handoff when a provider's quota is exhausted. Quota is reported per provider, not per agent, so respawning on an exhausted provider yields an equally stuck worker; that is a separate concern.
- A wedged agent that never ends a turn. A turn-end mechanism cannot see one; `stuck-crewmate-recovery` owns those.

## Verification

[`verification/session-handover.md`](verification/session-handover.md) records the current evidence.
The behaviour tests are `tests/fm-session-handover.test.sh`, `tests/fm-helm-takeover.test.sh`, and the handover case in `tests/fm-session-start.test.sh`.
