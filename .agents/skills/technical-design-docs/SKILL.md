---
name: technical-design-docs
description: >-
  Agent-only workflow for creating or materially revising implementation-ready technical design documents and reviewable technical-solution research from requirements, code evidence, Feishu comments, and review feedback.
  Use before drafting or changing a technical design or solution study that spans modules, repositories, persistence compatibility, frontend/backend contracts, validation ownership, or executable rollout evidence.
user-invocable: false
metadata:
  internal: true
---

# Implementation-ready technical designs and solution research

This skill owns the evidence model, review presentation intent, design content, and revision discipline for implementation-ready technical design documents and technical-solution research.
It does not own generic project intake, implementation delivery, review, or merge procedure.
For a Feishu document, load `lark-doc` and follow its current scenario reference before reading history, creating, editing, or manipulating a whiteboard; `lark-doc` owns Feishu API, XML, block selection, create, update, revision-precondition, whiteboard, export, preview, and readback mechanics.
Load `lark-drive` and follow its current comment references before reading, locating, replying to, resolving, restoring, or rechecking Feishu comments; `lark-drive` owns comment identity, pagination, location, reply, and resolution mechanics.
Before completing an investigation or review that exposed a genuine captain decision, or when routing the answer, load `decision-hold-lifecycle`; it owns the durable decision-record mechanics.

## Review shape and template fidelity

Apply this content and presentation contract to every Feishu technical design and every Feishu technical-solution research deliverable intended to guide a product or implementation decision.
It is a completion requirement within the categories and scope accepted for that document.
Use another language only when the requested review audience requires it.

- When the captain supplies a template, treat its information categories, hierarchy, order, scope, review density, and presentation pattern as the authority for the maintained document.
- Preserve the template's section purposes rather than merely copying its heading text.
- Do not add boilerplate sections because a generic checklist mentions them.
- Omit tests, rollout, monitoring, PPE or BOE, deployment, completion checklists, or any other category when the accepted template excludes that category.
- Keep the supporting task evidence, analysis, and verification private when they remain necessary but do not belong in the accepted document shape.
- Write concise Chinese prose that leads with the outcome, decision, or implementation consequence before the supporting mechanics.
- Use an existing summary or callout slot for load-bearing outcomes, invariants, decisions, risks, or owner boundaries rather than adding a new decorative section.
- Present exact document, repository, revision, commit, dependency, and generated-code baselines in compact evidence tables.
- Use stable terminology for identities, cardinalities, states, and owners, and define a term once before reusing it.
- Mark current behavior, proposed behavior, accepted decisions, and unknowns distinctly.
- Keep tables compact and reviewable, headings outcome-oriented, and exact code evidence adjacent to the contract it proves.
- Use visuals semantically to reduce review cost rather than decoratively.
- State unchanged ownership boundaries and forward-compatibility consequences explicitly when they constrain the change.
- Keep implementation chronology, command transcripts, validation theater, and delivery proof out of the maintained design.

### Two-layer readability

Write product and requirement sections for a reader with no prior subsystem background.
Explain the business background, the user-visible behavior before and after the change, important product or platform variants, and behavior that deliberately remains unchanged.
Keep repository paths, symbols, DTO rules, persistence mechanics, internal call order, and similar implementation detail out of that product layer.
Place implementation detail under the template's code-level section using the review-sized H3 units defined below.
Show Proto, TypeScript, Go, SQL, JSON Schema, or other relevant code contracts at subsystem boundaries with exact types, optionality, and call order when the template's technical scope needs them.
Include enough concrete code and call-site detail for implementation review without copying irrelevant implementations or creating a second source owner in prose.

### Semantic diagrams and render proof

Use a diagram only when architecture, current implementation, or a core flow is meaningfully complex and a visual will reduce review cost.
Prefer an overall architecture view, a sequence or core-flow view, and current frontend or backend UML-style views only when each view answers a distinct review question.
For a Feishu deliverable, use real Feishu whiteboards rather than inline diagram text that may not render.
Visually distinguish changed owners from unchanged owners and place each diagram beside the prose it explains.
Keep a simple document in prose and tables when a diagram would add ceremony without clarity.
Follow `lark-doc` for all whiteboard creation, update, export, preview, and attachment mechanics rather than copying those mechanics here.
A diagram is complete only after the remote board is written, exported or previewed from Feishu, and visually inspected for readability, missing content, overlap, clipping, and changed-versus-unchanged distinction.
Local diagram-source validation is useful but never substitutes for inspecting the rendered remote artifact.
Keep the exact document revision, board token, preview or export evidence, and visual inspection result in the private task report unless a reviewer needs that evidence in the maintained document.

