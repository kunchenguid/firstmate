---
name: propose-tool
description: Record a captain's proposal for a better alternative tool. Use when the captain invokes /propose-tool or proposes swapping or adding a tool (e.g. "propose we use X instead of Y", "there's a better tool for this"). Appends a structured proposed-tool entry (tool, what it replaces, why it is better) to CAPABILITIES.md and queues an evaluation, so the proposal is named and tracked instead of lost in chat.
user-invocable: true
---

# propose-tool

The captain has a better tool in mind for something firstmate already does.
This skill captures that proposal as a structured entry in the capabilities manifest and queues firstmate to evaluate it, closing one end of the capabilities loop: proposal recorded -> candidate evaluated -> capability added -> [`CAPABILITIES.md`](../../../CAPABILITIES.md) and the relevant playbook updated.

Do not edit `CAPABILITIES.md` by hand for this; the helper guarantees the exact, consistent schema.

## What it does

1. **Gather the three required fields** from the captain's message (ask one concise question only if a field is genuinely missing):
   - **tool** - the proposed tool and, if known, where to get it.
   - **replaces** - the current capability or tool it would replace or augment.
   - **why** - the concrete advantage: faster, more correct, fewer failures, lower cost.
   - Optionally **notes** - any extra context.

2. **Record the proposal** by running the helper from the firstmate repo root:
   ```sh
   bin/fm-registry.sh propose-tool \
     --tool "<tool>" \
     --replaces "<what it replaces>" \
     --why "<why it is better>" \
     [--notes "<optional context>"]
   ```
   This appends a `### T-<timestamp>-<slug>` entry to the "Proposed tools" section of `CAPABILITIES.md` with status `proposed`, and appends a line to the fleet-local evaluation queue (`data/evaluation-queue.md`).

3. **Confirm to the captain** in plain outcome language: the proposal is recorded and queued for evaluation, naming the tool and what it would replace. Do not expose internal mechanics.

## Closing the loop

The proposal now waits in the evaluation queue.
When firstmate evaluates it (often via a scout task that benchmarks the candidate against the incumbent), advance the entry's **Status** (`proposed` -> `evaluating` -> `adopted` | `rejected`).
On adoption, graduate the entry into the relevant category of `CAPABILITIES.md` with its version and known limits, remove it from "Proposed tools", and update any playbook that should now use it.

## Notes

- This is a firstmate-repo change. When the fleet has crewmates in flight, ship shared, tracked changes to `CAPABILITIES.md` through the normal pipeline; when the fleet is empty, firstmate may record directly. Either way the helper performs the append.
- If the captain is reporting a problem rather than proposing a tool, use `report-problem` instead; a proposed tool is often the candidate fix for a recorded problem.
