# pstack hybrid

This is a selective Firstmate adaptation of Lauren Tan's MIT-licensed pstack engineering discipline.
It keeps Firstmate as the only router and reuses Firstmate's owners for isolation, delivery, review, and authority.
The adaptation does not install the Cursor plugin, its 21 principle skills, or its 48-skill surface.

## Router

[`pstack-hermes`](../.agents/skills/pstack-hermes/SKILL.md) is the conditional router for rigorous non-trivial engineering work.
It selects one compact principle set and one playbook, then points at existing Firstmate owners instead of copying their procedures.
Its playbook index covers investigation, bug fixing, features, refactors, performance, forensics, prototypes, evaluation, verification, PR readiness, multi-phase delivery, and pickup.
A task that does not match the trigger or already has a complete owner does not load the router.
The task brief and backlog remain the durable place for the chosen steps, skipped reasons, fixed point, owner, and acceptance proof.

Firstmate/Sol owns coordination, scope, synthesis, and integration judgment.
Workers and ordinary reviews use the configured Luna route when the current dispatch profile actually selects it.
Several Luna executions with different rubrics are perspectives, not a multi-model panel.
Azure Opus is reserved for one small, explicit critique because its known limit is 80k tokens per minute.
Receipts record the actual harness, model, and provider rather than inferred role names.

## Principles and owners

[`references/principles.md`](../.agents/skills/pstack-hermes/references/principles.md) compresses the useful pstack decisions into a small selective index.
[`references/playbooks.md`](../.agents/skills/pstack-hermes/references/playbooks.md) owns the adapted sequences and exclusions.
The router defers defects to [`diagnostic-reasoning`](../.agents/skills/diagnostic-reasoning/SKILL.md), dependent plans to [`implement-spec`](../.agents/skills/implement-spec/SKILL.md), and project proof gaps to [`project-verification-harness`](../.agents/skills/project-verification-harness/SKILL.md).
Firstmate's lifecycle in [`AGENTS.md`](../AGENTS.md) remains the owner of worker isolation, steering, review, merge authority, cleanup, and PR state.
The four brief-conditional plays remain available through `bin/fm-brief.sh --plays` for task-level subtract-first, walk-if-needed, prove-the-artifact, and no-comments discipline.
Plays never pick work, isolate copies, or decide delivery.

## Project verification harness

[`project-verification-harness`](../.agents/skills/project-verification-harness/SKILL.md) creates or maintains a project-local proof surface when tests or builds do not close the real behavior loop.
It requires a narrow CLI or driver, a user-oriented Feature Map, synthetic fixtures, sanitized receipts, and a deliberate-break proof when a project needs those artifacts.
It extends an existing project convention instead of forcing a global `verification/` framework.
Its pass proves the real flow and observable state, not only compilation or process exit.
The harness never grants merge, deploy, publish, customer-message, secret-change, or destructive authority.

## Provenance and exclusions

The technical source is the pinned [pstack subtree at commit `b9ddc83c32972210b8a94d389130713e8eed346e`](https://github.com/cursor/plugins/tree/b9ddc83c32972210b8a94d389130713e8eed346e).
The editorial sources are [The Complete Guide to pstack Pt. 1](https://x.com/i/article/2094151284949688320) and [the announcing tweet](https://x.com/poteto/status/2094457600259842065).
The local adaptation was checked against the frozen handoff archive whose SHA-256 is `5f45a6a242f2a2053a34b4744b21fc215b0012a5810a336faff8fd9edb252e16`.
The adaptation excludes Cursor hooks, sticky mode, `/loop`, Graphite, Benny, `make-bot-ui`, `bootstrap.ts`, `orch`, `watch-pr`, `worktree-audit.sh`, auto-merge, auto-deploy, force-push, destructive cleanup, and raw plugin metadata.
It also excludes unsupported model-panel claims and treats the article's 2,000 PRs per month and 100-1000x figures as first-party claims, not Firstmate KPIs.
No Herdr runtime or other unrelated backend surface is changed by this layer.

## Verification

The documentation inventory checks every new skill and reference for classification and local links.
`bin/fm-skill-check.sh` checks internal skill frontmatter and the section 13 routing pointers.
`tests/fm-pstack-adaptation.test.sh` covers positive routing, negative routing, authority boundaries, and the harness contract.
`bin/fm-lint.sh` and `bin/fm-doc-audience-check.sh` remain the repository gates for shell and maintained prose.