A research deliverable may stop short of an implementation commitment, but it still needs the same baseline, evidence, ownership, conflict, alternative, testability, evidence-limit, and decision clarity within its accepted scope.
A technical document that cannot explain the business intent without prior context, locate material implementation owners, distinguish change from unchanged behavior, and show how the result will be proven is not implementation-ready.

## Evidence pack before prose

Build a compact evidence pack before proposing document text.
Keep task chronology outside the maintained design unless a concise rationale is needed to explain a current boundary.
Keep required evidence in the private task report when the accepted template excludes its category from the maintained design.

### Exact baselines

Record the following facts together so evidence from different moments cannot be blended accidentally:

- Pin the document identity, exact revision, revision read time, and any earlier revision being corrected.
- Pin every relevant repository to its canonical remote identity, default branch, and exact commit.
- Refresh live merge-request metadata and repository heads immediately before writing so the document cannot inherit a stale planning baseline.
- Pin generated-code sources, checked-in API artifacts, dependency versions, SDK declarations, and runtime package versions when they constrain the design.
- Distinguish the repository head from the version actually consumed by another repository.
- Distinguish implemented behavior at the pinned baseline from proposed behavior that has not landed there.
- Mark unavailable, stale, or permission-limited evidence explicitly rather than silently substituting a nearby checkout or latest package.
- Refresh a baseline before relying on volatile facts, and state when a design intentionally remains based on an older accepted revision.
- Preserve the canonical document identity for an in-place revision and verify that identity after the final write.

A baseline table should identify the source, immutable revision, why it matters, and which claims depend on it.
Line numbers are useful evidence at that revision, while repository path, symbol, and owner module are the more durable locator.

### Code and call-site evidence

Trace each important behavior through the executable path rather than stopping at a matching type or helper.

- Read the data declaration, constructor or decoder, validator, caller, persistence boundary, execution path, recovery path, and user-visible adapter that participate in the behavior.
- Inspect sibling paths and shared helpers when they can bypass, duplicate, or reinterpret the proposed owner.
- Inspect history or the accepted base when a current oddity may be migration behavior rather than the intended steady state.
- Separate what code proves now, what a requirement mandates, what the design proposes, and what remains unverified.
- Reconstruct concrete cardinality, identity, mutation, and failure sequences when a design claims they remain stable.
- Treat comments, names, and types as hypotheses until call sites and state transitions confirm their runtime meaning.

### Product invariant ledger

Translate product statements and corrections into testable invariants before choosing modules or APIs.
Each invariant should state the subject, allowed behavior, forbidden behavior, identity or cardinality rule, failure consequence, and supporting authority.
Record explicit non-goals and unsupported claims beside the invariants so they do not re-enter through tests, monitoring, rollout, or compatibility prose.
When product language and current code disagree, preserve both facts and classify the gap rather than rewriting one as if it proved the other.

### Conflict inventory

Inventory every location whose current claim conflicts with an accepted invariant or evidence baseline.
A conflict inventory should cover summaries, goals, architecture, diagrams, data ownership, wire examples, module plans, compatibility, tests, PPE, monitoring, rollout, open questions, and completion criteria.
Classify each item as a contradiction, unsupported assertion, stale baseline, duplicated owner, incomplete downstream update, or genuine unresolved decision.
Give each item a disposition of replace, delete, retain with evidence, or route as a decision.
Maintain negative search terms for retired concepts and positive checks for the replacement invariant.
A new correct section does not resolve an old contradictory section elsewhere in the document.

## Diagnose the design before patching

### Review-sized code map

Create a reviewable map by repository and runtime module using the template's existing implementation-detail section.
Use review-sized H3 units grouped by semantic owner or logical flow rather than implementation phase or delivery chronology.
For each unit, record exact paths and symbols, proven current behavior, implemented or proposed changed behavior, the owner boundary, call flow, edge and failure behavior, interactions, compatibility effect, and executable evidence.
Include generated repositories and ignored generated clients only when they are part of the actual delivery chain.
Mark a module unchanged when that conclusion depends on inspected evidence and matters to scope control.
Do not turn the map into a file wishlist that lacks call-site or ownership reasoning.

