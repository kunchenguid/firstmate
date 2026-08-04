---
name: post-pr-retrospective
description: >-
  Agent-only procedure for every Firstmate-owned PR that becomes review-ready.
  Use before presenting the PR recap or merging to ask every material worker how the work could have been completed faster and more effectively, verify the answers, and immediately route reusable improvements into their authoritative AGENTS.md, skill, script, documentation, or private operational owner.
user-invocable: false
metadata:
  internal: true
---

# post-pr-retrospective

Load this skill whenever a Firstmate-owned PR first becomes ready for review, before section 7's PR-ready captain report and before any merge.
This retrospective is part of finishing the PR, not optional backlog work.
A truthful no-op is correct when the evidence reveals no reusable improvement.

## Ask the workers

Ask every still-reachable worker that materially implemented, investigated, reviewed, or recovered the delivered result this exact bounded question without authorizing file changes:

> Looking only at this completed work, what could have made it materially faster or more effective without weakening safety, correctness, proof, or the captain's accepted intent?
> Name the concrete friction or mistake, the earliest point it could have been prevented, and one reusable change to an existing instruction, skill, script, test, or tool.
> Omit generic advice, task-specific trivia, and anything already owned correctly.
> If no reusable change is justified, say so.

Use the target worker's verified send path from `harness-adapters`.
Cover a material contributor that no longer has a live send path, such as a torn-down scout, a replaced worker, or an automated validation step, from its self-contained report, review or validation findings, status history, and the completed diff, and never relaunch or rebuild one to answer this question.
Do not ask a worker to edit the PR after validation has completed.
When multiple workers contributed, preserve disagreements rather than averaging them into false consensus.

## Verify before distilling

Treat each answer as a hypothesis until direct evidence supports it.
Check the completed diff, validation findings, status history, report, or exact tool behavior that the worker cites.
Reject suggestions that merely request more process, duplicate an existing owner, restate task chronology, optimize for one harness without reviewing the supported fleet, or weaken a safety or proof boundary.
Ask what observation would disconfirm the proposed improvement, and run the smallest safe check when the claim is load-bearing.

A reusable improvement must satisfy all of these conditions:

- It would have prevented or shortened a real issue in the completed work.
- It applies beyond the exact branch, identifier, temporary path, or incident.
- Its destination is the authoritative owner rather than a convenient duplicate.
- The proposed change is smaller than the recurring cost it removes.
- Its acceptance check can show the process became faster or more effective without weakening correctness.

## Route immediately

AGENTS.md section 6 is the source of truth for durable-knowledge destinations; select each verified improvement's owner there rather than re-deriving that mapping.

Only these routing behaviors are specific to a retrospective improvement:

- A deterministic mechanic belongs in the owning script and its `--help`, and lands together with a behavior-level regression test.
- A named conditional workflow belongs in the relevant skill, with one concise load trigger in its always-loaded instruction surface.
- Firstmate's shared tracked material changes only after loading `firstmate-coding-guidelines`.
- A project's `AGENTS.md` is written only by a crewmate through that project's selected delivery path with `bin/fm-ensure-agents-md.sh`, never by Firstmate.
- Task chronology and one-off evidence stay in the report or PR and never become standing instruction.

Apply verified improvements in the current workflow rather than creating ordinary backlog debt.
Do not widen or mutate the already-validated PR.
Use a separate small delivery change when tracked material must change, and follow that repository's normal validation and merge authority.
The retrospective and its routing decision must finish before the PR is presented, while that separate delivery only has to be initiated immediately and does not itself block presenting or merging the already-ready PR.
The single exception is an improvement whose evidence shows the ready PR is unsafe, which is a stop-and-report result rather than a follow-up.
Record a captain decision only when the improvement changes product behavior, approval authority, destructive scope, security posture, or another boundary the captain owns.

## Report the result

Include a short retrospective note in the PR-ready captain report with:

- the concrete friction found;
- the verified reusable improvement and its owner;
- whether it was applied, initiated as an immediate separate delivery, or rejected;
- any material contributor covered only from recorded artifacts because it was no longer reachable;
- the evidence that safety, correctness, and proof were not weakened.

Do not expose worker mechanics or internal status labels in captain-facing text.
Do not claim continuous improvement when the result was a no-op.
