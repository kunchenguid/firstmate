---
name: gather
description: Curate reusable ecosystem lessons from completed Firstmate work using the same manual inspect-then-update model as /stow. Use only when the captain explicitly invokes /gather or explicitly asks to gather ecosystem learnings.
user-invocable: true
metadata:
  internal: true
---

# gather

Curate reusable ecosystem lessons into Pedro's private Spec Kit knowledge owner.
This is deliberate whole-file curation, not automatic collection, semantic sanitization, or raw backup.

## Fixed boundary

- Run only after an explicit `/gather` invocation or equivalent captain request.
- Reuse `/stow`'s sweep, routing, whole-file retention, inspect-then-update, consolidation, and concise-receipt pattern.
- Keep raw evidence with its existing owner.
  This skill never copies or presents transcripts, prompts, logs, source text, code, paths, identities, credentials, quotas, costs, company or customer facts, work identifiers, URLs, or source metadata.
- Use registered secondmates only through marked routed requests and returned document pointers.
  Never read a secondmate chat or crawl a home.
- The only destination is the exact private repository `pedromuller-del/artemis-spec-kit-plugin` and its owner `docs/ecosystem/curated-learnings.md`.
- Before reading any evidence owner, returned document pointer, or curated-learning owner, and before accepting a no-op, verify that the registered target identity and origin both resolve to that exact repository and that its visibility is private.
- Do not add an executable sanitizer, installer, candidate schema or protocol, denylist, crawler, daemon, raw backup, telemetry ledger, memory service, dashboard, destination adapter, mirror, or alternate store.

## 1. Sweep completed owners

Inspect only evidence already available through a completed or terminal owner:

- Firstmate task outcomes, scout reports, and curated local learnings;
- Spec Kit outcomes and retros;
- no-mistakes review, correction, test, and delivery outcomes;
- captain accept, rework, or discard feedback already captured by its owner;
- generalized candidate lessons returned by a registered secondmate through the marked reply contract.

Retain a lesson only when it is useful beyond one task, grounded in an observed outcome, and stated without source-specific detail.
Successful patterns are eligible alongside failures, corrections, review misses, duplicate work, context loss, and discarded approaches.
Task history, chronology, speculative advice, and facts useful to only one project remain with their current owner.
Unknown evidence stays unknown.

## 2. Build one whole-file update

Read the complete current `docs/ecosystem/curated-learnings.md` owner before drafting.
Treat an absent file as an empty owner, not as permission to reconstruct old evidence.

Build one retention plan for the whole document:

1. retain current reusable lessons whose evidence and revision condition still hold;
2. consolidate semantic duplicates into one concise statement;
3. rewrite superseded wording instead of appending chronology;
4. prune stale or task-specific material only when its durable owner remains intact;
5. add clear generalized lessons from this sweep.

Write the complete proposed Markdown to one private proposal artifact.
The artifact contains only the intended destination bytes and is not a new evidence owner or operational backup.
Keep the full proposal available to the captain by private path and digest, but do not require them to read it.
A byte-identical proposal is a no-op.

## 3. Ask only about ambiguity or possible disclosure

Non-ambiguous lessons proceed through the retention plan without captain review.
Create a decision only when judgment cannot safely settle at least one of these conditions:

- the lesson may still identify a source, person, company, customer, project, or work item;
- the wording may retain a path, credential, quota, cost, URL, code, log, prompt, transcript, or other source text;
- evidence is too weak or conflicting to support the generalization;
- a proposed rewrite or deletion could materially change a current retained lesson;
- two plausible generalizations have meaningfully different ecosystem consequences.

Default to exclusion when uncertainty cannot be represented safely.
Never reproduce the suspected bytes in captain chat, a decision record, or the proposed Markdown.
If even a redacted excerpt could reveal them, use only a generic risk description.
Across the excerpt, risk class, reason, action, and recommendation, disclose only the proposed generalized lesson and the existence of unspecified disclosure risk.
Do not characterize protected source context at any level of abstraction; euphemisms and category labels that imply it are exposure too.
For every item with possible disclosure, use a fully generic safe rendering: the excerpt says only that a potentially reusable lesson cannot yet be stated safely, the risk class is `sensitive context`, and the reason and recommendation discuss only safe evidence and exclusion without describing the protected context.

Present one compact list rather than the whole document.
Every item contains exactly:

- a safe key such as `R1`;
- a redacted generalized excerpt written from scratch, never copied from evidence;
- the risk class and one-sentence reason;
- one proposed action whose entire value is exactly `include`, `edit`, or `exclude`, never a qualified variant;
- a recommendation.

For a possible-disclosure item, render the fields with no candidate subject at all:

- excerpt: `A potentially reusable lesson cannot yet be stated safely.`
- risk class: `sensitive context`
- reason: `Available safe evidence is insufficient to support inclusion.`
- action: `exclude`
- recommendation: `Exclude unless new safe evidence resolves the risk.`

Only its safe key may vary.
Lead with the item count and recommended actions.
The captain answers by safe key; no response requires reading the complete proposal.
Apply only the recorded action, regenerate the complete proposal when an edit changes its bytes, and keep unresolved items excluded.
When the list is empty, request no captain decision.

## 4. Deliver through existing owners

Before project intake, independently repeat the registered target identity, private visibility, and origin verification against the exact `pedromuller-del/artemis-spec-kit-plugin` repository.
Carry the complete proposal path, digest, target owner, and digest of the current owner used for the retention plan in the task instructions.
A changed current-owner digest means the proposal is stale and `/gather` restarts from the whole-file read; it never overwrites the newer owner.

Use AGENTS.md's ordinary isolated project lifecycle with the registered delivery posture and authority.
The target worker copies the complete proposed bytes without regenerating them, runs the target repository's checks, and returns through guarded delivery.
Identity, private visibility, destination-byte, or current-owner drift stops delivery rather than redirecting it.
The docs-only learning owner does not require Spec Kit runtime activation.

## 5. Report the result

Give the captain a compact receipt containing:

- retained, added, consolidated, rewritten, and excluded counts;
- each safe decision key and applied action;
- whether the result was a no-op or delivered;
- the private target and delivered commit or PR;
- the private full-proposal path and digest for optional inspection;
- every unresolved exception without suspected raw bytes.

Do not paste the complete document unless the captain explicitly asks to read it.
Keep the private proposal at the receipt's path after confirmed no-op or delivery so it remains optionally inspectable.
A later `/gather` proposal may supersede it; otherwise remove it only on an explicit captain request.
Never alter or delete source evidence.
