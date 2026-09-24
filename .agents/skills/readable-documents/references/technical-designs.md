# Implementation-ready technical designs

Load this reference only for an implementation-ready technical design or reviewable technical-solution study.
It adds design-specific evidence and implementation rigor to the reader-centered workflow in [`../SKILL.md`](../SKILL.md).
It does not impose a fixed six-heading structure or heavyweight design inventory on other document types.

## Preserve the accepted review shape

Treat an accepted template's information categories, hierarchy, order, scope, review density, and presentation pattern as authoritative.
Preserve each section's purpose instead of merely retaining its heading text.
Do not add tests, rollout, monitoring, deployment, PPE or BOE, completion checklists, or generic boilerplate when the accepted template excludes those categories.
Retain required supporting evidence privately when it does not belong in the maintained document.

Write product and requirement sections for a reader without prior subsystem context.
Explain business intent, current and target user-visible behavior, important variants, unchanged behavior, and non-goals before repository paths, symbols, schemas, persistence mechanics, or internal call order.
Place implementation detail under the template's code-level section in review-sized units grouped by semantic owner or logical flow.
For a Feishu technical design, write concise Chinese unless the requested review audience requires another language.
Use native Feishu whiteboards for retained diagrams rather than inline diagram text, and follow the parent skill's rendered-artifact verification.

## Build the evidence pack before prose

### Exact baselines

Record document identity and revision together with every relevant repository's canonical identity, default branch, and exact commit.
Pin generated artifacts, API declarations, dependency versions, SDKs, and runtime packages when they constrain the design.
Distinguish repository head from the exact revision another component consumes, and distinguish implemented behavior from proposed behavior.
Refresh volatile baselines immediately before relying on them.
Mark unavailable, stale, permission-limited, or intentionally older evidence explicitly.

Use a compact baseline table naming each source, immutable revision, relevance, and dependent claims.
Treat line numbers as revision-specific evidence while paths, symbols, and owner modules remain the durable locator.

### Executable-path evidence

Trace each important behavior through its declaration or decoder, constructor, validator, caller, persistence boundary, execution path, recovery path, and user-visible adapter as applicable.
Inspect sibling paths and shared helpers that can bypass, duplicate, or reinterpret the proposed owner.
Inspect history or an accepted base when current behavior may be a migration artifact.
Treat comments, names, and types as hypotheses until call sites, state transitions, or observable behavior confirm them.

### Invariant ledger and conflict inventory

Translate requirements into testable invariants before choosing modules or APIs.
For each invariant, state the subject, allowed and forbidden behavior, identity or cardinality rule, failure consequence, and supporting authority.
Record non-goals and unsupported claims beside the invariants so they do not re-enter through tests, monitoring, rollout, or compatibility prose.

Inventory every summary, diagram, example, contract, module plan, risk, test, rollout statement, decision, and completion criterion that conflicts with an accepted invariant or evidence baseline.
Classify each conflict as a contradiction, unsupported assertion, stale baseline, duplicated owner, incomplete downstream update, or genuine unresolved decision.
Give it a disposition of replace, delete, retain with evidence, or route as a decision.
A correct new section does not resolve contradictory content elsewhere.

## Make implementation units reviewable

For each semantic owner or logical flow, identify exact paths and symbols, proven current behavior, proposed or implemented changed behavior, unchanged boundaries, ownership, call flow, interactions, edge and failure behavior, recovery, compatibility effect, and executable evidence.
Include generated clients only when they participate in the delivery chain.
Do not substitute a file wishlist or phase plan for call-site and ownership reasoning.

### Boundary contracts

Show cross-boundary contracts in the language each side consumes.
Include exact field names, types, optionality, repeated or set semantics, path bindings, serialization, and response error semantics.
Show how transport values become domain values and where validation and final mutation occur.
Show create, edit, readback, retry, and failure ordering when order affects side effects.
State behavior for unknown, malformed, unavailable, stale, partial, duplicate, and empty inputs as applicable.
Make IDL, generated clients, frontend adapters, backend conversion, and surrounding prose agree.

### One semantic owner

