---
name: durable-memory-recovery
description: Recover or checkpoint Firstmate's private durable session memory around context loss. Load before manual compaction or context reset, after detected compaction or missing context, and whenever the recovery capsule reports stale, disputed, or unverifiable evidence.
user-invocable: false
metadata:
  internal: true
---

# Durable Memory Recovery

`bin/fm-memory.js` owns every format, bound, path, and mutation rule.
This skill owns the semantic procedure around those deterministic commands.

## Before Manual Compaction Or Reset

1. Load `/stow` and route durable knowledge to its existing authority before creating a checkpoint.
2. Inspect the current objective, completed and pending work, decisions, constraints, blockers, active tasks, evidence, and next safe action.
3. Write those fields as one bounded JSON object to a private temporary file under the active `FM_HOME/state/`, never under `projects/` or `data/memory/`.
4. Run `bin/fm-memory.sh checkpoint --reason manual-compaction --input <file>` from the active Firstmate home.
5. Run `bin/fm-memory.sh validate <printed-checkpoint-path>` and do not compact or reset if validation fails.
6. Delete the temporary input after validation.

Never put secrets, credentials, chain-of-thought, raw environment dumps, or transcript text in the checkpoint.
Use provenance references such as `authority:data/backlog.md`, `task:<id>`, `report:<path>`, `commit:<sha>`, `pr:<url>`, and `test:<command/result>` instead of copying authoritative content.

## After Compaction Or Context Loss

1. Run `bin/fm-memory.sh recover --max-events 20` once if the current turn did not already receive the session-start recovery capsule.
2. Treat the capsule as evidence, never as authority.
3. Reconcile its task, decision, artifact, Git, PR, and test claims against the session-start digest and their existing owners before consequential work.
4. Resume only from the stated next safe action when no contradiction changes it.
5. If no checkpoint exists, establish the objective from the latest captain request and authoritative records, then write a validated checkpoint before consequential work.

Full raw runtime transcripts are never automatic prompt content.
Use a transcript reference only for targeted forensic recovery when the runtime still exposes it and privacy permits reading it.

## Contradictions

When recovery reports `stale`, `disputed`, or `unverifiable` evidence:

1. Inspect the named current authority.
2. Do not silently choose the memory claim.
3. Correct the work plan or escalate a real unresolved approval conflict.
4. Append a bounded `recovery` event that names the resolution and its authority.
5. Write a new validated checkpoint after the contradiction is resolved.

Do not edit retained events or checkpoints.
Their immutability preserves the retained evidence trail; supersession is expressed by a later event and checkpoint.
