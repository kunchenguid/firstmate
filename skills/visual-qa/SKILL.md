---
name: visual-qa
description: Review web UI work for visual quality before calling it done - a breakpoint matrix, a state checklist covering hover/interactive/empty/success states, a table for translating subjective feedback ("feels weird", "too corporate") into actionable design language, and a closing report format that tells a human where to see the change and what to verify. Use when building or reviewing any user-facing web UI change, when a user gives subjective visual feedback, or before declaring frontend work complete.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone, with no private project paths, tool assumptions, or environment branching. -->

# visual-qa

Passing tests does not imply good visual quality.
A UI change that compiles, type-checks, and passes every automated test can still be visually broken: overflowing at one width, missing a hover state, or collapsing into an empty screen with no message.
This skill is the procedure for catching that before a human does: check the change at a fixed set of widths and states, translate any subjective feedback into concrete design dimensions, and close with a report that makes the change easy for a human to verify.

## Breakpoint matrix

Verify every UI change at each of these widths, using real rendering (a browser or browser automation), not intuition about how CSS should behave:

| Width | Represents |
| --- | --- |
| 1440px | Desktop |
| 1280px | Laptop |
| 768px | Tablet |
| 375px | Mobile |

If the project documents its own breakpoints (a Tailwind config, a design-tokens file, a documented breakpoint scale), use those instead - the four widths above are the default when the project defines none.
Do not verify only the width you developed at: most visual regressions live at the widths nobody was looking at.

## State checklist

At each width, check:

- Layout integrity - nothing overlapping, clipped, or misaligned.
- Visual hierarchy - the most important element reads as the most important; secondary content does not compete with it.
- Hover states - every interactive element visibly responds to hover.
- Interactive states - focus, active, disabled, and loading states exist and look intentional.
- Overflow and wrapping - long text, long unbreakable strings, and large datasets wrap or truncate deliberately instead of breaking the layout.
- Spacing consistency - gaps, padding, and margins follow one rhythm rather than ad hoc per-element values.
- Accessibility - contrast is sufficient, interactive elements are reachable by keyboard, and images and controls have accessible names.
- Empty states - the UI says something useful when there is no data, not a blank region.
- Success and error states - the result of an action is visible, not inferable only from the absence of failure.
- Project-specific variants - if the project has themes, locales, or a language toggle, check the change under each variant it affects.

## Translating subjective feedback

Human subjective reactions are first-class input, and the human is not required to use design terminology.
Never dismiss feedback for being vague; translate it into an actionable design dimension, asking one clarifying question when the mapping is genuinely ambiguous.

| Feedback | Translate into |
| --- | --- |
| "I don't like this." | Ask why once - corporate, crowded, generic, too playful - then map the answer using this table. |
| "This feels weird." | Determine which dimension is off: hierarchy, spacing, contrast, copy, affordance, density, or consistency. |
| "This feels too corporate." | Adjust tone: copy, placeholder text, imagery, and visual styling. |
| "This feels cluttered / busy." | Reduce density: fewer competing elements, more whitespace, clearer hierarchy. |
| "This looks generic / like a template." | Add a deliberate point of view: typography, color, and layout choices that are decisions rather than defaults. |

Two rules that keep this loop productive:

- Do not require a complete design system before making iterative improvements; act on the translated feedback now.
- When feedback concerns wording - labels, buttons, headings, placeholders - treat it as audience architecture, not copyediting: identify who the language is for and what mental model it creates, then explain why the proposed wording is better.

## Closing report

A UI change is not complete until a human can easily verify it.
End every UI change with a short report answering:

1. Where to see it - the URL or route, and whether it is local only, committed, pushed, in a deploy preview, or in production.
2. What visually changed - a plain-language description of the intended difference, with screenshots when you produced them.
3. What to verify - which interactions to try and which of the widths and states above matter most for this change.
4. What is already verified - which checks from this skill you completed, and which still need human eyes (subjective tone and taste always do).
