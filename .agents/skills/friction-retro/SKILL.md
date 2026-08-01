---
name: friction-retro
description: >-
  Agent-only procedure for turning one task's repeated friction into bounded durable owner updates, at most one per distinct repeatable failure.
  Load before recording completion on a task whose own evidence shows two or more corrective steers, a costly failed validation loop, a verified safety or quality incident, or an explicit captain postmortem request.
  Distinguishes one-off judgment from repeatable failure and routes only the repeatable part to an existing owner.
user-invocable: false
metadata:
  internal: true
---

# friction-retro

This skill is the single procedure owner for turning verified task friction into bounded durable updates to existing owners, at most one per distinct repeatable failure.
Skip it for an ordinary task; running it after every trivial task is exactly the noise it exists to avoid.

## When to run

Run only when the completing task's own evidence shows at least one of the following.

- Two or more corrective steers or retries during that task.
- A costly failed validation loop, not a single ordinary fix-review round.
- A verified safety or quality incident.
- An explicit captain postmortem request.

A single steer, a normal one-pass validation gate, or an unconfirmed suspicion is not friction; do not run.

## Evidence

Read only this task's own report, its `state/<id>.status` history, its validation result, and firstmate's own record of what it steered or corrected on this task.
Do not scrape broader chat or session history, and do not reconstruct chronology beyond what those sources state.

## Classify each correction

For every correction the evidence actually shows, name it once and classify it as exactly one of the following.

- One-off judgment - a reasonable call that would not recur under the same instructions.
- Stale or wrong instruction - the crewmate followed a written instruction that was itself wrong.
- Missing knowledge - no owner stated the fact the crewmate needed.
- Missing deterministic enforcement - the crewmate had the right knowledge but a person had to catch the violation by hand.
- Unnecessary process - a step or gate cost more than the failure it prevents.

Do not classify a correction unless the evidence names an identifiable instruction, gap, or step.
Unclear evidence gets no classification and no follow-up.

## Route to the first owner that fits

For every repeatable classification, every class except one-off judgment, apply AGENTS.md section 6's routing table and stop at the first owner that can absorb the lesson: project `AGENTS.md`, home-local `data/learnings.md`, an existing skill, a test, a hook, a script, or deletion of the redundant prose that caused the failure.
Prefer patching or pruning that one owner's existing language over adding a new layer.
Never invent a new owner when this task's evidence supports only a one-line fact.
Produce at most one concrete follow-up per distinct repeatable failure; do not fan one incident into several speculative improvements.

## Prove the fix and bound the shortcut

Before proposing a follow-up, state the specific evidence from this task that the proposed change would have caught.
If you cannot point to that evidence, do not propose the follow-up.
If the follow-up is a deliberate simplification rather than a full fix, name the condition under which it should later be upgraded or removed.

## Deliver without mutating

The retro produces knowledge, and for a deterministic follow-up, a normal backlog item; it never edits a project directly, merges anything, or closes anything automatically.
File a backlog item exactly as any other queued work item under AGENTS.md section 10, worded as the durable fact plus its authoritative owner, not as incident narrative.
Keep incident chronology, transcripts, and status-line history in this task's own private report; only the distilled current fact and its owner reach a tracked surface.
This skill decides nothing that AGENTS.md section 1's project-write boundary, section 7's delivery-mode and `yolo` authority, or section 9's captain-facing rules do not already allow; it grants no new authority.
