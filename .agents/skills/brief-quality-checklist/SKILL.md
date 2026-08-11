---
name: brief-quality-checklist
description: >-
  Agent-only checklist for a crewmate brief's task-specific content: objective, constraints, validation, stop condition, documentation, and an anti-reward-hacking clause.
  Load before finalizing a brief's `# Task` section, alongside `bin/fm-brief.sh`'s scaffold.
user-invocable: false
metadata:
  internal: true
---

# brief-quality-checklist

A short quality check for the task-specific content that goes into a crewmate brief - not a replacement for `bin/fm-brief.sh`, which alone owns the scaffold's structure, status protocol, delivery-mode definitions of done, and safety mechanics.
Use this only to sanity-check that the `# Task` section states its work clearly enough that the crewmate does not have to guess.

## The 5-part contract

Every brief's task description should give the crewmate all five of these, explicitly:

1. **Objective** - one sentence, one concrete outcome.
2. **Constraints** - what must NOT change: public interfaces, files, libraries, conventions, out-of-scope adjacent work.
3. **Validation** - the exact check that proves progress. In this fleet that is normally the selected delivery path's own pipeline (`no-mistakes`, direct-PR checks, or the project's existing test command) rather than a bespoke command invented per task.
4. **Stop condition** - verifiable: "done when X passes," or "when further changes need a captain decision" (an ask-user finding, per section 7's classification).
5. **Documentation** - one sentence on keeping any touched documentation accurate for the change, per the target project's own `AGENTS.md`, or `firstmate-coding-guidelines` when the target is firstmate's own repo.

A brief silent on any of the five is under-specified; add the missing piece rather than leaving it implicit.

## Anti-reward-hacking clause

For any task with a pass/fail validation gate, state explicitly: do not delete, skip, weaken, or narrow tests or checks to make the gate pass.
Without this line, a crewmate under time or difficulty pressure can game the stop condition instead of meeting it.

## Scope note

This is a content checklist, not a new brief format or feature.
It does not authorize a `/goal`-style persistent autonomous loop - firstmate has no such feature - and it never modifies `bin/fm-brief.sh`'s scaffold logic; that script remains the single owner of brief mechanics.
