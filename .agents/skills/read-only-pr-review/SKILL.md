---
name: read-only-pr-review
description: >-
  Agent-only procedure for deep, evidence-first pull-request reviews that return a verdict, findings, and action items without changing project or forge state.
  Use before scoping, dispatching, or evaluating a captain-requested read-only PR review.
user-invocable: false
metadata:
  internal: true
---

# read-only-pr-review

Use this procedure when the captain supplies a pull-request URL and asks for deep analysis with no changes.
This skill is the single owner of Firstmate's repeatable read-only PR-review procedure.
It standardizes the two-pass evidence discipline used successfully on the service-macaddress PR 19 and PR 20 reviews without preserving their project-specific findings.

## Review shape

Treat the request as a knowledge-only scout.
Use the managed scout lifecycle so completion is supervised, the report is durable, and the isolated project copy can be cleaned up safely.
Never substitute a standalone agent session whose completion and report exist only in a UI or temporary directory.

The review is full-diff by default.
A captain-supplied focus area adds emphasis but does not narrow away correctness, security, test quality, integration, or regression review of the rest of the pull request.
The review may recommend implementation, but it never authorizes implementation.

## Immutable snapshot

Resolve and record the repository, pull-request number, title, author, base branch, exact head SHA, exact base-tip SHA, merge-base SHA, commit list, and current forge checks before analysis begins.
Use the forge's pull-request diff semantics and state the exact reviewed range in the report.
If the head changes during review, finish and label the report against the recorded SHA rather than silently switching snapshots.
A review of a superseded head is not a review of the replacement head.

Start from a fresh isolated copy detached at the exact reviewed head.
Require `git status --short` to be empty before evidence gathering and again before completion.
Build and test caches are acceptable only when they leave the project copy clean.

## Hard read-only boundary

The scout must not edit project source, documentation, configuration, tests, generated files, or lockfiles.
The scout must not commit, push, update branches, merge, post GitHub comments, submit GitHub reviews, or change forge state.
The scout may write reproduction scripts and captured results only outside the project copy, and the durable final report only to the task's supplied `data/<id>/report.md` path.
The scout may run safe local tests, linters, builds, and representative local integrations.
The scout must not run tests or commands that can mutate production, shared cloud resources, external services, or durable team data.
When a faithful test would cross that boundary, record the limitation and use the closest safe evidence without claiming equivalence.

Apply the `no-mistakes` review discipline manually: reconstruct intent, require evidence before assertion, and evaluate whether tests execute the claimed behavior.
Do not start `no-mistakes axi run` or another validation-and-delivery flow because those flows may rebase, fix, commit, push, open pull requests, or drive CI.

## Evidence procedure

Reconstruct intended behavior from the pull-request body, linked issue or specification, commit messages, code comments, existing documentation, and relevant history.
Name missing or contradictory intent rather than silently choosing an interpretation.

Review the complete diff and the relevant surrounding code, callers, schemas, configuration, tests, workflows, generated documentation, migrations, and prior implementation history.
Trace changed values and contracts through their actual call chains.
Do not stop at a suspicious line when a later dedupe, validation, transaction, constraint, retry, or normalization could neutralize the suspected consequence.

Treat green CI and automated findings as evidence, not as the verdict.
Read existing human and automated review comments so the report can assess known concerns without merely repeating them.
Confirm that tests execute affected public behavior and assert observable outcomes rather than merely grepping or snapshotting source.
Check fixtures, skipped tests, helper signatures, configuration realism, and integration coverage for false confidence.
Assess already-reported findings, then seek additional defects instead of repeating automation alone.

Run the project's appropriate safe tests and linters where feasible.
Prefer the locked project environment and record versions when runtime behavior is load-bearing.
Use the real local engine or storage layer when engine semantics determine correctness.
State the exact limitation when the production engine, catalog, data, credentials, or environment is unavailable.

For each suspected defect, separate these scopes:

- Introduced by this pull request.
- Pre-existing but materially exposed or amplified by this pull request.
- Pre-existing and adjacent, which belongs under residual risks or a separate follow-up rather than as a pull-request finding.

Load `diagnostic-reasoning` before admitting a suspected behavioral bug as a finding.
Use its trigger, masking condition, visible symptom, proven-path comparison, counterfactual, and disconfirming-evidence procedure rather than restating that diagnostic contract here.

