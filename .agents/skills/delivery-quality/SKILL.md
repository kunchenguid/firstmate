---
name: delivery-quality
description: >-
  Agent-only procedure for choosing a task's configured model route and proportional delivery evidence.
  Load before writing any ship or scout brief and before treating a PR as ready, to apply exact-model discovery and fallback, right-size validation, browser and media evidence, reconcile CI and automated review, and report the result concisely without creating another review layer.
user-invocable: false
metadata:
  internal: true
---

# delivery-quality

Load this before writing any ship or scout brief and again before treating a PR as ready.
This skill owns the conditional decision procedure for model routing, validation depth, browser verification, review evidence, and PR-ready reconciliation.
The selected delivery path remains authoritative, and this procedure must not create a second orchestration or quality pipeline.

## Choose and record the route

Apply dispatch precedence exactly once: an explicit per-task captain instruction, then the best-fit `config/crew-dispatch.json` rule, then its configured default, then the static crew harness.
A per-task instruction always wins, including its requested harness or interface, model, and effort axes, unless the requested harness or exact model cannot be established as supported in the current authenticated environment.
Use the current discovery surface in `harness-adapters` before passing a configured exact model to `fm-spawn`.
Do not infer an alias, silently substitute a similarly named model, or claim that an unavailable route ran.

A rule's optional `fallback` is a concrete unavailable-model fallback, not a quota candidate or a lower-precedence default.
Use it only when the rule's single preferred `use` profile names an exact model whose current availability cannot be verified or whose launch reports that it is unavailable.
Verify the fallback's harness and exact model through the same current discovery surface before dispatching it.
If both preferred and fallback routes are unavailable or unverified, stop and report the two concrete failures.
A configured fallback never overrides an explicit per-task captain model instruction unless the captain also authorized that fallback.
Record the actual selected harness, model, and effort in the spawn flags, and mention a fallback in the eventual outcome because it materially differs from the standing route.

The copyable standing routes and their currently verified exact identifiers live in `docs/examples/crew-dispatch.json`.
`docs/verification/model-routing.md` records the current local empirical evidence for those identifiers.
Reverify volatile model availability before applying that private config after a later client, account, or catalog change.

## Write a proportional quality plan

Put a short task-specific validation and evidence plan in the task text before spawning.
Name the existing checks to run, whether browser verification is material, and whether a screenshot or video belongs in the PR.
Do not leave the worker to infer an expensive ceremony from the fact that a file is frontend code.

Use this scale:

- A trivial, mechanical, or nonvisual fix uses one cheapest capable worker, low effort, the repository's existing hooks, and only the focused checks already appropriate to the edit.
  It gets no extra worker, broad review, browser pass, screenshot, or video unless the changed behavior itself makes one materially useful.
- Quick, well-understood backend work uses one worker on the standing GPT-5.5 route when available, low effort, focused tests, and existing quality gates.
- Medium engineering work uses one worker on the standing GPT-5.6 route, medium effort, and focused plus affected-subsystem checks.
- Complex, ambiguous, high-blast-radius, or design-heavy work uses the same strongest appropriate route with high or xhigh effort and broader relevant checks.
  Add another worker only for an independently valuable investigation or a genuinely distinct validation question that cannot be answered well by the implementation worker or existing repository gates.
- Substantive frontend implementation uses the standing Claude Opus 5 route when available and gives browser behavior, visual regressions, accessibility, responsive states, and interaction paths the depth their user impact warrants.
  It does not automatically require video, a second worker, or a second broad code review.

Preserve every repository's installed pre-commit hooks and configured quality gates.
Run them through the repository's normal commit and delivery flow.
Do not reinstall, replace, or bypass them merely because a setup skill or local setup note is absent.

## Cross-model validation

For substantive frontend work implemented with Pi and `anthropic/claude-opus-5`, use one focused validation scout on Pi and `openai/gpt-5.6-sol` when it can answer a distinct correctness, browser-behavior, accessibility, responsive-state, or interaction question.
Validate the exact implementation commit before the PR is opened, and record the validator's model and named question in its instructions.
When a separate validation scout is required, tell the implementation worker in its original instructions to commit, append one keyed `blocked:` validation-ready event naming the commit, and stop before push so firstmate can act.
After the scout reports, steer the implementation worker with the findings or clearance and require it to append the matching `resolved:` event when it resumes.
Keep the scout knowledge-only and route material findings back to the implementation worker for focused fixes and affected-check reruns.
Do not turn it into a second generic code reviewer, repeat checks already answered by the implementation worker, or add another review after it.
Skip the extra worker when the change is trivial, nonvisual, or already fully established by focused checks and browser evidence.
If the exact validation model is unavailable, verify and report the configured fallback rather than claiming cross-model validation occurred.

## Browser and visual evidence

Require browser verification with `chrome-devtools-axi` for user-facing behavior when a real browser can materially validate the changed result.
Select task-relevant states and viewport sizes rather than performing a generic tour.
A browser pass is optional for nonvisual changes, generated output, documentation-only edits, and trivial changes whose behavior is fully proven by focused non-browser checks.

Require a screenshot in a frontend PR when it materially improves review of appearance, layout, responsive behavior, or a visible state.
Require video only when motion, interaction, responsiveness over time, or a state transition is materially clearer in motion than in still images and prose.
Do not require either medium for nonvisual or trivial changes.
Use the repository's existing PR upload or evidence mechanism.
Do not commit disposable screenshots or recordings unless that existing owner requires committed evidence.
If no existing mechanism can place the useful artifact in the PR without changing repository policy, state that limitation and include the browser result in the PR summary instead of inventing an evidence store.

## Discoveries and scope

A worker must surface a discovery that could materially change correctness, accepted scope, risk, security, migration behavior, or product behavior.
Route an actual product or engineering-contract choice through the normal decision authority.
Continue independently only when the correction is clearly required by accepted intent.
Do not use a discovery as permission for drive-by cleanup, adjacent feature work, or a broader redesign.

## Delivery and PR-ready reconciliation

After implementation and any proportionate cross-model validation, run the repository's existing focused tests, hooks, and quality gates.
For `local-only`, stop with a clean validated task branch, do not push or open a PR, and return the result to `task-lifecycle` for captain-approved landing.
For `direct-PR`, push only the task branch and open or update its PR through `gh-axi`; never push the default branch and never merge.
Verify all configured required CI checks are green before reporting a direct PR ready.
Inspect current automated review feedback through `gh-axi`, including CodeRabbit when the repository configures it or it has posted on the PR.
Route every actionable finding that could affect correctness, scope, risk, or product behavior back to the implementation worker, then rerun affected checks and push the focused fix on the same task branch.
Do not wait forever for an optional service that is absent or silent.
If no required check or posted review establishes that service as active, make one final refresh after required CI turns green and then treat its absence as non-blocking.
A pending required check, an already-posted actionable finding, or a repository-documented bot requirement remains blocking until it resolves or reports a concrete failure.

Report readiness to the captain in one concise outcome: what changed, the actual implementation and validation models when useful or when fallback occurred, checks and browser or media evidence, material residual risk, and the full PR URL or clean local branch as applicable.
Do not relay delivery mechanics or a checklist dump.
