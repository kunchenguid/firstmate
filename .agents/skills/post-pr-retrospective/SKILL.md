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

Load this skill whenever a Firstmate-owned PR first becomes ready for review, before the required Lavish PR recap and before any merge.
This retrospective is part of finishing the PR, not optional backlog work.
A truthful no-op is correct when the evidence reveals no reusable improvement.

## Ask the workers

Ask every worker that materially implemented, investigated, reviewed, or recovered the delivered result this exact bounded question without authorizing file changes:

> Looking only at this completed work, what could have made it materially faster or more effective without weakening safety, correctness, proof, or the captain's accepted intent?
> Name the concrete friction or mistake, the earliest point it could have been prevented, and one reusable change to an existing instruction, skill, script, test, or tool.
> Omit generic advice, task-specific trivia, and anything already owned correctly.
> If no reusable change is justified, say so.

Use the target worker's verified send path from `harness-adapters`.
Do not ask a worker to edit the PR after validation has completed.
When multiple workers contributed, preserve disagreements rather than averaging them into false consensus.

## Verify before distilling

Treat each answer as a hypothesis until direct evidence supports it.
Check the completed diff, validation findings, status history, report, or exact tool behavior that the worker cites.
Reject suggestions that merely request more process, duplicate an existing owner, restate task chronology, optimize for one harness without reviewing the supported fleet, or weaken a safety or proof boundary.
Ask what observation would disconfirm the proposed improvement, and run the smallest safe check when the claim is load-bearing.

A reusable improvement must satisfy all of these conditions:

- It prevented or prolonged a real issue in the completed work.
- It applies beyond the exact branch, identifier, temporary path, or incident.
- Its destination is the authoritative owner rather than a convenient duplicate.
- The proposed change is smaller than the recurring cost it removes.
- Its acceptance check can show the process became faster or more effective without weakening correctness.

## Route immediately

Route each verified improvement to the most specific owner.

- Project-wide knowledge needed by almost every contributor belongs in that project's `AGENTS.md`, using `bin/fm-ensure-agents-md.sh` and the project's normal delivery path.
- A named conditional workflow belongs in the relevant project or Firstmate skill, with one concise load trigger in its always-loaded instruction surface.
- Deterministic mechanics belong in the owning script and its `--help`, with a behavior-level regression test.
- Shared Firstmate lifecycle behavior belongs in Firstmate's tracked surface after loading `firstmate-coding-guidelines`.
- Captain working preferences belong in the appropriate private `data/captain.md` or main-authoritative `data/captain-shared.md` after inspect-then-update.
- Task chronology and one-off evidence stay in the report or PR and never become standing instruction.

Apply verified improvements in the current workflow rather than creating ordinary backlog debt.
Do not widen or mutate the already-validated PR.
Use a separate small delivery change when tracked material must change, and follow that repository's normal validation, visual recap, and merge authority.
When direct project editing is not currently and concretely authorized, dispatch the immediate bounded follow-up through Firstmate rather than writing the project yourself.
Record a captain decision only when the improvement changes product behavior, approval authority, destructive scope, security posture, or another boundary the captain owns.

## Report the result

Include a short retrospective section in the PR's Lavish recap with:

- the concrete friction found;
- the verified reusable improvement and its owner;
- whether it was applied, opened as an immediate separate delivery, or rejected;
- the evidence that safety, correctness, and proof were not weakened.

Do not expose worker mechanics or internal status labels in captain-facing text.
Do not claim continuous improvement when the result was a no-op.
