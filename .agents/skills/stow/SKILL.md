---
name: stow
description: Sweep the current session for uncaptured durable knowledge and file it to disk before a context reset, and own the supervision context-recycling cadence. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, when a long-lived supervision session's remaining context falls below about a third of its window, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge that only exists in conversation right now, and write it to the disk locations firstmate already prints in the next session-start context digest.
The goal is a session that is safe to reset or destroy because everything durable has already been captured.

## What it does

1. **Sweep the session for uncaptured durable knowledge.**
   Read back over this conversation and look for:
   - Operational learnings: fleet-local facts and gotchas discovered while operating firstmate (a script's sharp edge, a harness quirk, a recurring false alarm and its real cause).
   - Captain preferences expressed in passing: a working-style or approval preference the captain stated conversationally rather than through the destination selected by AGENTS.md's knowledge-routing table.
   - Project-intrinsic facts discovered: build, test, release, or architecture facts about a project that belong in that project's own `AGENTS.md`.
   - Decisions made: a standing choice the captain made this session that should outlive it.
   - Undone next steps: anything left open that has not yet been filed as backlog work.

2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md (section 6, "Knowledge routing") is the single source of truth for where each kind of knowledge belongs.
   Read that table and route each finding there instead of re-deriving the mapping here.

3. **Write within firstmate's existing write boundaries.**
   This skill does not grant any new write permission; it only prompts firstmate to use the boundaries that already exist (AGENTS.md section 1):
   - Captain preferences and fleet-local operational facts: hand-write directly to the destination selected by AGENTS.md's knowledge-routing table, using inspect-then-update every time.
     Before writing, inspect the destination, find the existing bullet or section the finding duplicates or supersedes, and rewrite it in place rather than adding a new trailing entry.
     `data/learnings.md` may not exist yet; create it on first local learning, in the same dated, evidence-backed, curated style as the captain-preference files.
   - Project-intrinsic knowledge: never hand-write a project's `AGENTS.md`.
     Route it through a normal ship task so a crewmate records it via `bin/fm-ensure-agents-md.sh` and commits it through that project's delivery pipeline, exactly as section 6 describes.
     If the fleet is live, delegate this to a crewmate rather than doing it inline.
   - Knowledge generalizable to every firstmate user: this repo's own `AGENTS.md` (or other shared, tracked material), shipped through the normal branch -> no-mistakes -> PR -> captain-merge pipeline for this repo (section 1), never hand-committed straight to `main`.
   - Task-scoped notes: inspect the relevant backlog item with `tasks-axi show <id> --full`, judge whether the new note is new, duplicate, superseding, or obsolete, then write a considered replacement body with `tasks-axi update <id> --body-file <path>`.
     When the replacement intentionally supersedes prior state that should remain recoverable, add `--archive-body` to that update command so the prior body stays recoverable without copying it into the replacement.
     Never append.
     If hand-editing `data/backlog.md` per the active backend, make the same inspect-then-update edit in place.
   - Undone next steps: file each as a queued backlog item (section 10), with `blocked-by` recorded if it genuinely depends on something else.

4. **Curate with inspect-then-update.**
   Every write starts by reading the current destination and deciding how the finding changes what is already there.
   Use this checklist before writing:
   - Which existing bullet, section, or task body does this supersede?
   - Can this be a one-sentence rewrite instead of a new entry?
   - Should an older bullet or note be deleted, retired, or archived because it is now obsolete?
   When a finding overlaps or supersedes something already on disk, rewrite or prune the existing entry instead of piling on a new one.
   Graduation moves are limited to exactly three: promote a learning to the shared `AGENTS.md` via PR, fold it into the captain-preference destination selected by AGENTS.md, or delete a stale entry.
   Do not invent other graduation paths.

5. **Report to the captain.**
   Summarize, in plain outcome language (section 9): what was stowed and where, what was filed to the backlog, and whether the session is now safe to reset or destroy - i.e. whether every durable finding from this sweep now lives on disk rather than only in this conversation.
   If something could not be captured yet (for example, project-intrinsic knowledge waiting on a crewmate to land it), say so explicitly rather than reporting the session fully safe.

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
While away mode is active the captain is not present to reset, so complete the sweep, keep supervising, and raise the reset when they return.

## Scope exclusion: no skill storage

`/stow` must **never** store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
This is a deliberate, standing exclusion, not an oversight: even with the two-tier skill layout, a stow sweep is a memory-routing operation, not a way to author or mutate skills.
Writing learnings into either `.agents/skills/` or public `skills/` would still risk mixing fleet-local material with shared firstmate behavior or standalone installer-facing behavior.
Until a human deliberately scopes a skill change as firstmate repo work, route generalizable knowledge to the shared `AGENTS.md` (or other shared, tracked material) via the pipeline, and fleet-local knowledge to `data/`, never to a skill.
