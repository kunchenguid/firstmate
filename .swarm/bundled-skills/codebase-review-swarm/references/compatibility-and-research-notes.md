# Compatibility and Research Notes

This package targets the shared Agent Skills shape: a directory containing `SKILL.md`, plus optional `references/`, `assets/`, `scripts/`, and Codex-specific `agents/openai.yaml` metadata.

## Compatibility decisions

- Canonical opencode-swarm repo install path: `.opencode/skills/codebase-review-swarm/`.
- Claude Code repo adapter path: `.claude/skills/codebase-review-swarm/`.
- Codex repo adapter path: `.agents/skills/codebase-review-swarm/`.
- Portable OpenCode install paths for other repositories: `.opencode/skills/codebase-review-swarm/`, `.claude/skills/codebase-review-swarm/`, or `.agents/skills/codebase-review-swarm/`.
- Frontmatter is intentionally minimal and portable: `name`, `description`, `license`, `compatibility`, and `metadata`.
- Long operational content is progressively disclosed via `references/` and `assets/` rather than packed only into `SKILL.md`.
- The full v7 source is retained verbatim in `references/full-v7-source-prompt.md` for long checklists and provenance.

## Standards updates in v8.2

- OWASP ASVS: use 5.0.0 as the stable baseline. The source v7 prompt referenced 4.0.3 with v5.0 draft; this package supersedes that for current reviews.
- OWASP Top 10 for LLM Applications: use 2025 categories, including system prompt leakage and vector/embedding weaknesses.
- SLSA: use v1.2 terminology for provenance, build levels/tracks, and attestation expectations.
- UI accessibility: use WCAG 2.2 AA unless repository policy requires stricter.
- Observability: use OpenTelemetry traces, metrics, logs, and context propagation as the default model.

## Invocation policy

This review is heavy and can run many read-only commands. Codex-specific `agents/openai.yaml` sets `allow_implicit_invocation: false` to prefer explicit `$codebase-review-swarm` usage. Other hosts may still suggest it based on the `description`.
