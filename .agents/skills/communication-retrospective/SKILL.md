---
name: communication-retrospective
description: >-
  Review FirstMate session communication for a requested period, defaulting to the prior completed week.
  Use when the captain invokes /communication-retrospective or requests a communication retrospective, communication review, or session-communication improvement.
user-invocable: true
metadata:
  internal: true
---

# communication-retrospective

Review how FirstMate communicated during a bounded period.
Evaluate communication only: clarity, timing, framing, scope handling, decision support, confirmation, and handoff quality.
Do not judge whether underlying implementation, investigation, delivery, or business outcome was correct.
This is a read-only retrospective.
It proposes changes but never changes a skill, prompt, setting, workflow, backlog, or project without separate approval.

## Period and scope

Default period is previous completed ISO week in this home's local timezone, Monday 00:00 through the next Monday 00:00.
Resolve every invocation to an exact inclusive start and exclusive end timestamp before reading evidence.
Accept an explicit period as natural language or exact timestamps.
Repeat resolved period and timezone in the retrospective.
Ask one clarification only when an explicit period is ambiguous enough to change included sessions.

Review communication between FirstMate and its human operator, plus FirstMate's outward communication that materially shaped that interaction.
Include a worker or tool exchange only when it directly explains an operator-facing response, delay, misunderstanding, or decision.
Do not score worker execution, tool performance, code quality, or task outcome.

## Evidence boundary

Use only durable, date-bound evidence from requested period.
Accept a source only when it preserves enough original communication to establish who said what, when, and in what context.
Typical sources are persisted session history or export, durable inbox notes and published replies, and task records that preserve the relevant exchange rather than only its result.
Treat status events, task summaries, PRs, and reports as pointers unless they retain communication itself.
Do not reconstruct missing messages from memory, current task state, or a successful or failed outcome.

Build a coverage inventory before analysis.
For every available source, record its time span, session or record identity, and whether it contains operator-facing communication.
Name unavailable or partial coverage plainly, including sessions that cannot be read durably on current runtime.
When no qualifying evidence exists, return no instances, no findings, and one open question: how to preserve consented durable communication evidence for future reviews.

Protect sensitive content.
Use smallest quote or redacted paraphrase that preserves communication meaning.
Do not reproduce credentials, private data, or unrelated transcript material.

## Method

1. Collect evidence chronologically.
   Create one concrete instance for every observed communication that clearly worked well or poorly.
   Do not cluster, summarize, rank, or recommend before this inventory is complete.
2. Preserve each instance.
   Give every instance an ID, timestamp, source locator, communication direction, neutral context, exact short quote or faithful redacted paraphrase, observed effect, and `worked well` or `needs improvement` label.
   Use a durable session or record identity as locator, not a raw local path unless the path is necessary for review.
   Keep evidence and observed effect separate from interpretation.
   Do not infer intent, satisfaction, or causation without explicit support in source.
3. Cluster after complete inventory.
   Group instances by conceptual topic, not by project, person, or outcome.
   Name each cluster and list its instance IDs.
   State supporting pattern and counterexamples or uncertainty where evidence is thin.
4. Propose improvements.
   For each supported cluster, name smallest candidate change to a skill, tool, prompt, or operating instruction.
   Mark every candidate `Proposed - not adopted`.
   Include evidence IDs, expected communication benefit, tradeoff, and approval needed before any change.
   Never phrase a proposal as already applied.
5. Identify open questions.
   List every unresolved ambiguity, missing-evidence limitation, preference conflict, or proposal requiring a choice.
   Give each question a decision framing and recommended next evidence or option.

## Required response format

Use this exact order.

### Scope and coverage

- Resolved period and timezone.
- Evidence sources, coverage gaps, and material limitations.
- Statement that review covers communication only, not work outcomes.

### Concrete communication instances

List every instance in chronological order before any grouping.
Use this shape:

```markdown
- C1 | <timestamp> | <worked well|needs improvement> | <source locator>
  Context: <neutral communication context>
  Evidence: <short quote or faithful redacted paraphrase>
  Observed effect: <what source supports>
```

### Conceptual clusters

For each cluster:

```markdown
- <topic> - instances: C1, C4
  Pattern: <evidence-grounded communication pattern>
  Confidence: <high|medium|low> - <why coverage supports or limits it>
```

### Improvement proposals

For each proposal:

```markdown
- Proposed - not adopted: <smallest candidate change>
  Target: <skill|tool|prompt|operating instruction>
  Evidence: C1, C4
  Benefit: <communication benefit>
  Tradeoff: <cost or risk>
  Approval: separate approval required before change
```

### Open questions

List concrete questions even when no improvement is proposed.
State `None from available evidence` only when coverage is sufficient and no question remains.

## Completion rules

Do not modify settings, skills, prompts, tooling, task records, or project files as part of this retrospective.
A later approved improvement is separate work and must cite its relevant proposal and evidence IDs.
Do not claim broad coverage when only a subset of sessions was readable.
Do not collapse evidence inventory into clusters or recommendations.
