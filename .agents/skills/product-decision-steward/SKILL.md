---
name: product-decision-steward
description: >-
  Agent-only workflow for an ordinary project secondmate steward that prepares, answers, or recovers repository-local Project Implementation Decisions.
  Load before shaping, creating, superseding, answering, or recovering a PID, and when authoring the steward's ordinary secondmate charter.
user-invocable: false
metadata:
  internal: true
---

# Product decision steward

This is a reusable responsibility for an ordinary secondmate, not a supervisor kind or a second decision queue.
The project Firstmate remains the repository authority and captain-facing surface, while the steward owns product judgment and delegates repository edits as ordinary tracked work.

## Scope

Escalate only a genuine product choice that changes customer or user experience, product behavior, policy, or a material project outcome.
Keep technical execution questions inside ordinary implementation work, and use `ask-user-authority` when a technical finding genuinely requires the captain's authority.
Do not turn a preference, resolved finding, implementation detail, or recommendation the steward can safely decide into a PID.

Before creating a PID, confirm that the question belongs to the captain and identify the captain-held task it gates in this steward's home.
Use the existing `bin/fm-captain-hold.sh hold` lifecycle rather than creating a second queue or inventing a PID-specific task state.

## Presentation and durable record

Write the question in non-technical product language and explain the user impact before asking for a choice.
Offer two or more lettered options and list concrete pros and cons for every option before giving exactly one recommendation with its rationale.
State neutral implementation consequences for each option and identify affected requirements, documentation, and related tasks.
Keep the alternative tradeoffs fair and do not hide the recommendation among the options.

Create through `bin/fm-product-decision.sh` in the work item's owning home.
The command's header and help own the input schema, durable record fields, allocation, replay, and route mechanics.
The script stores one private record per PID in the authoritative project Firstmate home and a repository-local monotonic identifier.
Never copy the full record or answer into startup memory, a main-home duplicate, or an unowned index.
If a material change makes an open PID obsolete, create a successor with its `supersedes` field instead of overwriting either record.

## Captain answers and follow-through

The captain may answer later in root chat or through Bearings, using the owner-qualified `<project>/pid-<n>` key.
Do not ask the captain to repeat an answer already captured in the durable record.
Preserve the exact answer and route it through `fm-product-decision.sh` so the existing `fm-captain-hold.sh` intake remains the only task resolver.
If the owner secondmate is offline, keep the authority-home route pending and retry through `fm-product-decision.sh retry-routes` when that home is available.

Once the answer is accepted, the PID record must retain the verbatim captain words and neutral consequences, and the held task must be resolved or released through the guarded intake.
The script reports the concise decision outcome through the existing typed parent channel.
If requirements or documentation are affected, recording the answer must not wait for those edits: queue an ordinary tracked documentation task and report whether that sync is queued or completed.
Do not directly edit a project worktree from the steward home.

An interrupted create or answer is durable work, not permission to create another decision or mark it complete.
Resume the matching reserved PID or pending answer through the script's retry path and confirm the recorded status before reporting completion.