### Frontend and backend wire contracts

Show cross-boundary contracts in the code language each side consumes.

- Show the authoritative IDL or schema with exact field names, types, optionality, repeated or set semantics, path bindings, and response error model.
- Show the generated or typed frontend adapter and how transport values become domain values.
- Show the backend request conversion, shared validation call, and final mutation entry.
- Show create, edit, readback, retry, and failure ordering when order affects side effects.
- Label code as existing, proposed, or illustrative so pseudocode cannot be mistaken for a compiled contract.
- Reuse an existing wire type when it already expresses the invariant, and justify every new public field with behavior that cannot be represented otherwise.
- State what happens on unknown, malformed, unavailable, stale, or partial inputs instead of depicting only success.

Code blocks are contracts, not decoration.
Their symbols, types, optionality, and call order must agree across IDL, generated clients, frontend code, backend code, and surrounding prose.

### One-owner schema and validation boundaries

Assign every rule to one semantic owner and make other layers consume or call it.

- Put a static product matrix or field relationship in one typed rule source from which machine validation and UI metadata are derived when both need it.
- Keep dynamic, cross-record, authorization, and external-eligibility checks in narrow backend helpers rather than pretending a static schema owns them.
- Make preflight and final write paths call the same authoritative validation entry for their shared rules.
- Keep final writes authoritative even when an earlier preflight passed.
- State the preflight side-effect boundary and prove prohibited mutations with executable spies or fakes.
- Do not duplicate platform matrices, enum compatibility, canonicalization, or error interpretation in frontend, preflight, and write paths.
- Name the owner file or symbol and list every consumer that must stop maintaining a copy.

If frontend behavior needs richer controls, prefer owner-generated metadata over a second hand-maintained business matrix.
If the metadata is absent, duplicate, or contradictory, define whether the client stops, degrades for display only, or invokes a proven fallback.
A local display fallback must not become authority for a server mutation.

### Lowest-layer compatibility

Choose the lowest shared boundary that still has enough information to transform persisted or legacy data without loss.

- Prefer one decode-to-domain or model-to-domain compatibility owner before DTOs, services, list/get responses, validators, planners, and log formatters fan out.
- Make the transform pure, deterministic, deep-copying, and idempotent.
- Preserve already canonical input byte-for-byte where identity compatibility requires it.
- Do not write back, create a new version, infer provenance from shape, or expose a migration selector unless the accepted contract requires that behavior.
- Return an explicit contextual error when lossless mapping is impossible rather than dropping fields or guessing.
- Require every upper layer to consume the canonical result without repeating legacy detection.
- Test the actual shared read boundary so a unit test of an otherwise unused normalizer cannot create false confidence.

A higher-layer compatibility branch is justified only when the lower shared layer lacks required context or when callers intentionally need different semantics.
Document that reason and prevent the exception from becoming a second general owner.

## Build executable evidence into the design

### Automated tests

Specify tests through public or executable interfaces and observable behavior.
Place the test plan in the maintained document only when its accepted template and scope include that category, while retaining the executable evidence in the private task record otherwise.

- Cover every invariant with positive, boundary, and disallowed cases.
- Cover direct-write or alternate-entry bypasses that could skip a preflight or frontend rule.
- Prove canonicalization order insensitivity, idempotence, caller immutability, and duplicate handling where those properties matter.
- Pin legacy identity and naming with behavioral golden cases only when compatibility requires exact stability.
- Assert exact logical cardinality separately from physical chunks, files, retries, or transport nodes.
- Assert prohibited side effects on every failure path.
- Exercise wire serialization and the real generated or typed consumer when feasible.
- Feed owner-generated schema or metadata fixtures into frontend behavior so changing the owner changes the control behavior without source inspection.
- Test malformed, unknown, empty, timeout, and unavailable outcomes without collapsing them into generic failure or success.

Do not use source grep, source snapshots, or AST-shape assertions as substitutes for behavior.
For a machine-consumed declarative artifact, use the real consumer when feasible or parse it into a typed normalized model and assert meaning.

### PPE and rollout evidence

