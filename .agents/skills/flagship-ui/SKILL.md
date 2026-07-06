---
name: flagship-ui
description: "Use when asked to build a UI, screen, dashboard, or component that needs to feel genuinely shipped, not a mockup. Use for 'build me a screen', 'make this feel premium', 'CRM/dashboard/SaaS/agent UI', or any single-prompt UI request where the bar is production quality. Use when a prior UI build looked right in a screenshot but felt flat, static, or like a wireframe with colors."
user-invocable: false
metadata:
  internal: true
---

# Flagship UI

A screenshot is not a shipped product. This skill exists because a model can pass every visual-taste check (right tokens, right spacing, right palette) and still deliver something dead — no interaction earns its keep, no number does anything but sit there, everything works exactly once (on load) and never again.

This skill does not define a visual language. For that, load whichever system fits the brief: `refined-product-ui` (Linear/Attio-tier structural minimalism), `skeuomorphic-ui` (tactile dark hardware), `glassmorphism`, `design-provenance` (landing/portfolio), or `ux-taste` (the vocabulary for *why* a detail matters). This skill is the **forcing function** that makes whichever visual language you picked actually ship with depth, instead of stopping at static composition.

## Core Prompt

Start from this baseline:

> Before writing a single line of markup, name the specific interaction, data-visualization, meter-shape, and warmth decisions this exact screen needs. Then build all of it working — not decorated, not deferred, not left as a hover class with no payload. A build that looks right in a still frame and does nothing when touched is not done.

## Phase 1 — READ

Identify: product type (CRM, dashboard, agent tool, landing, form), audience, and which visual-language skill fits (`refined-product-ui` / `skeuomorphic-ui` / `glassmorphism` / `design-provenance` / none-of-the-above-build-native). State it in one line: *"Reading this as: \<type> for \<audience>, building in \<system>."*

**Completion criterion:** the one-line read is stated before any code exists.

## Phase 2 — CRAFT INJECTION (the mandatory, checkable gate)

Before writing code, answer each line below with a **specific, named decision for this exact screen** — not a category, not "add micro-interactions." An honest `N/A — reason` is acceptable only when the element genuinely doesn't apply; `N/A` alone is not.

1. **Live/hover state with a real payload.** Something on this screen must reveal information on hover/focus/interaction that wasn't visible before — a preview card, an enrichment popover, an expand, a reveal. Not a background-color hover. Name what reveals and where it appears.
2. **A number becomes a shape.** If this screen has any numeric data (revenue, usage, scores, trends), at least one of them is rendered as a visualization (sparkline, meter, chart), not bare digits. Name which number and which shape.
3. **Meter shape matches the math.** If anything is metered (quota, storage, progress), state whether it's discrete or continuous and confirm the component shape (segmented vs. smooth) matches. See `ux-taste` Q12 for the reasoning if unsure.
4. **One warmth accent, if the surface is chrome-dense.** If the screen is otherwise all icons/type/bars, name the one photographic or illustrative element and where it sits. If the screen is already warm or is deliberately data-only (a spec table, a settings page), say so.
5. **One micro-interaction with an actual state change.** Not a decorative animation — something that responds to a real user action (drag, type, submit, delete) with physical or visual consequence. Name the trigger and the response.

**Completion criterion:** all five lines exist in writing, each either a specific named decision or a reasoned N/A. Skipping straight to code is premature completion — treat the visible next phase (BUILD) as invisible until this list exists.

## Phase 3 — BUILD

Implement everything named in Phase 2 as **working code**, not markup that implies it:

- Every hover/live-state decision from #1 has real JS/state behind it — an element that changes on `:hover` alone with no new information does not satisfy #1.
- Every data visualization from #2 renders from real-looking data (varied, specific numbers — see `ux-taste`'s "organic data" standard), not placeholder round numbers.
- Empty, loading, and error states exist for anything that fetches, lists, or paginates — a build that only shows the happy path is incomplete, not "polished."
- Every interactive element has a focus-visible state; nothing is a click target with no visual affordance.

**Completion criterion:** opening the file and interacting with it (hover, click, type) produces at least one state change that wasn't visible on first paint. A file that is visually complete but behaviorally inert on interaction fails this criterion outright, regardless of how correct the tokens and spacing are.

## Phase 4 — AUDIT

Run the audits already defined elsewhere — do not re-derive them here:

- If the visual system is `refined-product-ui`, run its Quality Checklist (card-soup, tag patterns, alignment, meter shape).
- Run `ux-taste`'s Mandatory Per-Build Materiality Pass for this screen specifically.
- Re-check Phase 2's five lines against the shipped code: did the built version actually do what was named, or did a line get quietly dropped during BUILD?

**Completion criterion:** every Phase 2 line has a corresponding, verifiable piece of shipped code. A line that was named but not built is a broken promise, not a completed audit.

## Failure Modes (what this skill exists to prevent)

- **The screenshot trap.** Code that would look correct in a static image but has zero interactive depth — every hover is a color shift, every number is plain text, nothing responds to touch beyond the browser's free defaults.
- **Decorative motion standing in for craft injection.** A fade-in on scroll is not a substitute for #1-#5. Motion without new information is decoration, and decoration doesn't satisfy this skill's gate.
- **Named-but-not-built.** Phase 2 lists a hover-enrichment card; Phase 3 ships a plain tooltip. The audit phase exists specifically to catch this gap — check it every time, it is the single most common failure.
- **Placeholder data undermining a real visualization.** A sparkline drawn from `[10, 20, 30, 40, 50]` reads as fake the instant someone looks at it. Jagged, specific, slightly noisy data or nothing.
- **Applying craft injection where it isn't earned.** Not every screen needs a hover-enrichment card. A settings toggle page may legitimately answer "N/A" to #1 and #2. The gate is mandatory to *answer*, not mandatory to *apply everywhere* — forcing a sparkline onto a page with no numeric data is its own failure.

## Approval Bar

- Phase 2's five lines are answered in writing, specifically, before code exists
- every named decision has corresponding working code — no promise left unbuilt
- at least one genuine state change is producible through interaction, not just page-load
- the relevant visual-language skill's own checklist passes
- `ux-taste`'s materiality pass is written and reasoned, not skipped

**Presumptive blocker:** a delivered build where every element is visually final on first paint and stays that way no matter what the viewer does.

## Review Tone

- `this looks right in a screenshot, but nothing on the page changes when I hover or click. what was supposed to reveal itself and where did it go?`
- `this hover state changes a background color. that's not a payload — what information should actually show up here?`
- `this number sits in plain text but it's a trend/quota/score. what shape should it take?`
- `phase 2 named a live enrichment card. the shipped code has a plain title tooltip. that's a broken promise, not a finished audit.`
- `this sparkline is drawn from round placeholder numbers. it reads as fake immediately — use organic, specific data.`
