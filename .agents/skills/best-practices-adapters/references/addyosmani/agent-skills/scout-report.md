# scout.report: addyosmani/agent-skills

Pairs with the scout's report, firstmate's first: the report firstmate expects, then the pack's shape for it.
`bin/fm-best-practices.sh` composes each `##` block below into the brief, where the block's heading is its id and a routing row in `manifest.json` may select it; a block no row names is always composed.

## firstmate-first
Write the report your Definition of done asks for first, then add the pack's shape below it in the same report.

## spec-plan
Add a spec and plan in the pack's shape, from `spec-driven-development` and `planning-and-task-breakdown`: success criteria, slices with acceptance criteria, a "Not doing" list, and the spec's open questions.

## map-only
This request spans several independently testable capabilities, so the report is the capability map only, in `spec-driven-development`'s shape: module boundaries, dependency direction, and build order in about ten reviewable lines, with no module spec yet.

## one-pager
This ask is an idea to explore rather than a direction to build, so the report takes `idea-refine`'s one-pager shape instead: a problem statement, a recommended direction, key assumptions to validate, MVP scope, a "Not doing" list with the why, and open questions.
Name the two or three directions the research converged on, so they can be put side by side for a pick.

## gates
The pack's approval gates are not yours to wait on: finishing the report is the stop.
Firstmate brings the report for review and holds each open question as a decision, and nothing is built from it until that answer, because a scout report is evidence, not authorization.
