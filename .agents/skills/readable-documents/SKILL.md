---
name: readable-documents
description: >-
  Agent-only workflow for creating or materially revising reader-centered technical documents, including designs, solution studies, explanations, guides, tutorials, references, and reports.
  Use before drafting a substantial reader-facing technical document or repairing one that is hard to understand, too abstract, poorly structured, or missing clear examples or visuals.
user-invocable: false
metadata:
  internal: true
---

# Reader-centered technical documents

This skill owns the portable authoring workflow for technical documents that must be accurate and understandable to their intended readers.
It does not grant implementation, architecture expansion, publishing, sharing, or review authority.
The document format owner still owns API mechanics, revision preconditions, comments, and remote readback.
This file is the single normative authoring owner for both general readability and implementation-ready technical-design rigor; old skill names and references only redirect here.
For a Feishu document, load `lark-doc` before content operations, `lark-drive` before comment operations, and `lark-whiteboard` before independent whiteboard operations at their respective triggers.
Load `captain-hold-lifecycle` when its decision-routing or completion trigger applies.

## Establish the reader contract

Before drafting, record a short private reader contract:

- Who will read this, and what role and technical proximity can the document safely assume?
- What relevant knowledge do readers already have, and what knowledge gap must this document bridge?
- What question should readers be able to answer, decision should they be able to make, or task should they be able to perform afterward?
- What is in scope, out of scope, and prerequisite knowledge?

Use the request and available context rather than turning every document into an audience questionnaire.
Ask only when plausible audiences would require materially different documents.
Assume readers cannot see the author's chat, investigation history, hidden notes, or unstated decisions.
Match vocabulary to the audience, define unfamiliar terms and abbreviations at first use, and prefer plain culturally neutral language.

## Choose the document's job

Use the accepted template when one exists, preserving its information categories, hierarchy, order, and scope.
Otherwise choose a reading path by the document's primary job.
These are paths through the content, not mandatory headings.

| Document job | Reading path |
|---|---|
| Architecture or refactor proposal | Concrete scenario, current behavior, evidenced pain, smallest proposed change, same scenario afterward, contracts and exceptions |
| Explanation | Question, short answer, context, causal model, consequences and limits |
| How-to guide | Goal and prerequisites, one successful procedure with expected results, relevant failure and recovery branches, optional detail |
| Tutorial | Small working example, one new concept at a time, progressively richer examples |
| API or technical reference | Scope and lookup structure, exact parameters, types and behavior, minimal usage example, constraints and error semantics |
| Investigation or factual report | Question, answer and confidence, supporting evidence, limitations, consequence or necessary next decision |

Keep the primary job coherent.
When a document serves multiple jobs, separate the explanatory path from tutorial, procedure, or reference material instead of switching unpredictably between them.
Do not force architecture diagrams, before-and-after views, decision sections, or a fixed heading count onto a short guide, reference, explanation, or report.
Do not force a decision when the document's job is simply to convey knowledge.

## Build one through-line - 主线容易读懂

Give the reader one connected path from why the document matters to what changes for them.

1. Start with the current situation and the reader-visible outcome, not repositories, schemas, or author chronology.
2. State the concrete pain, gap, or question and the evidence that supports it.
3. Introduce the smallest change or explanation that resolves that pain.
4. Show the resulting behavior, consequence, or next action.
5. Add detailed contracts, variants, exceptions, and reference material only after the main path is understandable.

This through-line is a mandatory acceptance condition, not a stylistic preference.
From the body alone, the intended reader must be able to identify the problem or question, the conclusion, why a change or explanation is needed, and how one concrete example travels through current and proposed behavior or the analogous path for that document type.
Explain causes and transitions before detailed fields, responsibilities, interfaces, state, errors, and verification.
A document fails when chat context, a disconnected term list, or unexplained source knowledge is needed to infer how those facts relate.
Complete headings, polished formatting, successful remote readback, and an author or AI self-rating do not repair a missing through-line.

Use headings that name a reader goal, question, outcome, or decision rather than an unfamiliar tool or internal component.
Give each heading a brief orienting sentence before descending into subsections.
Keep one concept or task per outline unit and place information near the first place the reader needs it.
For a long document, use a navigable outline and progressively disclose detail from overview to focused sections.

## Carry one concrete example end to end

Choose one representative example that matches the request.
Label invented values as illustrative rather than evidence.
Trace its input or starting state, responsible actors or components, important actions, result, and relevant failure behavior.
For a proposed change, carry the same example through current and target behavior with comparable scope and steps so the responsibility shift is visible.
Explain the example in plain language before presenting type definitions, call inventories, configuration matrices, or exhaustive variants.
Use additional examples only when they reveal a materially different branch.

Every new component or concept should answer the applicable questions:

