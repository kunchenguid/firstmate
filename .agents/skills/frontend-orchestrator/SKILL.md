---
name: frontend-orchestrator
description: Agent-only reference for dispatching frontend crewmates. Load before briefing or spawning any crewmate whose task involves UI, frontend, design, styling, animation, or visual output. Ensures every frontend task is armed with ux-taste, design-engineer, and flagship-ui.
user-invocable: false
metadata:
  internal: true
---

# Frontend Orchestrator

Load this before dispatching any crewmate whose task involves frontend, UI, design, styling, screens, dashboards, components, animation, layout, or visual output. This is trigger gating, not a suggestion — if the task touches pixels, this skill fires.

## Mandatory Skill Stack

Every frontend crewmate brief MUST include these three skills. None are optional. Order matters: taste first, then motion, then craft injection.

1. **`ux-taste`** — UX vocabulary and decision framework. The crewmate must use this to reason about every interaction decision. This is the *why* before the *what*. Load it first so every subsequent decision is grounded.

2. **`design-engineer`** — Animation and micro-interaction craft. The crewmate must use this for any motion, transition, spring, or timing decision. This is the *how it moves*.

3. **`flagship-ui`** — Craft injection gate. The crewmate must pass all four phases (READ, CRAFT INJECTION, BUILD, AUDIT) before the task is complete. This is the *is it alive* check.

## Brief Injection

When writing a frontend crewmate brief, include this block verbatim after the task description:

```
## Frontend Quality Gates (MANDATORY)

You MUST pass every gate below before reporting done. No exceptions.

1. Load `ux-taste` and use it for every interaction, layout, and hierarchy decision. State your reasoning.
2. Load `design-engineer` for every animation, transition, spring, and motion decision.
3. Load `flagship-ui` and complete ALL FOUR PHASES:
   - Phase 1: READ — state the product type, audience, and visual system in one line.
   - Phase 2: CRAFT INJECTION — answer all five lines specifically before writing code.
   - Phase 3: BUILD — implement everything named in Phase 2 as working, interactive code.
   - Phase 4: AUDIT — verify every Phase 2 promise was built. Run the visual system's own checklist.
4. The build MUST have at least one genuine state change producible through interaction.
5. Empty, loading, and error states MUST exist for anything that fetches, lists, or paginates.

Failure condition: a deliverable that looks correct in a screenshot but has zero interactive depth.
```

## Pre-Dispatch Detection

Before spawning, scan the task description for frontend signals. Any of these triggers the orchestrator:

- Keywords: UI, frontend, design, screen, dashboard, component, style, CSS, layout, animation, page, view, modal, sidebar, panel, widget, landing, form, table, chart, visualization
- Actions: build, create, make, design, style, animate, polish, improve + any visual noun
- Explicit skill mentions: ux-taste, design-engineer, flagship-ui, skeuomorphic-ui, glassmorphism, refined-product-ui, design-provenance
- References to: look, feel, visual, appearance, interaction, hover, click, responsive

When in doubt, trigger. A false positive costs one extra skill load in a brief. A false negative ships dead UI.

## Completion Gate for Firstmate

Before accepting a frontend task as done, verify the crewmate's deliverable against these minimums:

- [ ] Crewmate's response references passing flagship-ui's Phase 2 (all five lines answered)
- [ ] Crewmate's response references passing flagship-ui's Phase 4 AUDIT
- [ ] At least one interactive state change is described as working
- [ ] No "TODO", "placeholder", or "add animation later" in the deliverable

Reject with the specific gate that failed. Do not merge, do not accept, do not close the task until all gates pass.

## Review Vocabulary

When pushing back on a frontend deliverable, use these exact patterns (from flagship-ui's Review Tone):

- `this looks right in a screenshot, but nothing on the page changes when I hover or click. what was supposed to reveal itself and where did it go?`
- `this hover state changes a background color. that's not a payload — what information should actually show up here?`
- `this number sits in plain text but it's a trend/quota/score. what shape should it take?`
- `phase 2 named a live enrichment card. the shipped code has a plain title tooltip. that's a broken promise, not a finished audit.`
