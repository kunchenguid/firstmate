---
name: agent-skill-trigger-index
description: Load only when auditing or maintaining the complete agent-only skill trigger index.
user-invocable: false
metadata:
  internal: true
---

# Agent-only reference skills

This directory links to canonical internal agent-only skills; each skill's frontmatter description owns its load trigger.
The index itself, the `decision-hold-lifecycle` compatibility redirect, and user-invocable skills are excluded from membership.
`bin/fm-doc-audience-check.sh` checks this directory against tracked skill metadata; it does not judge trigger wording.

- [operational-home-layout](../operational-home-layout/SKILL.md)
- [session-start-recovery](../session-start-recovery/SKILL.md)
- [bootstrap-diagnostics](../bootstrap-diagnostics/SKILL.md)
- [diagnostic-reasoning](../diagnostic-reasoning/SKILL.md)
- [ask-user-authority](../ask-user-authority/SKILL.md)
- [validation-supervision](../validation-supervision/SKILL.md)
- [ship-landing](../ship-landing/SKILL.md)
- [scout-completion](../scout-completion/SKILL.md)
- [quota-array-dispatch](../quota-array-dispatch/SKILL.md)
- [harness-adapters](../harness-adapters/SKILL.md)
- [firstmate-orca](../firstmate-orca/SKILL.md)
- [project-management](../project-management/SKILL.md)
- [stuck-crewmate-recovery](../stuck-crewmate-recovery/SKILL.md)
- [secondmate-provisioning](../secondmate-provisioning/SKILL.md)
- [captain-hold-lifecycle](../captain-hold-lifecycle/SKILL.md)
- [away-quiet-supervision](../away-quiet-supervision/SKILL.md)
- [process-event-sources](../process-event-sources/SKILL.md)
- [fmx-respond](../fmx-respond/SKILL.md)
- [firstmate-codexapp](../firstmate-codexapp/SKILL.md)
- [firstmate-coding-guidelines](../firstmate-coding-guidelines/SKILL.md)
