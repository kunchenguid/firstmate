# Codebase Review Swarm Skill v8.2

Portable Agent Skill for OpenCode, Codex, and Claude Code. It converts the v7 codebase-review swarm prompt into a progressive-disclosure skill package with a short routing-focused `SKILL.md`, detailed protocol references, parseable schemas, report template, optional Codex metadata, and deterministic helper scripts.

## Contents

```text
codebase-review-swarm/
  SKILL.md
  INSTALL.md
  README.md
  agents/
    openai.yaml
  assets/
    jsonl-schemas.md
    review-report-template.md
  references/
    compatibility-and-research-notes.md
    full-v7-source-prompt.md
    review-protocol-v8.2.md
  scripts/
    init-review-run.py
    validate-skill-package.py
```

## Design summary

- Canonical opencode-swarm repo path: `.opencode/skills/codebase-review-swarm/`.
- Claude path: `.claude/skills/codebase-review-swarm/` as a thin adapter to the canonical OpenCode skill.
- Codex path: `.agents/skills/codebase-review-swarm/` as a thin adapter with `agents/openai.yaml`.
- Portable user install paths may still use `.agents/skills/`, `.opencode/skills/`, or `.claude/skills/` depending on host.
- Frontmatter is intentionally portable: required `name` and `description`, plus harmless metadata.
- Long instructions are split into references/assets to preserve routing quality and context budget.
- Focused track selections expand depth inside the selected domain; multi-track/all-track selections add waves rather than sacrificing per-track quality.
- The full v7 prompt is preserved verbatim for detailed track checklists.
- Standards are current as of 2026-06-08: ASVS 5.0.0, OWASP LLM Top 10 2025, SLSA v1.2, WCAG 2.2 AA, OpenTelemetry.

## Primary command

```text
$codebase-review-swarm
```

Begin at repository root. The skill runs Phase 0 inventory, stops for review mode selection unless preselected, then performs selected exhaustive tracks with coverage closure, review-depth planning, non-diluting multi-track execution, and critic validation.