- What concrete problem does it solve?
- Who or what handles that responsibility now?
- Why can the current owner not continue unchanged, or why is no new owner needed?
- What are its inputs, outputs, callers, and relationships to existing concepts?
- What stays unchanged?

Do not invent a predecessor, failure, or architectural need merely to make the narrative flow.
Document complexity is not evidence that the system needs another class, framework, persisted field, table, or store.

### Compact contrast

Negative example:

> `RequestRouter`, `LeaseRow`, and `retry_generation` are introduced below.
> The interfaces, states, and tests are complete.

This is not understandable from the body because it never says what fails today, why the new concepts are needed, or how one request moves between them.

Positive example:

> Today, a retried request can be accepted by two workers because each checks availability before either records ownership.
> The proposal makes one compare-and-swap lease the acceptance boundary: for request `R17`, worker A records generation 4 and proceeds, while worker B observes that generation and declines.
> Routing and response formats stay unchanged; the later contract section specifies the lease fields, stale-owner recovery, and executable duplicate-acceptance test.

The positive example gives the problem, conclusion, necessity, transition, unchanged behavior, and a concrete before-and-after path before enumerating the detailed contract.

## Separate claims by epistemic status

Make factual status visible in prose, tables, code blocks, and diagrams.
Use stable labels appropriate to the document, such as `current`, `proposed`, `unchanged`, `illustrative`, `assumption`, `unknown`, and `needs evidence`.
Never blend implemented behavior with a proposal or present illustrative code as a compiled contract.

Distinguish these evidence classes:

- Authored explanation is the document's claim and can still be wrong or unclear.
- Source evidence, executable checks, and remote readback can verify facts, behavior, and whether content rendered as intended.
- An author or LLM standalone check can expose missing context, contradictions, or unusable navigation, but is only a proxy for comprehension.
- Actual reader feedback is the only evidence that a particular human understood the document or completed its intended task.

Do not claim that an LLM self-check, successful render, passing test, or lack of comments proves human understanding.
Mark unavailable, stale, permission-limited, or conflicting evidence explicitly rather than silently substituting a nearby source or guessing.
Keep command transcripts, investigation chronology, and proof-of-work narration in private evidence unless the document's job is to report that chronology.

## Use detail in proportion to the document type

A readable document is not necessarily short, and a complete document is not necessarily readable.
Include the technical detail needed for the reader's intended decision or task, then route secondary detail to later sections or existing references.
Keep material risks and decision-changing limitations in the main reading path.

For a design, satisfy the evidence, ownership, contract, compatibility, failure, and executable-verification requirements below within the accepted template.
For a how-to guide, make prerequisites, actions, expected results, and recovery executable without importing a design inventory.
For a tutorial, optimize for a safe learning sequence rather than exhaustive reference coverage.
For a reference, optimize for accurate lookup, stable organization, exact semantics, and minimal examples rather than a narrative journey.
For an explanation or report, make the answer, reasoning, evidence, assumptions, uncertainty, and consequence distinguishable.

## Make technical designs implementation-ready

Apply this section only to an implementation-ready technical design or reviewable technical-solution study.
Do not impose its full inventory on a guide, tutorial, reference, explanation, or factual report.

### Preserve the accepted review shape

Treat an accepted template's information categories, hierarchy, order, scope, review density, and presentation pattern as authoritative.
Preserve each section's purpose instead of merely retaining its heading text.
Do not add tests, rollout, monitoring, deployment, environment scenarios, completion checklists, or generic boilerplate when the accepted template excludes those categories.
Write product and requirement sections for a reader without prior subsystem context, then place code-level detail in review-sized units grouped by semantic owner or logical flow.
Retain required supporting evidence privately when it does not belong in the maintained document.

### Build evidence before prose

Record the live document identity and revision together with every relevant repository's canonical identity, default branch, and exact commit.
Pin generated artifacts, API declarations, dependency versions, SDKs, and runtime packages when they constrain the design.
Distinguish repository head from the exact revision another component consumes, implemented behavior from proposed behavior, and unavailable or stale evidence from verified evidence.
Use a compact baseline table when several sources constrain the design, and treat line numbers as revision-specific evidence while paths, symbols, and owning modules remain durable locators.

Trace each important behavior through its declaration or decoder, constructor, validator, caller, persistence boundary, execution path, recovery path, and user-visible adapter as applicable.
Inspect sibling paths and shared helpers that can bypass, duplicate, or reinterpret the proposed owner.
Treat comments, names, and types as hypotheses until call sites, state transitions, or observable behavior confirm them.

Translate requirements into testable invariants before choosing modules or APIs.
For each invariant, state the subject, allowed and forbidden behavior, identity or cardinality rule, failure consequence, and supporting authority.
Inventory conflicting summaries, diagrams, examples, contracts, module plans, risks, tests, rollout statements, decisions, and completion criteria; replace or delete contradictions, retain only with evidence, and route only genuine unresolved decisions.

