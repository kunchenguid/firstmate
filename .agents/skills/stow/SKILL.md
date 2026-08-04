---
name: stow
description: Sweep the current session for uncaptured durable knowledge and file it to disk before a context reset, and own the supervision context-recycling cadence. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, when a long-lived supervision session's remaining context falls below about a third of its window, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge that exists only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
This skill writes only through the existing Firstmate ownership and write boundaries.

## Required startup-memory pass

Every `/stow` invocation performs this complete pass, even when the session contains no new finding:

1. Run `bin/fm-startup-memory-budget.sh report` before considering a write.
   Record its effective budget and each file's estimated-token total.
   The helper's stable estimate is the documented conservative local approximation, not provider-exact accounting.
   If it rejects the setting or a memory file, do not infer a default or silently continue.
   Report that concrete exception and do not call the session reset-safe.
2. Read every current memory file completely: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`.
   Treat an absent local file as absent, not as an invitation to manufacture content.
   In a primary home, all three are curation inputs under their existing ownership rules.
   In a secondmate home, `data/captain-shared.md` is a read-only primary-owned input: count it, never edit it, and curate only the editable local files.
3. Build one whole-file retention plan before editing.
   Retain, in order: current captain preferences, authority and safety boundaries, and recurring working style; stable home-local operating facts that repeatedly affect future work and are expensive to rediscover; then concise pointers to an existing authoritative report, project document, configuration, or backlog item.
   Retain lower-priority material only while budget remains.
4. Consolidate every editable memory file as needed, not only the file apparently related to a new finding.
   Prefer one concise current rule or authoritative pointer over duplicate prose.
   Remove, merge, or route completed incident and release chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, superseded claims, duplicates, and report-sized procedures.
   Do not remove a unique current fact unless it is preserved directly elsewhere through a stronger existing owner.
5. Run `bin/fm-startup-memory-budget.sh report` again after the complete pass.
   Finish at or below the effective budget unless a concrete inability remains.
   A secondmate must explicitly report `primary-owned-shared-file-alone-exceeds-budget` when the inherited shared file alone exceeds its allowance, because local curation cannot resolve it.
   Any other unresolved excess must identify the fact that cannot safely be removed or routed and why.

A net increase is allowed only for a genuinely new current fact with no stronger owner.
Before allowing it, consolidate enough lower-priority material to remain within budget.
Never describe the session as reset-safe while the memory total is over budget or an exception is unresolved.

## Knowledge sweep and routing

1. **Sweep the session for uncaptured durable knowledge.**
   Look for operational learnings, captain preferences expressed in passing, project-intrinsic facts, standing decisions, and undone next steps.
2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md section 6 is the source of truth for destinations.
   Do not re-derive or duplicate that mapping here.
3. **Write within the existing boundaries.**
   - Captain preferences and fleet-local operational facts belong in the destination selected by AGENTS.md after the required whole-file curation pass.
     Create `data/learnings.md` only for a genuinely new local learning with no stronger owner.
   - In a primary home, curate shared captain preferences only under the existing primary-authoritative shared-preference contract.
     In a secondmate home, route a newly discovered shared preference to the main firstmate through marked status or a document pointer instead of editing the inherited file.
   - Project-intrinsic knowledge never goes directly into a project's `AGENTS.md`.
     Route it through a normal ship task so a crewmate records it with `bin/fm-ensure-agents-md.sh` and the project's delivery path.
   - Knowledge general to every Firstmate user belongs in this repo's shared tracked material through the normal branch, no-mistakes, PR, and captain-merge path.
   - For task-scoped notes, inspect the item with `tasks-axi show <id> --full`, classify the change as new, duplicate, superseding, or obsolete, then use a considered replacement body through `tasks-axi update <id> --body-file <path>`.
     Use `--archive-body` when recoverability matters.
     Never append.
   - File each undone next step as a queued backlog item with a genuine `blocked-by` dependency when applicable.
4. **Use inspect-then-update.**
   For every retained fact, ask which current statement it supersedes, whether it can be a one-sentence rewrite, and whether a stale entry should be deleted, retired, or routed to an existing stronger owner.
   The only graduation moves are promotion to tracked shared material through a PR, folding a learning into the captain-preference destination selected by AGENTS.md, or deletion of a stale entry.
   Do not invent another graduation path.

## Completion receipt

Report the outcome in plain captain-facing language with all of these facts:

- effective startup-memory budget and total estimated tokens before and after;
- one or more actions for each of `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`: `unchanged`, `added`, `rewritten`, `pruned`, or `routed`;
- each durable finding filed outside memory and its authoritative owner;
- every unresolved exception, including a primary-owned shared-file constraint in a secondmate home;
- whether the session is safe to reset, only when all durable findings are captured and the post-pass result is within budget with no exception.

Do not hide an over-budget result behind a reset-safe claim.

## Context recycling

Firstmate's own running cost is calls times context size times rate, so a supervision session that never resets re-reads its entire accumulated history on every wake.
`AGENTS.md` section 8 states the trigger that loads this skill; this section is the single owner of the threshold, the safe-point test, and the reset handoff.

### Threshold

Recycle when either of these holds:

- This session's remaining context has fallen below about a third of its window.
- The harness has warned that automatic compaction is imminent, whatever percentage it reports.

Evaluate this only at the end of a wake-handling turn, never in the middle of one.
One reading below the threshold is enough; do not wait for a second, because every further wake costs more than the reset would have.

### Safe-point test

Recycle only when every condition below holds.
If any condition fails, do not recycle: handle that item, keep working, and re-test at the next resting point.

1. The durable wake queue is drained and empty, and every wake drained this turn has been carried to a resting point - acted on, escalated, or filed as a backlog item.
2. No steer is outstanding: no worker is holding an instruction whose reply only this conversation is waiting for, and no marked secondmate request is awaiting a correlated reply that exists nowhere on disk.
3. No captain-facing escalation is unsent, and no captain decision received this session is still unrelayed to the worker that needs it.
4. Every unresolved decision is on disk as a backlog hold under `decision-hold-lifecycle`, not only in conversation.
5. No landing is half-done: no merge is started without its outcome recorded, and no teardown decision about unlanded work rests only on this session's memory.
6. The sweep above has run to completion, and every finding it produced is either already written to disk or dispatched as durable tracked work.
   Dispatched means the backlog item and brief are already on disk before the worker starts, not merely that firstmate intends to file it, so an outstanding crewmate task satisfies this condition rather than blocking the recycle.
7. A live supervision cycle is armed, so every wake arriving before the reset is queued durably.
   An in-process reset keeps that cycle, while a full harness restart ends it, because the watcher is armed as the harness's own tracked background task and dies with it.
   Nothing is lost across that gap: the next session-start digest drains the durable wake queue and re-reads every status and metadata record.

### Why nothing in flight is lost

A reset destroys conversation, never durable state.

- Queued wakes live in the home's durable wake queue on disk, and the next session's one-shot session-start digest drains them under the session lock as its first work queue.
- Signals not yet queued live in each task's durable status and metadata records, which the watcher re-reads on its next poll and the session-start fleet digest re-reads in full.
- The session lock survives either reset shape, because it records the harness process id: an in-process reset re-acquires its own lock, and a full harness restart leaves a lock whose recorded process is dead, which the next acquire replaces.
- Whatever existed only in conversation is exactly what the sweep above just wrote to disk or handed to a worker as an already-recorded task, which is why condition 6 is a precondition rather than an afterthought.

If any of those cannot be confirmed for this home, treat the session as not safe to reset and say so plainly instead of recycling anyway.

### Reset handoff

Firstmate cannot reset its own session, so the captain performs the reset.
Once the sweep passes, tell the captain in plain outcome language that everything durable is on disk and the session is safe to restart, then keep supervising normally until they do it.
Tell them to end this session before starting the replacement, because the session lock refuses a second acquire while a different live process still holds it, and the new session would otherwise come up read-only with no ability to spawn, steer, merge, or drain queued wakes.
Do not stop supervising, tear anything down, or hold new work back while waiting.

That announcement is a claim about the moment it is made, and continuing to supervise re-accumulates exactly the conversation-only state conditions 2 and 3 guard.
So the safe-point test stays live for as long as the announcement stands: re-run it at the end of every wake-handling turn after announcing, and again immediately before the reset if the captain says when they are about to do it.
When a re-test fails, retract the announcement in the same turn rather than letting the captain reset on a stale guarantee.
Retracting means telling the captain plainly that the session is no longer safe to restart, naming the specific item that changed - the correction still only in this conversation, the unrelayed decision, the unsent escalation - then carrying that item to a resting point on disk, and re-announcing only after the whole test passes again.
Because the captain may reset at any moment once told it is safe, keep the window small while the announcement stands: file each new steer, decision, and escalation to its durable destination as it happens rather than deferring it to a later sweep.
While away mode is active the captain is not present to reset, so complete the sweep, keep supervising, and raise the reset when they return.

## Scope exclusion: no skill storage

`/stow` must never store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
Until a human deliberately scopes a skill change as Firstmate repository work, route generalizable knowledge to shared tracked material through its pipeline and fleet-local knowledge to `data/`, never to `.agents/skills/` or public `skills/`.
