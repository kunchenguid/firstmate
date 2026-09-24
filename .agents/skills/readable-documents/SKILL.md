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
For an implementation-ready technical design or technical-solution study, also load [`references/technical-designs.md`](references/technical-designs.md) before investigating or drafting.
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

## Build one through-line

Give the reader one connected path from why the document matters to what changes for them.

1. Start with the current situation and the reader-visible outcome, not repositories, schemas, or author chronology.
2. State the concrete pain, gap, or question and the evidence that supports it.
3. Introduce the smallest change or explanation that resolves that pain.
4. Show the resulting behavior, consequence, or next action.
5. Add detailed contracts, variants, exceptions, and reference material only after the main path is understandable.

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

For a design, load the technical-design reference and satisfy its evidence, ownership, contract, compatibility, failure, and executable-verification requirements within the accepted template.
For a how-to guide, make prerequisites, actions, expected results, and recovery executable without importing a design inventory.
For a tutorial, optimize for a safe learning sequence rather than exhaustive reference coverage.
For a reference, optimize for accurate lookup, stable organization, exact semantics, and minimal examples rather than a narrative journey.
For an explanation or report, make the answer, reasoning, evidence, assumptions, uncertainty, and consequence distinguishable.

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

## Standalone readability check

Use only the final reader-visible document to answer the questions appropriate to its job.
Record brief answers and their exact section, example, table, or figure locations in private evidence.
If an answer requires chat history, unexplained source-code knowledge, guessed relationships, or an undefined name, repair that specific gap.

For a proposal or refactor, check:

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
- One representative example grounds the main path, with comparable before and after behavior when the document proposes change.
- Detail is progressively disclosed and proportionate to the document type.
- Facts, proposals, assumptions, examples, unknowns, and evidence limits are distinguishable.
- The accepted template is preserved without checklist-driven sections or a forced heading count.
- Every retained diagram answers one question and passes inspection in the actual rendered artifact.
- The standalone readability check has document-based answers, without being misreported as human review.
- Factual and executable checks required by the document type pass independently of the readability check.
- The final body, outline, links, resources, revision identity, and remote render are verified where relevant.
- Actual comprehension feedback is reported only when an actual reader supplied it.

## Sources

These sources inform the portable writing practices above but do not replace task evidence or prove comprehension.

- [Google Technical Writing: Audience](https://developers.google.com/tech-writing/one/audience) supports defining reader roles and proximity, identifying what readers must learn, matching vocabulary, and guarding against assumed knowledge.
- [Google Technical Writing: Organizing large documents](https://developers.google.com/tech-writing/two/large-docs) supports outlines, scope and prerequisites, task-oriented navigation, introducing concepts where needed, and progressive disclosure from simple examples.
- [Google Technical Writing: Illustrating](https://developers.google.com/tech-writing/two/illustrations) supports takeaway-first captions, limited information per figure, overview-to-detail visuals, attention cues, and rendered visual revision.
- [Diátaxis](https://www.diataxis.fr/start-here/) contributes the distinct separation among tutorials, how-to guides, reference, and explanation according to reader need.
- [C4 diagram review checklist](https://c4model.com/diagrams/checklist) contributes the distinct architecture-diagram checks for title, type, scope, legend, element meaning, and labeled directional relationships.
