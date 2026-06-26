---
name: report-problem
description: Record a captain-flagged recurring problem. Use when the captain invokes /report-problem or flags something that keeps going wrong (e.g. "this keeps failing", "X is too slow", "report a problem with Y"). Appends a structured entry (problem, symptom, impact, suspected root cause) to PROBLEMS.md and queues an evaluation, so the problem is named and tracked instead of fixes chasing symptoms.
user-invocable: true
---

# report-problem

The captain has hit a recurring problem - something slow, wrong, or repeatedly failing.
This skill names that problem in the registry before anyone fixes it, so the fix targets the cause rather than the symptom.
It closes one end of the capabilities loop: problem reported -> named in [`PROBLEMS.md`](../../../PROBLEMS.md) -> candidate fix/tool evaluated -> capability added to [`CAPABILITIES.md`](../../../CAPABILITIES.md) -> manifest and playbook updated.

Do not edit `PROBLEMS.md` by hand for this; the helper guarantees the exact, consistent schema.

## What it does

1. **Gather the four required fields** from the captain's message (ask one concise question only if a field is genuinely missing):
   - **problem** - a one-line title naming the problem, not the symptom.
   - **symptom** - what is actually observed (the failure, error, or degraded behavior).
   - **impact** - who or what it costs, and how much.
   - **cause** - the best current hypothesis for the root cause.
   - Optionally **fix** - a candidate remedy or tool, if one is already apparent.

2. **Record the problem** by running the helper from the firstmate repo root:
   ```sh
   bin/fm-registry.sh report-problem \
     --problem "<one-line title>" \
     --symptom "<what is observed>" \
     --impact "<cost>" \
     --cause "<suspected root cause>" \
     [--fix "<candidate fix or tool>"]
   ```
   This appends a `### P-<timestamp>-<slug>` entry to the "Registry" section of `PROBLEMS.md` with status `reported`, and appends a line to the fleet-local evaluation queue (`data/evaluation-queue.md`).

3. **Confirm to the captain** in plain outcome language: the problem is recorded and queued for evaluation, restated in one line. Do not expose internal mechanics.

## Scope: tracked taxonomy vs fleet-local incident

`PROBLEMS.md` holds the **general taxonomy** - problems any firstmate fleet can hit.
If the captain's report is a one-off, captain-specific incident with private context, record it in `data/` (fleet-local) instead, and only promote a sanitized, general version into `PROBLEMS.md` if it recurs across the fleet.
When in doubt, file it to `PROBLEMS.md` if it is general and to `data/` if it is specific to this captain's projects.

## Closing the loop

The problem now waits in the evaluation queue.
When firstmate evaluates it, advance the entry's **Status** (`reported` -> `triaging` -> `evaluating` -> `fix-identified` -> `resolved` | `wontfix`).
A `propose-tool` proposal is frequently the candidate fix; on resolution, record the landing change and update `CAPABILITIES.md` if the fix added or changed a capability.

## Notes

- This is a firstmate-repo change. When the fleet has crewmates in flight, ship shared, tracked changes to `PROBLEMS.md` through the normal pipeline; when the fleet is empty, firstmate may record directly. Either way the helper performs the append.
