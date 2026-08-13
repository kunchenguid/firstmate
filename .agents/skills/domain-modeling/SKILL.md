---
name: domain-modeling
metadata:
  internal: true
description: >-
  Build and sharpen a project's domain model.
  Use when the user wants to pin down domain terminology or a ubiquitous language, record an architectural decision, or when another skill needs to maintain the domain model.
---

Before applying this vendored skill inside Firstmate, read [`VENDORED-ENGINEERING-CONTRACT.md`](../VENDORED-ENGINEERING-CONTRACT.md).

# Domain Modeling

Actively build and sharpen the project's domain model as you design.
This is the *active* discipline - challenging terms, inventing edge-case scenarios, and writing the glossary and decisions down the moment they crystallise.
Merely *reading* `CONTEXT.md` for vocabulary is not this skill; that is a one-line habit any skill can do.
Use this skill when changing the model, not merely consuming it.

## File structure

Most repos have a single context:

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

If a `CONTEXT-MAP.md` exists at the root, the repo has multiple contexts.
The map points to where each one lives:

```
/
├── CONTEXT-MAP.md
├── docs/
│   └── adr/                          ← system-wide decisions
├── src/
│   ├── ordering/
│   │   ├── CONTEXT.md
│   │   └── docs/adr/                 ← context-specific decisions
│   └── billing/
│       ├── CONTEXT.md
│       └── docs/adr/
```

Create files lazily - only when you have something to write.
If no `CONTEXT.md` exists, create one when the first term is resolved.
If no `docs/adr/` exists, create it when the first ADR is needed.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `CONTEXT.md`, call it out immediately.
For example: "Your glossary defines 'cancellation' as X, but you seem to mean Y - which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term.
For example: "You're saying 'account' - do you mean the Customer or the User?
Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios.
Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees.
If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible - which is right?"

### Update CONTEXT.md inline

When a term is resolved, update `CONTEXT.md` right there.
Don't batch these up - capture them as they happen.
Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

`CONTEXT.md` should be totally devoid of implementation details.
Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions.
It is a glossary and nothing else.

### Offer ADRs sparingly

Apply the three-condition decision test owned by [ADR-FORMAT.md](./ADR-FORMAT.md).
If any condition is missing, skip the ADR.