Assign every schema, product matrix, validation rule, identity, compatibility transform, persisted field, and derived response value one semantic owner.
List the consumers that must call or derive from that owner instead of maintaining copies.
Keep dynamic, cross-record, authorization, and external-eligibility checks in narrow authoritative boundaries rather than pretending a static schema owns them.
Make preflight and final writes call the same owner for shared rules, while final writes remain authoritative.
State the preflight side-effect boundary and prove prohibited mutations through observable checks.

### Compatibility and persistent state

Place compatibility at the lowest shared boundary with enough context to transform data without loss.
Prefer a pure, deterministic, deep-copying, and idempotent conversion before upper layers fan out.
Preserve already canonical input when identity compatibility requires it.
Do not write back, create a new version, infer provenance from shape, or expose a migration selector unless the accepted contract requires it.
Return a contextual error rather than dropping fields or guessing when lossless conversion is impossible.

When the design includes persistence or a state machine, specify:

- The exact writer trigger and intermediate events forbidden from writing.
- The authoritative evidence and treatment of retry, checkpoint, chunk, session, partial, stale, duplicate, and ambiguous input.
- The transaction or compare-and-swap boundary, operation order, no-op rule, and rollback behavior.
- Stable identities, generations, dedupe keys, cardinalities, and watermarks.
- Partial success, late evidence, corruption, overflow, retry, restart, migration, and repair behavior.
- Persisted values, response-only values, and the unique owner of each.

## Build executable evidence into the design

Specify tests through public or executable interfaces and observable behavior.
Cover every invariant with positive, boundary, and disallowed cases, including alternate-entry bypasses.
Test ordering, idempotence, caller immutability, duplicate handling, exact logical cardinality, prohibited side effects, serialization, malformed input, timeout, and unavailable dependencies where they matter.
Exercise the real generated or typed consumer when feasible.
Do not use source grep, source snapshots, or AST shape as a substitute for behavior.

Write PPE scenarios as reproducible decisions when the accepted scope requires them.
Name preconditions, input, action, observable evidence, forbidden side effects, pass criteria, cleanup owner, and recovery path.
Use disposable external resources when a scenario mutates another system, and exclude credentials and high-cardinality business payloads from monitoring.
Separate automation claims from claims requiring PPE, production observation, or another owner.
Derive deployment order, rollback constraints, and monitoring from the same invariants and data-compatibility boundaries as the design.

## Revise without drift

Use the parent skill's Observe-Diagnose-Patch-Verify loop until the conflict inventory is empty.
After every material correction, verify consequences across summary, architecture, diagrams, wire contracts, module maps, compatibility, tests, PPE, monitoring, rollout, decisions, and completion criteria where those categories are in scope.
Preserve genuine unresolved choices in the accepted decision location and route them through `captain-hold-lifecycle` when its trigger applies.
Do not manufacture a decision from naming anxiety or a technical choice already forced by evidence and invariants.

For Feishu comment review, read the current document revision and every relevant complete comment thread before editing.
Track each comment's stable identity, current location or location confidence, concern, governing invariant, evidence, disposition, dependent sections, reply state, and verification state privately.
Reply on the original thread with the verified content location and evidence, and do not resolve a thread until both the document change and reply are verified.
Keep unanswered factual questions and genuine decisions visibly unresolved.

## Design completion standard

In addition to the parent skill's completion standard, complete only when the applicable statements are true:

- Exact document, code, generated-artifact, and dependency baselines distinguish current behavior, proposed behavior, and evidence gaps.
- The invariant ledger and one-owner map agree with every in-scope section and diagram.
- The conflict inventory is empty or contains only durably routed genuine decisions.
- Review-sized implementation units identify material owners, paths, symbols, calls, boundaries, interactions, failure and recovery, compatibility, and unchanged scope.
- Cross-boundary code and prose agree on types, optionality, cardinality, ordering, and error semantics.
- Persistence and state models define triggers, evidence, transaction boundaries, identities, failure recovery, and persisted-versus-response ownership.
- Automated tests and environment scenarios prove observable outcomes and forbidden side effects at the appropriate evidence layer.
- Rollout, rollback, monitoring, decisions, and completion criteria express the same invariants where the accepted scope includes them.
- Every addressed comment points to verified current content, and every unresolved comment remains visible.
