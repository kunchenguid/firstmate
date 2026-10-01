---
name: design-docs
audience: swarm-plugin
description: >
  Full execution protocol for MODE: DESIGN_DOCS — generate or sync structured,
  language-agnostic design docs (domain.md, technical-spec.md, behavior-spec.md,
  reference/) for the project under build, with a stable section-ID registry and
  a design changelog. Loaded on demand by the architect when the design-docs
  command emits a [MODE: DESIGN_DOCS ...] signal (issue #1080).
---

# Design-Doc Generation & Sync Protocol

Generate or maintain the project's structured design documentation. The work is delegated to the `docs_design` agent (a design-doc-author role variant of the docs agent). This mode authors a fixed set of version-controlled docs in the **target project repo** (NOT under `.swarm/`). It does NOT modify source code, does NOT call `declare_scope`, and does NOT touch `.swarm/spec.md`, `CHANGELOG.md`, or `docs/releases/pending/*`.

### MODE: DESIGN_DOCS

## Step 0 — Parse Header

Parse the `[MODE: DESIGN_DOCS ...]` header to extract:
- `out`: output directory, project-relative (default `docs`)
- `lang`: target language for `reference/` docs, or `auto` (default `auto`)
- `update`: boolean — `true` = sync existing docs to current code/spec; `false` = generate fresh
- the trailing free text = the system description (required when `update=false`)

If the header is malformed, report the error and stop.

## Step 1 — Preconditions

1. Confirm `design_docs.enabled` is true (the `docs_design` agent only exists when enabled). If it is not, tell the user to set `design_docs.enabled: true` in `opencode-swarm.json` and stop.
2. If a spec-staleness block is active (`.swarm/spec-staleness.json` present), resolve/acknowledge spec staleness FIRST — otherwise design-doc writes may be blocked by the guardrail, which emits `SPEC_DRIFT_BLOCK`. Do not blindly retry on `SPEC_DRIFT_BLOCK`.
3. Read `.swarm/spec.md` if present — it is the authoritative requirements source (FR-### IDs). The design docs must be consistent with it.
   Run `/swarm sdd status` to resolve the effective spec before reading.

## Step 2 — Index Existing State (always)

Have the `docs_design` agent (or `doc_scan`) index `<out>/` to discover any existing design docs. If `<out>/reference/traceability.json` exists, it is the section-ID registry — load it. Existing section IDs MUST be preserved on regeneration.

## Step 3 — Generate or Sync

Dispatch the **`docs_design`** agent (the active swarm's `docs_design` — never the standard `docs` agent) with:
- `TASK`, `MODE` (generate|sync), `OUT_DIR`, `LANGUAGE`
- For sync: `FILES CHANGED` and `CHANGES SUMMARY` from the current phase/diff
- `SKILLS: file:.swarm/bundled-skills/design-docs/SKILL.md` (this skill)

The agent owns exactly these files under `<out>` and creates NOTHING else:

```
<out>/
├── domain.md              # 100% language-agnostic. Entities in neutral notation
│                          #   (field: type-class), domain invariants. ZERO framework
│                          #   names in normative text. Section IDs: D-###
├── technical-spec.md      # Language-agnostic architecture: layers, dependency rules,
│                          #   contract SHAPES (inputs→outputs→error-kinds), algorithms,
│                          #   invariants. + the traceability table. Section IDs: S-###
├── behavior-spec.md       # 100% language-agnostic Given/When/Then specs. IDs: B-###
├── design-changelog.md    # Keep-a-Changelog log of design-doc changes (NOT release notes)
└── reference/             # ALL [INCIDENTAL] language/framework-specific material here.
    ├── reference-impl.md  #   Exact signatures, CLI strings, SQL, code. Mapped to
    │                      #   spec sections by ID. Section IDs: R-###
    ├── idiom-notes.md     #   "Here is how the reference solved X" — examples only.
    └── traceability.json  #   Machine-readable section-ID registry (source of truth)
```

## Step 4 — Invariants the docs MUST satisfy

- **Language-agnostic normative text**: `domain.md`, `technical-spec.md`, and `behavior-spec.md` contain ZERO framework/library/language names in normative content. All such material lives ONLY in `reference/`.
- **Version header** on every doc:
  `<!-- design-doc: <name>  version: <phase-or-counter>  generated: <ISO-8601>  spec-hash: <8 chars> -->`
- **Stable section IDs**: assigned once, never renumbered. `D-###` domain, `S-###` technical-spec, `B-###` behavior-spec, `R-###` reference. On sync, reuse every existing ID; mint new IDs only for genuinely new sections.
- **Traceability footer** ending each section: `> Traceability: FR-012, FR-013 | invariant: <id-or-none>`.
- **traceability.json** kept in sync: `{ "schema_version": 1, "sections": [ { "section_id", "doc", "title", "spec_frs": [], "invariants": [], "code_anchors": [] } ] }`. `technical-spec.md` renders a human-readable mirror table `| Doc Section | Spec FR | Invariant | Code anchors |`.
- **design-changelog.md**: append one entry per generate/sync under `## [Unreleased]` (Added/Changed/Removed), e.g. `- <ISO date> phase <N>: <sections touched> (<FR refs>)`. This file is SEPARATE from release-please artifacts — never edit `CHANGELOG.md` or `docs/releases/pending/*` here.

## Step 5 — Verify & Report

1. Confirm the agent created/updated only the allowed files and `traceability.json` is consistent with the docs.
2. Confirm no normative doc names a framework (spot-check) and every section has an ID + traceability footer.
3. Report `UPDATED` / `ADDED` / `REMOVED` / `SUMMARY` back to the user.

## Notes on the PHASE-WRAP sync path

During PHASE-WRAP, the deterministic design-doc drift check (`runDesignDocDriftCheck`) writes `.swarm/doc-drift-phase-N.json`. If the verdict is `DOC_STALE` and `design_docs.enabled`, dispatch `docs_design` in **sync** mode for the affected sections only, then append a design-changelog entry. This is advisory and non-blocking — never block phase completion on design-doc lag.
