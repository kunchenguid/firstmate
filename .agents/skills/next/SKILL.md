---
name: next
description: >-
  Identify the single highest-value concrete action for the captain, using deterministic fleet-wide ranking and durable task evidence rather than exposing workflow state.
  Use when the captain invokes /next or asks for the one most useful thing to do next.
user-invocable: true
metadata:
  internal: true
---

# next

Return one chief-of-staff recommendation, not a fleet digest or workflow explanation.
The answer must tell the captain what to physically or mentally do next.

Run `bin/fm-next.sh --json` once.
The command owns eligibility, ranking, autonomous-work exclusion, closure fallback, and the structured evidence packet.
Never re-rank its selection or alternatives, and never execute the selected action during the `/next` invocation.

The command's `card` is the reliable deterministic rendering.
Return it unchanged when it is already natural and specific.
You may translate the selected packet into smoother action guidance only from these supplied fields: `action`, `context`, `checks`, `done_when`, `why`, `outcomes`, task identity, artifacts, requirements, review plan, and completion evidence.
Do not invent an acceptance criterion, checklist item, command, artifact, outcome, or reason for the ranking.
When supplied evidence is insufficient, preserve the card's one concrete inspection and the question it answers instead of filling the gap from conversation memory.

Keep action and outcome separate.
A correction found during review belongs under `POSSIBLE OUTCOMES`; it is not an alternative action.
Only the command's `alternatives` may appear as `OTHER WORTHWHILE ACTIONS`, in their supplied order, with at most two entries.
Do not expose lifecycle labels, ranking tiers, delivery-mode labels, raw revision hashes, or internal supervision mechanics.

Use the card's structure:

```text
NEXT — <specific human action>
TASK <ref> - <meaningful name>

<context>

DO THIS
<numbered concrete checks or actions>

DONE WHEN
<observable success and failure>

WHY THIS
<why it outranks other useful work and what it unlocks>

POSSIBLE OUTCOMES
<accept, continue, fix, or action-specific consequences>
```

If `selection` is null, return `Fleet needs no captain action.` exactly.
If collection fails, report the concrete failure rather than guessing from conversation history or the latest task event.

Use `/tasks` for breadth, `/task` for depth, `/next` for focus, `/close` for guarded archival, and `/history` for recall.
A `/next` recommendation supplies no acceptance, delivery, closure, or follow-up authority by itself.