### Specify review-sized owners and boundaries

For each relevant semantic owner or logical flow, identify exact paths and symbols, proven current behavior, changed and unchanged behavior, ownership, call flow, interactions, edge and failure behavior, recovery, compatibility effect, and executable evidence.
Do not substitute a file wishlist or phase plan for call-site and ownership reasoning.

Show cross-boundary contracts in the language each side consumes.
Include exact field names, types, optionality, repeated or set semantics, path bindings, serialization, response error semantics, and the order of create, edit, readback, retry, and failure where order affects side effects.
State behavior for unknown, malformed, unavailable, stale, partial, duplicate, and empty inputs when relevant, and make declarations, generated clients, adapters, conversion, and prose agree.

Assign every schema, product matrix, validation rule, identity, compatibility transform, persisted field, and derived response value one semantic owner.
Name its consumers and make preflight and final writes share the same rule owner while final writes remain authoritative.
Keep dynamic, cross-record, authorization, and external-eligibility checks at narrow authoritative boundaries, and state and verify the preflight side-effect boundary.

### Define compatibility and state only when present

Place compatibility at the lowest shared boundary that can transform data without loss.
Prefer a pure, deterministic, deep-copying, and idempotent conversion before upper layers fan out; preserve already canonical input, and return a contextual error rather than guessing when lossless conversion is impossible.
Do not write back, create a new version, infer provenance from shape, or expose a migration selector unless the accepted contract requires it.

When persistence or a state machine is in scope, specify:

- The exact writer trigger and intermediate events forbidden from writing.
- The authoritative evidence and treatment of retries, checkpoints, chunks, sessions, partial, stale, duplicate, and ambiguous input.
- The transaction or compare-and-swap boundary, operation order, no-op rule, and rollback behavior.
- Stable identities, generations, dedupe keys, cardinalities, and watermarks.
- Partial success, late evidence, corruption, overflow, retry, restart, migration, and repair behavior.
- Persisted values, response-only values, and the unique owner of each.

### Make verification executable

Specify tests through public or executable interfaces and observable behavior.
Cover each relevant invariant with positive, boundary, and disallowed cases, including alternate-entry bypasses.
Test ordering, idempotence, caller immutability, duplicate handling, exact logical cardinality, prohibited side effects, serialization, malformed input, timeout, and unavailable dependencies where they matter.
Do not use source grep, source snapshots, or abstract syntax tree shape as a substitute for behavior.

When environment scenarios, deployment, rollback, or monitoring are in accepted scope, derive them from the same invariants and compatibility boundaries.
State scenario preconditions, input, action, observable evidence, forbidden side effects, pass criteria, cleanup owner, and recovery path.
Use disposable external resources when a scenario mutates another system, and exclude credentials and high-cardinality business payloads from monitoring.
Separate automated claims from claims requiring environment or production observation.

Use code blocks only when exact syntax, types, optionality, cardinality, ordering, or error behavior matters.
Keep code and surrounding prose consistent and label code as current, proposed, or illustrative.
Prefer compact tables for repeated exact mappings and prose for a single causal path.

## Use diagrams when they answer a question faster

Keep a document in prose and tables when a diagram would add ceremony without clarity.
Before drawing, write the one-sentence takeaway or caption and name the review question the diagram must answer.
Show an overall view first, then add focused subsystem, sequence, state, transaction, or deployment views only when each answers a distinct question.
Constrain each diagram to one coherent message and split visual run-ons rather than shrinking text or compressing the whole system into one board.

For architecture diagrams:

- State the diagram type, scope, and abstraction level.
- Name and briefly describe every element and define unfamiliar abbreviations.
- Label every material relationship so its wording matches the arrow direction and intent.
- Explain shapes, line styles, icons, and colors with a legend, and never rely on color alone.
- Distinguish current, changed, unchanged, replaced, and new elements when that distinction matters.
- Compare before and after at the same scope, abstraction level, naming convention, and preferably layout.

Place each diagram beside the prose it supports.
Inspect the actual rendered deliverable at a useful reading size for clipping, overlap, legibility, arrow continuity, label accuracy, and missing content.
Local source validation does not replace remote or final-format inspection when the maintained artifact renders elsewhere.

## Draft, revise, and verify

Use this loop for material authoring and revision.

### Observe

Read the accepted template, current outline, target content, dependent sections, and relevant evidence.
For an existing document, identify current claims, duplicated owners, stale terms, contradictions, unresolved comments, and revision identity before editing.

### Diagnose

Name the earliest break in the reading path: missing background, undefined term, unsupported claim, lost causal step, unclear responsibility, incomparable before and after, misplaced detail, or inadequate visual.
Identify every dependent section, example, diagram, and summary affected by the correction.

### Patch

