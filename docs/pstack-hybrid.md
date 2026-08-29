# pstack hybrid

This fork ports the engineering-discipline habits of [pstack](https://github.com/cursor/plugins/tree/main/pstack) by Lauren Tan ([@poteto](https://x.com/poteto), MIT) onto Firstmate's own worker stack, so the discipline fires inside the code-writing worker instead of competing with Firstmate for routing authority.

The design recipe this page summarizes lives in the captain's private data (the reference artifact); this page is the tracked summary.
When this page and an authoritative file disagree, the authoritative file wins.

## One runtime, not two routers

Firstmate remains the only router.
Plays never pick work, isolate copies, or decide delivery; the lifecycle in [`AGENTS.md`](../AGENTS.md) sections 7 and 11 keeps that authority.
Plays are habits for the worker that is already writing code, loaded just in time through the task brief.

Nothing is always-on: a brief names exactly the plays that job needs, and an unnamed play never applies.

## Plays library

Each play is a small internal skill under `.agents/skills/`, one principle each:

- [play-subtract-first](../.agents/skills/play-subtract-first/SKILL.md) - task-level anti-overengineering: trace the real flow and callers, plan the smallest scope, remove before adding, fix the root cause once, test only changed uncovered behavior, and prove the final diff.
- [play-walk-if-needed](../.agents/skills/play-walk-if-needed/SKILL.md) - walk the system only when the change crosses into unfamiliar areas or shared boundaries; otherwise write one line saying why you skipped it.
- [play-prove-the-artifact](../.agents/skills/play-prove-the-artifact/SKILL.md) - prove with a live command, flow, record, or local verifier; tests existing is not done.
- [play-no-comments](../.agents/skills/play-no-comments/SKILL.md) - strip AI-tell comments from your own diff before review.

A play is loaded by a worker only when its brief names it.
`bin/fm-brief.sh --plays <name[,name...]>` validates names against this home's plays library and emits a task-scoped `# Plays` section; the script's header owns the exact mechanics.
Plays deliberately exclude pstack's orchestration plays (`orchestrate`, `autopilot-full`, `autopilot-stack`, and friends): routing, isolation, and delivery stay with Firstmate.

## Setup-pstack analog: model roles are already covered

pstack's `/setup-pstack` writes per-role model configuration for code, judgment, and review roles.
This fork already has the machinery for that, so the deliverable is this mapping, not new code:

- Code role: the per-task harness, model, and effort chosen by a `config/crew-dispatch.json` dispatch profile; [`docs/configuration.md`](configuration.md) owns that schema.
- Judgment role: the strongest-reasoning-class rule in `AGENTS.md` section 4, which prevents silently downgrading ambiguous work to conserve quota.
- Review role: the task's selected delivery path (`AGENTS.md` section 7), which owns review through the no-mistakes pipeline or the configured merge authority; Firstmate never spawns a separate reviewer for it.
- Quota-aware model choice among candidates: `quota-axi` ranked by `spendPriority`, with the `quota-array-dispatch` skill owning the selection procedure.

There is no per-role model config file to write, and none is needed.

## No-comments analog and the delivery path

[play-no-comments](../.agents/skills/play-no-comments/SKILL.md) is the worker-side habit: the worker sweeps its own diff for AI-tell comments as implementation hygiene before declaring done.
It adds no review gate, no reviewer, and no multi-model loop; the selected delivery path still owns review.
Its findings fold into the worker's own commit, so no-mistakes validates the already-clean diff.

## Verification

- `tests/fm-brief.test.sh` covers conditional play loading, unknown-play refusal, and the charter refusal.
- `bin/fm-lint.sh` and `bin/fm-doc-audience-check.sh` gate style and classification.
