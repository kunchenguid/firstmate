---
name: doc-review-lenses
description: >-
  Agent-only procedure for reviewing planning artifacts, SPECs, scout reports, Linear Documents, ticket descriptions, and memlog-derived artifacts through named document lenses before those documents are treated as decision-ready or worker-ready.
user-invocable: false
metadata:
  internal: true
---

# doc-review-lenses

Load this before reviewing a planning artifact, SPEC, scout report, Linear Document, ticket description, story shard, or memlog-derived artifact through named document lenses.
It complements no-mistakes for document quality and planning integrity.
It does not replace no-mistakes, code review, project-docs, Linear workflow, or the captain's decision authority.

## Inputs

Read the target artifact in full before finding issues.
Also read any cited SPEC, memlog, report, ticket, PR, or project document that the target depends on for its claims.
If the artifact is large, split the review by section but keep one consolidated findings list.
If the target claims to be rendered from a memlog, read the memlog first and verify that every rendered decision, non-goal, ticket, and acceptance criterion can be traced to a current entry.

## Lenses

Use every required lens unless the caller explicitly scopes a narrower review.
Tag each finding with exactly one primary lens.

- `adversarial` tests whether a reasonable critic could reject the artifact's assumptions, scope, authority, or unstated tradeoffs.
- `edge-case` tests unusual projects, absent integrations, missing credentials, concurrent work, privacy boundaries, or failure modes that the artifact does not cover.
- `verification-gap` tests whether success signals, evidence, acceptance criteria, and rerender proofs are concrete enough to validate.
- `structure` tests ownership, ordering, duplication, rendering boundaries, dependency flow, and whether a worker could act without guessing.
- `prose` tests ambiguity, stale wording, captain-facing translation, excessive ceremony, and sentences that obscure the operational consequence.

## Finding format

Return a compact findings table followed by any safe self-resolutions already applied or recommended.
Use this schema for every finding:

- `id`: stable local identifier such as `DRL-001`.
- `lens`: one of the required lens tags.
- `severity`: `minor`, `moderate`, or `major`.
- `evidence`: exact source location or quote.
- `risk`: what can go wrong if this remains as written.
- `route`: `self-resolve`, `captain-ticket`, `defer`, or `dismiss`.
- `recommended action`: the concrete edit, ticket, or reason to leave it alone.

## Routing findings

Do not turn every unresolved captain-facing finding into a decision hold or ticket.
Firstmate self-resolves smaller document revisions when the overall project direction already answers them.
Use `self-resolve` for clarification, missing cross-references, local inconsistency, incomplete verification wording, stale phrasing, and limited scope choices that stay inside the approved initiative direction.
Use `captain-ticket` only for large directional commitments such as product scope expansion, architecture or workflow commitments that constrain future work, security or privacy posture, irreversible or costly external commitments, or a conflict between approved sources that cannot be resolved from the existing direction.
When `captain-ticket` is required, create or request a Linear issue assigned to the captain and summarize the decision needed in plain language.
Use the decision-hold lifecycle only when the unresolved decision must be tracked locally rather than as a Linear issue, or when another firstmate contract specifically requires that lifecycle before completion.
Use `defer` only when the artifact can remain useful without the answer and the deferred question has a named destination.
Use `dismiss` only when the issue is invalidated by a cited source or is below the artifact's intended rigor.

## Memlog interaction checks

A memlog is source material for one initiative's planning render, not a general memory bucket.
It never replaces `/stow`, because `/stow` routes session knowledge to the most specific durable owner and may decide that a fact belongs in captain preferences, learnings, backlog, a project `AGENTS.md`, or shared tracked material instead.
It never replaces graphify, because graphify indexes and queries a corpus but does not own decisions or rendering authority.
If graphify is run over a corpus that includes rendered SPECs or memlogs, treat its output as navigation evidence only and trace decisions back to the memlog before changing tickets or briefs.
If `/stow` finds a session decision for an active initiative with a memlog, the stow sweep may add or cite the memlog entry, then still route any broader reusable learning to the normal knowledge owner.

## Done criteria

The review is done only after the findings list names the lenses used, each finding has a route, and any `captain-ticket` or local decision tracking destination is explicit.
For a memlog-derived artifact, the review is done only after the report says whether the render is traceable from current memlog entries.
Before treating an investigation or visual review as complete, load `decision-hold-lifecycle` if any unresolved decision remains outside a Linear ticket.
