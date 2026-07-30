# Documentation audiences

[`documentation-audiences.json`](documentation-audiences.json) is the machine-consumed classification owner for every maintained prose surface.
`bin/fm-doc-audience-check.sh` validates exact inventory coverage, README setup routing, required owner pointers, and local link targets.
Audience metadata is centralized there rather than copied into front matter on every page.

Every surface declares three required fields, and the check refuses a surface that omits any of them rather than defaulting one:

- `audience` - who reads it, from the classes below.
- `injection` - how it reaches a reader: `always` (in context at every session with no action), `lazy` (loaded at a named trigger), `generated` (reaches a reader only through a renderer), `referenced` (cited and read on demand), or `never` (never loaded into an agent session).
- `responsibility` - the single sentence this surface uniquely owns.

The one-sentence limit on `responsibility` is the enforcement, not a style preference: a surface that needs two sentences owns too much, and the fix is to split the document rather than widen the field.
Because `injection` is declared per surface, the always-loaded set is a queryable list instead of a claim, so growth in it is visible in review.

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
