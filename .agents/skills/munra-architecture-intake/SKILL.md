---
name: munra-architecture-intake
description: >-
  Agent-only protocol for intaking and briefing a Munra issue against Munra's committed agent-facing architecture model (docs/architecture plus docs/development/CHANGE_PROTOCOL, added by Munra PR #275).
  Load before selecting a Munra issue to dispatch and before writing a Munra implementation brief.
  Covers refreshing the clone to current origin/master first, choosing work from the current issue list and current master rather than a stale in-flight brief, and requiring the brief to consult the architecture index and change-impact protocol, apply the source-of-truth boundary, name the affected invariants and feature surfaces, and select the proving test lanes.
user-invocable: false
metadata:
  internal: true
---

# munra-architecture-intake

Load this before you select a Munra issue to dispatch, and before you write a Munra implementation brief.
Munra ships its own agent-facing architecture model under `docs/architecture/` and `docs/development/CHANGE_PROTOCOL.md` (Munra PR #275).
This skill makes firstmate operate Munra work through that model without freezing each issue into a rigid preplanned assignment.
It owns only the firstmate-side workflow; the model's substance stays in Munra's own documents, which the brief points the crewmate at rather than restating.

## 1. Refresh to current origin/master before intake

Do not select or brief a Munra issue against a stale clone.
Refresh the Munra clone through the guarded fleet-sync path (`bin/fm-fleet-sync.sh`, the same safe fetch session start uses) so both the open-issue list and the architecture docs you read reflect current `origin/master`.
The architecture index is only trustworthy at `origin/master`; an out-of-date clone can hide a renamed surface, a new invariant, or a just-merged consumer.
Read the architecture material from that refreshed state, never from memory of an earlier session.

## 2. Choose work from current reality, not a stale brief

Pick the next issue from the currently open issue list and current `master`, not from an in-flight brief left over from an earlier plan.
A brief written days ago encodes assumptions about code that may have moved; treat it as history, and re-derive scope from today's issue text and today's master.
This keeps issue selection flexible: firstmate commits to a concrete issue only when it is actually dispatching, and the impact analysis is built against the tree the crewmate will really edit.

## 3. Require the brief to consult Munra's architecture model

Every Munra implementation brief must direct the crewmate to Munra's own protocol; point at these documents, do not copy their content into the brief:

- Read `docs/architecture/README.md` first (the agent index) and follow its mandatory before-changing-code checklist.
- Build the change-impact graph per `docs/development/CHANGE_PROTOCOL.md` and meet its Definition of Done; green unit tests on one surface is explicitly not done.
- Apply the source-of-truth boundary the index defines: `WDD/` is normative design intent, `.planning/codebase/` is durable topology, and `docs/architecture/` is a descriptive implementation map; where the map disagrees with code the code wins, and a code-versus-`WDD/` conflict is logged as a Deviation, not silently resolved.
- Name the affected invariants (`docs/architecture/INVARIANTS.md`, machine subset `invariants.yaml`) and feature surfaces (`docs/architecture/FEATURE_GRAPH.md` and each consumer in `features.yaml`) the change must touch.
- Select the proving test lanes from `docs/testing/FEATURE_TEST_STRATEGY.md` and the index's test commands, and define the test evidence before implementing.

For a multi-surface feature, point at `docs/development/prompts/IMPLEMENT_CROSS_CUTTING_FEATURE.md`; for a bug fix or small feature, `docs/development/prompts/IMPLEMENT_CHANGE.md`.

## 4. Keep it a brief, not a frozen plan

State the architecture-consult requirement and the target issue; do not pre-decide the edit list.
The crewmate derives the impact graph itself from current master, so the brief stays a task description plus this requirement, not a rigid assignment that goes stale the moment master moves.

## Keeping this skill honest

These paths are Munra-owned.
If Munra renames or moves a document, update the pointer here rather than duplicating the document's content, so the two never drift.