Write PPE scenarios as reproducible decisions, not as aspirations.
Place PPE, BOE, rollout, rollback, deployment, and monitoring material in the maintained document only when its accepted template and scope include those categories, while retaining required execution evidence privately otherwise.
Each scenario should name preconditions, input, action, observable system evidence, forbidden side effects, pass criteria, cleanup owner, and recovery path.
Use disposable external resources where the test mutates another system.
Separate claims that automation can prove from claims that require PPE, production observation, or another owner.
Tie monitoring to invariants such as validation outcomes, logical cardinality, reuse identity, or fallback rate while excluding credentials and high-cardinality business payloads.
Define deployment ordering and rollback constraints from data compatibility and active-reader behavior, not from a generic release template.
Never include a PPE or monitoring assertion that the code and product contract do not support.

## Observe-Diagnose-Patch-Verify

Material revisions use this loop until the conflict inventory is empty.

### Observe

Read the latest revision identity, outline, target section, dependent sections, and relevant history using the document owner's smallest sufficient read mode.
Confirm the template's information categories, hierarchy, order, and scope before deciding which maintained-document sections are allowed.
Refresh the live sources required by the exact-baseline contract immediately before writing.
Recheck the conflict inventory because an earlier patch or another editor may have changed its blast radius.

### Diagnose

Name the invariant or evidence mismatch and every dependent section it affects.
Decide whether the correction is local, a repeated-owner problem, a lowest-layer compatibility issue, a wire-contract change, or a genuine captain decision.
Choose one coherent patch unit that leaves no half-migrated contract between summary, architecture, code examples, tests, and completion criteria.

### Patch

Use the `lark-doc` editing workflow for Feishu documents, including its current revision-precondition and block-selection mechanics.
Patch the smallest coherent unit, but include all nearby dependent statements that would otherwise contradict it.
Prefer replacing or deleting stale owners over appending another explanation.
Keep a record of the revision returned by each successful patch.
Preserve the target document's canonical identity when the task is an in-place revision.

### Verify

Read back the edited section from the returned or latest revision and confirm the intended structure, code blocks, tables, and wording landed once.
Read back the complete final body and outline before declaring success.
Search the whole document for categories forbidden by the accepted template, retired terms, old decisions, opposite cardinality rules, duplicate matrices, duplicate sections, and stale failure or rollout claims.
Re-read the outline to catch hierarchy drift, reordered categories, duplicated sections, or misplaced inserts.
Reconcile every conflict-inventory item and update the baseline to the verified revision before the next patch.
When a patch changes an invariant, verify its consequences in wire contracts, module maps, compatibility, tests, PPE, monitoring, rollout, decisions, and completion criteria.
Confirm that unresolved decisions are either visibly retained in the accepted decision location or absent because they were durably resolved.
Confirm that the final revision still has the intended canonical document identity and exact refreshed code baselines.
Do not declare success from a locally correct inserted section while stale contradictory prose remains elsewhere.

If a revision conflict or partial document update occurs, stop and follow the document owner's recovery guidance before another write.
Do not stack speculative patches on an unverified revision.

## Feishu comment review loop

After a draft exists, treat Feishu comments as the normal review interaction channel rather than relying on chat alone.
Chat may clarify authority or provide evidence, but each affected review thread must carry the resulting disposition.

### Observe the review surface

Load both `lark-doc` and `lark-drive` and follow their current references before touching the review.
Read the current document revision first, then read every relevant comment and its complete reply thread, following the comment owner's pagination and solved-status rules.
Request comment location evidence where supported and match it to the current document block rather than relying only on quoted text.
When the original anchor was deleted or only a weak text match remains, label the location uncertainty and inspect the surrounding current section before diagnosing.
Do not infer that a comment was addressed merely because its quoted text disappeared.

### Build a comment-to-disposition inventory

Give every relevant comment one inventory row with its stable comment identity, current location or location confidence, reviewer concern, governing invariant, code or product evidence, disposition, dependent sections, decision key if any, reply state, and verification state.
Use dispositions such as accepted correction, answered with evidence, superseded by an accepted decision, duplicate, out of scope with authority, or unresolved decision.
Diagnose the complete comment set before editing so two comments cannot drive contradictory local patches.
Keep the inventory outside the maintained document unless a compact unresolved-decision table belongs in the design itself.

### Patch and reply

