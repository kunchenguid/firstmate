---
name: align-intake
description: Align intention before every new request, and handle alignment validation diagnostics.
user-invocable: false
metadata:
  internal: true
---

# Alignment intake

Load before interpreting a new request as implementation authority, and on `ALIGNMENT:` diagnostics.
The loop is discuss -> record spec -> approve plan -> implement -> validate -> capture memory.
Existing merge authority and safety boundaries remain unchanged.
Project work uses the registered project alignment second mate for discussion, specification, and planning; if none exists, ask about provisioning rather than silently creating one or dispatching implementation.
No-project work uses the main session or an explicitly commissioned temporary scout.
The owning home keeps the records; skills are shared, not specific to a mate.

## Gate

Default to discussion, not dispatch.
A fast-lane candidate must meet ALL of these deterministic criteria: one explicit bounded operation, exactly one unambiguous target, no unresolved choice or missing acceptance condition, known reversible effect, and no change to external behavior or accepted scope.
Always discuss destructive or irreversible operations, security or credential changes, migrations, product/design choices, external commitments, and requests with competing interpretations.
A simple question answered by existing evidence is not an implementation commission.
For an eligible candidate call `bin/fm-align-decide.sh` on the request file; its header owns the typed-decision wire format and command mechanics.
Only a confident `fast` result permits the fast lane when that optional check is enabled; uncertain, malformed, failed, or discussion results require discussion.
`off` leaves the deterministic gate unchanged and makes no network call, matching typed dispatch resolution's opt-in semantics.
The fast lane abbreviates discussion and approval using the explicit bounded instruction itself, not the linked records or existing safety checks.
Record the deterministic criteria and the typed result in the spec before dispatch.

## Discussion discipline

Reflect the intended outcome, scope boundary, and strongest uncertainty before proposing work.
Ask one focused question at a time; probe assumptions, alternatives, tradeoffs, and what success looks like without inventing requirements.
Separate the actual request from implementation advice.
Summarize settled choices and unresolved points and obtain explicit intent alignment before planning.
Capture the actual answer, date, authority, rationale, and consequence as a stable D-number in the spec.
Use the existing captain-hold lifecycle for unresolved keyed calls; cite their exact keys in the decision entry rather than inventing a parallel decision system.
A changed intention revises the spec and requires renewed alignment, not silent plan expansion.

## Records and routing

Use `bin/fm-alignment.sh` to scaffold, link, record delivery evidence, and archive; its header owns syntax and the validator-consumed format.
Use the generated spec template in this skill directory and the plan template owned by plan-breakdown.
All records live under the owning home's `data/alignments/<key>/`, indexed by `index.md`, with completed records under dated `archive/` directories.
Never reuse a key or leave loose specifications in `data/`.
The stable key survives archival and links both directions: spec to plan and work items, work-item body and brief `alignment: <key>`, PR description `spec: <key>`, and memory `source: alignment <key>`.
Resolve links by key through the index, not by a remembered active-folder path.

| Information | Owner |
| --- | --- |
| Verbatim ask, aligned intent, scope, decisions, validation | Alignment spec |
| Approved units, guardrails, dependencies, risks | Alignment plan |
| Execution and completion | Existing backlog item, linked from spec |
| Unresolved approvals | Existing captain-hold records, cited in spec |
| Reusable preferences or learnings | Existing memory owner, with source citation |
| Implementation and checks | Task evidence and PR, with spec citation |

## Completion

Run the validator before dispatch and when diagnosing startup warnings.
Repair broken records without manufacturing approvals or completion evidence.
Completion is pointer-scoped: historical unlinked tasks pass unchanged.
A linked task needs its own delivery evidence; a shared alignment remains active until every linked task has evidence.
Only then archive before the last task completes.
PR deliveries record their landed URL, scouts their retained report, and local-only deliveries their local landing commit.
These documentary checks never substitute for the existing landed-work, report, approval, or discard guards.
Capture reusable knowledge through the existing memory owners with the source citation before closing the loop.
