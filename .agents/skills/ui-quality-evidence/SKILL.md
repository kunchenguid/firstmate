---
name: ui-quality-evidence
description: Produce reproducible evidence for an implemented UI against its authoritative templates and acceptance contract, including visual, interaction and accessibility checks; do not use to invent a design or choose mobile adaptations.
metadata:
  internal: true
---

# UI quality evidence

Own the reproducible UI evidence matrix, using the project's existing test framework and reporting surface.
Start from the authoritative templates, design system and acceptance requirements; do not invent designs, baselines or approval criteria.
The project's roles, live review and delivery contract remain authoritative, and evidence does not replace their approval.
Read [matrix and checks](references/matrix.md) when building or refreshing evidence.

## Evidence procedure

1. Map each required route and state to its exact template or design source and acceptance criterion.
2. Select the required viewport, theme and locale combinations, stating exclusions and the reason rather than silently sampling away required axes.
3. Freeze the rendering environment and fixtures, then exercise the real route and interactions using observable readiness assertions.
4. Compare structural/template parity and visual appearance separately from functional and dimensional checks, recording failures with reproducible steps.
5. Exercise keyboard, focus, accessibility and overflow behavior and attach the observed results to the same matrix.
6. Report pass, fail, unverified or not applicable per row, with artifact/test pointers and honest limitations.

For phone/tablet adaptation decisions, use [mobile-tablet-ui](../mobile-tablet-ui/SKILL.md) and incorporate its device observations in this matrix.
Use internal screenshots or diffs only as evidence within the existing workflow; when live approval is required, provide the actual application through the project's established review path.
This skill is original repository guidance and vendors no third-party prompt, executable or remote instruction feed.