Update the smallest exact set of document sections that makes each accepted disposition coherent across summary, architecture, contracts, module maps, compatibility, tests, PPE, rollout, and decisions.
Use the `lark-doc` owner for all revision and block-update mechanics.
Reply to every addressed comment through the `lark-drive` owner with the evidence or accepted decision and a direct link to the changed block.
A reply should state what changed or why no change is correct, which evidence governs, and any remaining limit.
If the comment interface, permissions, or comment state prevents the required reply, leave the comment visibly unresolved and report the blocker rather than claiming it was addressed.
Do not resolve a thread before its document change and evidence reply have both been verified.

### Preserve unresolved review state

Keep unresolved comments visibly unresolved in Feishu and reflect their implementation consequence in the document's unresolved-decision section when appropriate.
Route genuine captain choices through `decision-hold-lifecycle` without copying its mechanics here.
When authority answers outside Feishu, durably route the decision, update the document, and reply in the original comment thread so chat does not become the only record a reviewer can see.
Do not replace a reviewer question with a speculative implementation answer merely to empty the comment queue.

### Verify comments and content together

Re-fetch every changed section from the resulting document revision.
Re-fetch the relevant comments and complete reply threads to confirm the reply landed on the intended comment and that solved or unresolved state is correct.
Re-run the whole-document conflict and terminology checks because comment-driven patches can leave stale claims in unreviewed sections.
Close an inventory row only when the current block, evidence reply, comment state, and dependent sections agree.
A review is coherent only when addressed comments point to verified content, unresolved comments remain visible, and no chat-only answer is required to understand the design.

## Genuine captain decisions

Evidence, accepted requirements, and existing ownership should resolve technical details whenever they leave only one implementation that satisfies the contract.
Do not manufacture a captain decision from naming anxiety, speculative future compatibility, or an implementation choice already forced by an invariant.
A genuine captain decision exists when multiple materially different product or architecture contracts remain valid after evidence is exhausted.

For each genuine decision:

- Assign a stable privacy-safe key.
- State the exact choice, evidence, options, consequences, recommendation, and dependent document sections.
- Keep unresolved language out of the decided architecture until authority answers.
- Follow `decision-hold-lifecycle` for durable routing when its trigger applies.

After the answer, update the invariant ledger and every dependent section in one revision sequence.
Remove stale option language, obsolete decision headings, contradictory tests, and superseded rollout claims.
Retain the chosen rationale only where future implementers need it to preserve the contract.
Verify the whole document and the durable decision record before treating the design or review as complete.

## Completion standard

An implementation-ready design is complete only when all of the following are true:

- The maintained document preserves the accepted template's information categories, hierarchy, order, and scope without checklist-driven boilerplate.
- A reader without prior subsystem context can understand the business intent, before and after behavior, important variants, and unchanged behavior.
- The document and every code source have exact immutable baselines refreshed immediately before writing, with implemented and proposed behavior distinguished.
- Product invariants, non-goals, and unsupported claims are explicit and consistent in the maintained document or private evidence according to the accepted scope.
- The conflict inventory is empty or contains only durably routed genuine decisions.
- Review-sized implementation units identify every material path, symbol, owner, call flow, edge and failure behavior, interaction, compatibility effect, and deliberately unchanged boundary.
- Frontend, backend, IDL, generated clients, and error semantics agree in code.
- Every schema, validation rule, compatibility transform, and identity has one named owner.
- Legacy behavior is handled at the lowest sufficient shared boundary with explicit failure semantics.
- Required automated tests and PPE scenarios are executable and prove observable outcomes and forbidden side effects, whether they live in the accepted document scope or the private task record.
- Required rollout, rollback, monitoring, decisions, and completion evidence express the same invariants as the architecture without forcing excluded categories into the maintained document.
- Complex Feishu visuals exist only where they reduce review cost, distinguish changed from unchanged owners, sit beside their explanatory prose, and have passed remote render inspection.
- Feishu content follows the concise Chinese outcome-first, compact-evidence, semantically visual, review-oriented presentation contract.
- Every addressed Feishu comment has a verified evidence reply and changed-block link, while every unresolved comment remains visible and durably routed when required.
- The final full-body and outline checks find no forbidden categories, retired terms, duplicate sections, stale conflicts, or unresolved decision language outside the durable decision inventory.
- The final revision preserves the intended canonical document identity and matches the exact refreshed code baselines.
