---
name: consult
audience: swarm-plugin
description: >
  Full execution protocol for MODE: CONSULT -- answering advisory questions with bounded evidence and clear uncertainty.
---

# Consult Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

### MODE: CONSULT
Check .swarm/context.md for cached guidance first.
Identify 1-3 relevant domains from the task requirements.
Call the active swarm's sme agent once per domain, serially. Max 3 SME calls per project phase.
Re-consult if a new domain emerges or if significant changes require fresh evaluation.
Cache guidance in context.md.

### Read-before-cite discipline

SME consultation answers are advisory. When the SME (or any agent synthesizing the final answer) cites source code, file paths, line ranges, API behavior, or CLI flags, it MUST read the actual file or tool output in the current revision. Specific anti-patterns to refuse:

- Quoting `src/foo.ts:123-145` without reading those lines.
- Restating an API signature from earlier conversation history after the source has been edited.
- Citing behavior from documentation that pre-dates the current version.

For uncertain claims, the SME must mark `confidence: LOW` and identify what additional evidence (a specific file read, a test run, a docs check) would resolve the uncertainty. Do NOT report `confidence: HIGH` for claims that could not be verified against current source this turn.
