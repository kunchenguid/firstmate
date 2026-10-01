# Documentation audiences

[`documentation-audiences.json`](documentation-audiences.json) is the machine-consumed classification owner for every maintained prose surface.
`bin/fm-doc-audience-check.sh` validates exact inventory coverage, README setup routing, required owner pointers, local link targets, and always-loaded byte ceilings.
Audience metadata is centralized there rather than copied into front matter on every page.

The audience classes have one placement purpose each:

- `public-product` introduces the product or provides standalone public material.
- `operator-current` explains current behavior, setup, supported limits, stable invariants, concise rationale, and current verification entry points.
- `operator-example` is copyable current setup material.
- `maintainer-architecture` explains stable ownership, extension points, mechanism boundaries, and safety rationale for contributors.
- `maintainer-verification` records repeatable evidence for an active guarantee and may include dates, versions, exact commands, and exact output.
- `agent-runtime` is loaded or rendered as an operating contract for Firstmate agents rather than read as product documentation.

The knowledge-placement policy is owned by [`firstmate-coding-guidelines`](../.agents/skills/firstmate-coding-guidelines/SKILL.md).
Task-specific chronology, delivery transcripts, temporary paths, branches, failed hypotheses, and one-off process identifiers stay in private task reports or PR evidence by default.
Before removing that evidence from a tracked page, distill every unique current fact into its classified owner and retain a focused regression pointer.

Run the structural check directly with:

```sh
bin/fm-doc-audience-check.sh
```

The check intentionally does not lint dates, versions, commands, paths, incident language, or transcript-like prose.
Those forms are legitimate in maintainer verification and require semantic review rather than keyword heuristics.
For every changed prose surface, review its audience, authoritative owner, current relevance, evidence destination, and unique safety facts, then repeat that review over the complete branch diff after all fixes.

## Always-loaded byte ceilings

The inventory's `alwaysLoadedByteBudgets` caps the byte size of an always-loaded agent contract, and the check fails naming the size, the ceiling, and the remediation.
`AGENTS.md` is capped at 45,000 bytes, which the startup-memory estimate `ceil(UTF-8 bytes / 3)` ([`configuration.md`](configuration.md#startup-memory-budget-configstartup-memory-budget)) puts at 15,000 tokens: twice the default 7,500-token budget for the three startup memory files combined.
Every primary, secondmate, and firstmate-repo worker session pays that contract in full, so it gets a fixed multiple of the memory budget rather than an unbounded allowance.
Whether a firstmate-repo worker could skip that load while primaries and secondmates keep it was investigated and deferred: root `AGENTS.md` is how every supervisor harness currently finds its contract, and no per-harness loading path has been shown safe to separate yet, so treat that boundary as unverified rather than settled.
The ceiling leaves little headroom on purpose: an addition beyond a few lines is paid for by moving conditional detail out under the knowledge-placement tree in [`firstmate-coding-guidelines`](../.agents/skills/firstmate-coding-guidelines/SKILL.md), not by raising the number.
Raise a ceiling only with a stated reason in the same change.
