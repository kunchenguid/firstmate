---
name: c4-modeling
description: >-
  Create or audit C4 software architecture models, including system context,
  container, component, deployment and dynamic views, grounded in source and
  explicit current/target states. Use for a requested C4 model or when a software
  architecture explanation needs consistent zoom levels and ownership boundaries.
  Do not apply to generic flowcharts, organizational charts or UI mockups.
metadata:
  internal: true
---

# C4 modeling

Produce a coherent architecture model expressed through the few views that answer the user's questions.
C4 defines the abstractions; a drawing format alone does not establish conformance.
Read [sources.md](references/sources.md) for official definitions and verify current guidance when requested or when uncertain.

## Establish the model

Identify the system of interest, audience, evidence revision/date, requested views and state: implemented, observed running, target or hypothesis.
Inspect source, contracts and runtime configuration read-only within the task's authority.
Distinguish a documented intention from source implementation, a test fixture, and a live deployment.
Preserve material unknowns rather than turning missing evidence into either success or failure.
Keep a compact element/relationship inventory with stable IDs, type, parent, responsibility, technology, ownership/trust boundary, evidence and state.
Do not infer deployment, migration or acceptance authority from a request for diagrams.

## Choose views and maintain scope

- Level 1: one software system with directly related people and external software systems; leave technical internals out.
- Level 2: that system's applications and data stores, with their protocols and external dependencies.
  A C4 container is a runtime/storage boundary, not automatically a Docker container, repository or package.
  An owned database schema or bucket is inside the logical system even when externally hosted.
  Embedded SDKs belong inside their host application; separately running clients/workers are containers.
- Level 3: components in one named container, plus directly related containers/people/systems as context.
  Components group functionality behind interfaces and share the container's process/deployment boundary; they are not automatically individual classes or folders.
- Deployment: instances mapped to named execution nodes in one explicit environment per view; show network and infrastructure boundaries here.
- Dynamic: reuse static-model elements at a consistent chosen level; number interactions for a concrete scenario and show consequential refusal/retry paths.
  Sequence notation is acceptable.

Usually begin with context and containers.
Add component, dynamic or deployment views when they answer a specific question or the user asks for them.
Do not require all four zoom levels or invent a Level 4 diagram to fill a template.
Keep current and target views separate when the difference changes structure or ownership.
If a future element appears in a current view for orientation, label it future and make its relationships visibly distinct in the key.
Avoid implying dual writers during a migration unless that is an evidenced design.

## Author and validate

Use the user's notation; otherwise choose available portable text notation such as Mermaid, PlantUML or Structurizr.
Use [templates.md](references/templates.md) when starting a view.
Every view needs a title including type/scope/state, named and typed elements with brief responsibilities, boundaries, directional action labels, relevant technologies/protocols and a self-contained key.
Explain abbreviations and any shape, color, border or line semantics; do not rely on color alone.

Cross-check that the same ID/name retains its role across zoom levels and that dynamic participants/relationships exist in the static model.
Separate logical ownership, runtime trust, and physical deployment boundaries instead of using one enclosure for all three without explanation.
State source evidence and uncertainty beside each view or in a keyed evidence table.

Parse or render every delivered text source with a real tool and record its version, exact command and outcome.
If images are delivered, also inspect their layout, labels, clipping and readability; a parser pass is not visual QA.
If only parsing is available, explicitly say that layout was not verified.
Use an existing approved renderer rather than building a new diagram tool.
Fix failures before claiming validation; if unavailable, report the limitation without inventing a pass.

## Deliver

Return the requested report or diagrams, portable sources, evidence/state limits and validation receipt.
An architecture report may compose with an existing document skill; rendering may compose with an existing diagram skill.
Neither dependency is mandatory if absent, and no new deployment/review/approval process is implied.
When an acceptance plan is requested, name exact actor actions and observable outcomes, and distinguish product rollback, data recovery, binary/schema rollback and routing reversal.
Do not claim a product accepted because its diagram renders.
Use [smoke-tests.md](references/smoke-tests.md) to evaluate substantial skill changes.
