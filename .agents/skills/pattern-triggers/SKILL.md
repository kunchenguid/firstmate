---
name: pattern-triggers
description: >-
  Agent-only reference mapping a captain's request-shape language (opinion, plan, build, review, team) onto a concrete dispatch pattern.
  Use during intake, alongside the existing Ship/Scout classification in AGENTS.md section 7, whenever the captain's phrasing signals one of the named patterns below rather than a plain ship or scout request.
  This skill decides HOW MANY agents to dispatch and in what shape; it does not replace the project resolution or Ship/Scout classification steps that already happen during intake.
user-invocable: false
metadata:
  internal: true
---

# pattern-triggers

## Why this exists

AGENTS.md section 7 already classifies every request as Ship or Scout.
That classification answers "does this change a project."
It does not answer "how many independent perspectives does this need, and does the result need to be synthesized before it's useful."
This skill answers that second question, for requests whose phrasing signals a known shape.
The five patterns below are not new capabilities; they are named, repeatable combinations of dispatch primitives firstmate already has, given the same names the fusion-harness Pi extension uses for the same underlying idea, since firstmate is fusion-harness's pattern applied at the fleet-management scale rather than the single-session scale.

## The five patterns

### opinion

**Recognize:** "give me your opinion on X," "what do you think about X," "opinion:", "how would you compare X."
**Shape:** two Scout tasks, different harness/model per `config/crew-dispatch.json`'s planning-tier routing, same prompt, dispatched in parallel.
Neither task sees the other's output.
**Deliverable:** both reports, presented side by side, unedited.
No synthesis, no recommendation from firstmate beyond what each report says on its own.
**When not to use this:** the captain wants one clear answer, not two perspectives to weigh.
Use a single Scout instead.

### plan / fusion

**Recognize:** "plan X," "fusion:", "figure out how to X," any request for a milestone, roadmap, or multi-step breakdown where the scope is not already fully specified.
**Shape:** two Scout tasks (same routing as opinion) propose independently, open-ended, no shared scope between them.
A third step, run by firstmate itself or a dedicated synthesis Scout, reads both proposals plus the actual project state and produces one reconciled plan.
**Deliverable:** the reconciled plan, with explicit attribution for which proposal contributed which part, and an explicit note of what each proposal got right or missed.
**Known cost, from the 2026-07-21 run:** open-ended two-worker proposals can diverge completely from what the captain actually wants, discarding real time/cost on the divergent halves.
If the scope is already known and narrow, skip straight to a single well-briefed Ship or Scout task instead of this pattern - fusion planning earns its cost on genuinely open, ambiguous scope, not on well-specified work.

### build / ship

**Recognize:** "build X," "ship X," "implement X," "fix X" - ordinary Ship classification, already covered by AGENTS.md section 7.
No new behavior; listed here only so the five patterns read as a complete set from the captain's side.

### review

**Recognize:** "review X," "critique X," "find problems with X," "check my work on X," any request to evaluate existing work rather than produce or plan new work.
**Shape:** one dedicated Scout task, explicitly framed as adversarial: verify claims against the actual artifact (code, PR diff, doc), not just restate what the artifact already says about itself.
**Escalation, for higher-stakes review:** dispatch a second review pass on a **different model family** than the first.
The 2026-07-21 run found a real bug that survived four same-family review passes and was only caught once a cross-family pass ran - see `firstmate-data/data/sdlc-milestone-review/report.md` and the fusion-harness repo's `BUGS_FOUND.md` for the evidence.
Default to single-pass review; escalate to cross-family only when the captain asks for higher confidence, or the work is high-stakes (production infrastructure, security-relevant, or explicitly flagged as needing extra scrutiny).

### team / milestone

**Recognize:** "run the team on X," "swarm X," any request that names or implies multiple related issues delivered together as one unit, or an explicit milestone.
**Shape:** the full pipeline exercised on 2026-07-21: `plan`/`fusion` produces the milestone and its issues, each issue dispatches as its own Ship task (potentially to different harnesses/models per `config/crew-dispatch.json`, weighted by the issue's own difficulty), then `milestone-integration-review` runs before any PR-ready escalation reaches the captain.
**This is the pattern that most needs the milestone-integration-review skill.**
Never report a multi-issue milestone ready without it - see that skill for why.

## What this skill does not decide

Project resolution, Ship-vs-Scout classification, delivery mode (`no-mistakes`/`direct-PR`/`local-only`), and secondmate routing are all unchanged, decided exactly as AGENTS.md section 7 already specifies.
This skill only decides how many agents and what shape, layered on top of that existing classification.