Change the smallest coherent unit that removes the defect everywhere it appears.
Prefer replacing, reordering, or deleting a stale explanation over appending a competing explanation.
Preserve the accepted template and the canonical document identity for an in-place revision.

### Verify

Read back the changed unit, then inspect the complete final body, outline, links, code blocks, tables, and rendered resources.
Search for retired terms, old decisions, opposite rules, duplicated owners, stale examples, and claims forbidden by the accepted scope.
For remote artifacts, verify the actual remote revision and render through the format owner's workflow.
On drift, partial success, or a revision conflict, re-observe before another write.

For comment-driven revision, read each relevant complete thread and track its stable identity, concern, governing evidence, disposition, dependent sections, reply state, and verification state privately.
Reply on the original thread only after verifying the changed content, and do not resolve an unanswered factual question or genuine decision merely because the prose or diagram improved.

## Standalone readability check

Use only the final reader-visible document to answer the questions appropriate to its job.
Record brief answers and their exact section, example, table, or figure locations in private evidence.
If an answer requires chat history, unexplained source-code knowledge, guessed relationships, or an undefined name, repair that specific gap.

For every document, first apply this body-only rubric:

1. Can the intended reader state the problem or question and the conclusion?
2. Can the reader explain why the change, procedure, or explanation is needed?
3. Can the reader follow one concrete example from its starting state through the important causes and transitions to its outcome?
4. Are current, proposed, and unchanged behavior distinguishable where those categories exist?
5. Do detailed fields, responsibilities, interfaces, state, errors, and verification appear only after the body has explained why they matter?
6. Can every answer cite the body itself without chat context, a disconnected glossary, or guessed relationships?

Any `no` fails the readability check and requires a focused repair before completion.
Headings, formatting, remote readback, and author or AI scoring are evidence about structure or rendering, not substitutes for these answers.

For a proposal or refactor, additionally check:

1. How does the current system handle the representative example?
2. What evidenced pain requires a change?
3. What responsibility or behavior changes, and how does the same example work afterward?
4. What remains unchanged?
5. Why is each new component or storage change necessary, or why is none needed?

For a how-to guide or tutorial, check the goal, prerequisites, executable steps, expected results, and relevant recovery.
For a reference, check whether the intended lookup questions have unambiguous answers and usable examples.
For an explanation or report, check whether the answer, evidence, assumptions, uncertainty, and consequence are distinguishable.

This is an authoring check, not evidence of real reader comprehension.
When actual reader feedback identifies a gap, reopen the earliest failed link and repair the content and dependent visuals coherently.

## Completion standard

Complete only when the applicable statements are true:

- The reader contract and the document's primary job are clear.
- The document has a connected path from current situation or question through evidence to outcome, change, or action.
- The body-only rubric passes, including an explicit problem, conclusion, necessity, and end-to-end example or analogous explanation without hidden context.
- One representative example grounds the main path, with comparable before and after behavior when the document proposes change.
- Detail is progressively disclosed and proportionate to the document type.
- Facts, proposals, assumptions, examples, unknowns, and evidence limits are distinguishable.
- The accepted template is preserved without checklist-driven sections or a forced heading count.
- Every retained diagram answers one question and passes inspection in the actual rendered artifact.
- The standalone readability check has document-based answers, without being misreported as human review.
- Factual and executable checks required by the document type pass independently of the readability check.
- The final body, outline, links, resources, revision identity, and remote render are verified where relevant.
- Actual comprehension feedback is reported only when an actual reader supplied it.
- For a technical design, every applicable evidence, owner, boundary, compatibility, state, failure, recovery, and executable-verification requirement above is satisfied, while irrelevant categories are omitted.
- For a technical design, its baselines, invariant ledger, one-owner map, conflict inventory, contracts, examples, diagrams, and completion claims agree, with any genuine unresolved choice still visible and durably routed.

## Sources

These sources inform the portable writing practices above but do not replace task evidence or prove comprehension.

- [Google Technical Writing: Audience](https://developers.google.com/tech-writing/one/audience) supports defining reader roles and proximity, identifying what readers must learn, matching vocabulary, and guarding against assumed knowledge.
- [Google Technical Writing: Organizing large documents](https://developers.google.com/tech-writing/two/large-docs) supports outlines, scope and prerequisites, task-oriented navigation, introducing concepts where needed, and progressive disclosure from simple examples.
- [Google Technical Writing: Illustrating](https://developers.google.com/tech-writing/two/illustrations) supports takeaway-first captions, limited information per figure, overview-to-detail visuals, attention cues, and rendered visual revision.
- [Diátaxis](https://www.diataxis.fr/start-here/) contributes the distinct separation among tutorials, how-to guides, reference, and explanation according to reader need.
- [C4 diagram review checklist](https://c4model.com/diagrams/checklist) contributes the distinct architecture-diagram checks for title, type, scope, legend, element meaning, and labeled directional relationships.
