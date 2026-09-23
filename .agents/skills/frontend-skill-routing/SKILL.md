---
name: frontend-skill-routing
description: >-
  Agent-only intake procedure for selecting installed frontend, UI, UX, visual,
  interaction, accessibility, and frontend-quality skills and handing the
  relevant instructions to isolated workers.
user-invocable: false
metadata:
  internal: true
---

# Frontend skill routing

Load at the `AGENTS.md` section 7 intake trigger, before scoping or dispatching material frontend work, including a standalone visual or UX audit.
Do not load for backend-only, pipeline-only, or unrelated tasks merely because the project has a frontend.
This skill owns the needs-to-skills choice; the existing intake, secondmate scope, delivery, model, effort, concurrency, and worker lifecycle contracts remain in charge of their own decisions.

## Select by the assignment, not by a fixed bundle

1. Identify the actual deliverable and the worker's bounded surface: visual direction, usability/interaction, frontend implementation, interface review, or research.
   Follow the captain's current words, project instructions, established brand and component system, and any stricter local skill policy first.
   An accepted visual direction is not an invitation to prototype alternatives; design-system work can require visual judgment, implementation guidance, and accessibility rather than code-only changes.
2. Discover only the skills exposed by the active harness and the current user/workspace skill directories; inspect lightweight names, descriptions, and invocation metadata before selecting.
   Never assume a named skill exists, search archives or caches, install one speculatively, or treat a present but unreadable skill as loaded.
   Select the smallest complementary set with a material purpose for this assignment, read each selected `SKILL.md` completely, and follow linked task-relevant references.
   Respect `disable-model-invocation: true` and other invocation restrictions: an explicit-only skill is not eligible for automatic invocation, even when its subject fits.
3. Use `frontend-design` when fresh visual direction, type, color, composition, or layout judgment materially matters; `ui-ux-pro-max` when usability, interaction patterns, or component UX decisions need its breadth; `modern-web-guidance` for current HTML/CSS/client-side implementation guidance (follow its own execute-first requirement); and `web-design-guidelines` for a real interface, accessibility, or usability review, including a review supporting implementation when useful.
   These are complementary options, not four required reads on every task.
   Add `shadcn-svelte` when working with shadcn-svelte, its primitives, or a matching Svelte design-system setup; `apple-design` when refined feedback, motion, transitions, microinteractions, or physical interaction principles materially help, never to imitate Apple's brand.
   For competing visual/interaction concepts, consider `prototype` only when alternative concepts would change the decision and invocation is permitted; do not prototype a settled direction.
   Consider `imagegen-frontend-web` only for useful generated visual references or concept exploration, never routine implementation; a skill is not permission for an unrequested image-model call or a disallowed provider.
   Consider `pick-ui-library` only for an actual library selection, replacement, or comparison, and only when invocation is permitted; never reopen a settled project choice.
   Use `user-interviews` only for actual qualitative UX research, interview planning, or synthesis, not ordinary UI implementation.
4. If a skill is missing, broken, inaccessible to the worker, or disallowed by its invocation metadata, continue using project rules and ordinary judgment unless the missing capability would materially affect the outcome; report only that material impact.
   Do not invoke another provider on a skill's recommendation without current authorization.
   Preserve accepted brand and local UI constraints, including borders, hover effects, radius, contrast, component ownership, storefront separation, and framework architecture; advice never overrides these.

## Hand off and verify

Before dispatch, state in **each** frontend ship or scout brief's `## Firstmate spec` the selected skill names, why they fit that worker's specific scope, and where that worker can load their full instructions (an accessible path or harness-provided skill invocation).
Tell the worker to read them before acting and follow relevant references and project authority, and to report any material unavailability; do not merely say that the supervisor has loaded them.
Different independent frontend assignments may need different selections; secondmates make the same selection in their own home when they brief their workers, rather than inheriting an inaccessible path from the main home.
When an existing worker's remaining scope gains a material frontend need, steer only the newly relevant accessible instructions for that remaining work; do not restart, redo completed work, or reload an already applied set mechanically.
Do not inject frontend skill instructions into backend-only briefs or a blanket scaffold.
Match verification to the work: behavior, keyboard/accessibility, responsive layout, and visual/interaction checks where applicable, rather than treating a successful build as a complete UI review.