## Focused second pass

A Critical or High finding is not publishable from inspection alone when executable validation is feasible.
Before finalizing it, require a focused second pass that:

- Runs the smallest behavioral reproduction against the exact reviewed head.
- Runs an A/B comparison against the exact base when the behavior changed across the pull request.
- Checks the complete call chain for a later operation that neutralizes the suspected effect.
- Exercises the real local engine, database, storage layer, or protocol when its semantics are load-bearing.
- Distinguishes "the code permits this outcome" from "production inputs reach this outcome."
- States what evidence would falsify the finding and whether that evidence was found.
- Records unresolved production reachability separately from the proven code behavior.

If the focused pass cannot establish the claimed consequence with high confidence, downgrade it to an open question or residual risk instead of presenting it as a Critical or High finding.
A contradictory result must remain in the report and must not be explained away to preserve the original theory.

## Finding admission and severity

Admit only actionable, high-confidence defects with a concrete consequence.
Do not report style preferences, speculative concerns, generic best practices, or unrelated debt as findings.
A missing PR description may be a finding only when the missing intent creates a concrete review, deployment, migration, or operational risk.

Use these review severities consistently:

- **Critical**: demonstrated security compromise, irreversible or widespread data loss, or another immediate release-stopping consequence.
- **High**: demonstrated serious correctness, security, data-integrity, or public-contract failure with substantial impact.
- **Medium**: demonstrated bounded correctness, integration, migration, build, CI, or operability defect that should be fixed before or soon after merge depending on reachability.
- **Low**: demonstrated limited-impact defect with a worthwhile concrete correction.

The report verdict follows the evidence:

- **Approve** when there are no blocking findings.
- **Approve with follow-ups** when only clearly non-blocking findings remain.
- **Request changes** when any Critical, High, or blocking Medium finding remains.
- **Evidence incomplete** when a load-bearing unknown prevents a responsible merge recommendation.

A nuanced explanation may distinguish a sound core feature from adjacent breakage, but it must still choose one verdict from this list.
The verdict is a recommendation in the report and is never submitted to the forge by this procedure.

## Durable report contract

Write the report to the task's supplied `data/<id>/report.md` path, never only to `/tmp`.
Use this structure:

```markdown
# Review: <repository> PR #<number> - "<title>"

Reviewed head `<head-sha>` against base tip `<base-sha>` with merge base `<merge-base-sha>`.
State the read-only boundary, final project-copy cleanliness, and forge-check snapshot.

## Verdict

**<Approve | Approve with follow-ups | Request changes | Evidence incomplete>.**
Give the evidence-first rationale.

## Findings

### 1. <SEVERITY> - <actionable title>

- **Scope:** <introduced | amplified>
- **Where:** `<path:line-range>`
- **Observed behavior:** <executed or directly inspected evidence>
- **Trigger and masking conditions:** <when it occurs and what can hide it>
- **Consequence:** <user, data, security, integration, or operational impact>
- **Recommendation:** <smallest adequate correction>
- **Falsifier or uncertainty:** <what would disprove it or what remains unverified>

Write **No findings** when none meet the admission bar.

## Validated behavior

Record the important pull-request claims that were positively verified.

## Checks run

| Check | Result |
|---|---|
| `<exact command or evidence source>` | `<result>` |

## Action items

1. Address Finding 1 before merge.
2. Track any accepted non-blocking follow-up explicitly.

## Residual risks

List production-only uncertainty, adjacent pre-existing debt, and unavailable-environment limitations that are not findings.
```

Keep recommendations proportional and implementation-neutral.
Do not write replacement code unless a minimal snippet is necessary to make the recommendation unambiguous.

## Completion and captain handoff

Before treating the review as complete, follow `captain-hold-lifecycle` when the report exposes an unresolved captain decision.
Confirm the report names the exact reviewed SHA, contains the verdict and ordered action items, records the checks run, distinguishes findings from residual risks, and confirms a clean project copy.

Firstmate reads the report as evidence and relays a concise captain-facing summary with the verdict, highest-severity findings, ordered action items, full pull-request URL, and durable report path.
Do not paste raw worker output or internal lifecycle labels into captain chat.
Do not post findings to GitHub or start fixes unless the captain separately requests that concrete action.
