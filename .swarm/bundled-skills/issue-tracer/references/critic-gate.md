# Independent Critic Gate

This reference drives three independent gates: the Phase 3 plan critic, the Phase 4.5 implementation review, and the Phase 4.6 final critic. Each is adversarial and independent - it does not improve wording; it tries to prove the work is not done. None of them writes production code.

Every verdict artifact records both `reviewed-commit` (`git rev-parse HEAD`) and `tree-id` (the output of `trace-check.sh tree-id`) under the `## Reviewed SHA / diff hash` heading, as exactly two lines: `reviewed-commit: <40-hex sha>` and `tree-id: <40-hex tree-id>`. `trace-check.sh` requires these two lines and requires their values to equal the corresponding `## Gates` row's `reviewed-commit`/`tree-id` cells for that gate (plan-critic for `06-critic-review.md`, implementation-review for `08b-implementation-review.md`, final-critic for `09-final-critic.md`). Closure requires the final-approval identities to equal the shipped HEAD; a later edit invalidates the approval and re-runs the affected gate. Freshness is checked by comparing identities, never by recollection.

Before any fallback pass: attempt the delegation mechanism and record the verbatim tool-call error, or quote the user/session text forbidding subagents. If authorization is merely unclear and the session is interactive, ask the user. Non-interactive sessions may fall back only with the recorded failure output, stated in the artifact.

## Plan Critic (Phase 3)

Use before presenting the plan to the user. The critic reviews only evidence and plan quality and tries to prove the plan would fail to fully close the issue and its defect class.

### Preferred Invocation

If subagent delegation is available, launch a separate critic with this prompt:

```markdown
You are an independent critic reviewing an issue-tracer fix plan before implementation.

Your task is to find gaps, unwired functionality, unsupported assumptions, missed edge cases, missing tests, unsafe scope, an under-scoped defect-class sweep, and root-cause errors.

Read these artifacts:
- 01-issue-summary.md
- 02-reproduction.md (including the `## Acceptance checks` table)
- 03-localization-log.md
- 04-root-cause.md
- 05-fix-plan.md
- repro/checkpoint.manifest and every check/fixture/helper file it lists
- both identities (`reviewed-commit`, `tree-id`) from state.md

Also inspect any files referenced in the plan. Do not trust summaries if the underlying code is available. Independently replay the frozen acceptance checks yourself (`repro-check.sh run` for each row) before returning a verdict - do not accept the table's pre-fix column on faith.

When a checkpoint anchor exists, independently compare the externally published receipt with `repro-check.sh verify-anchor --slug <slug> --receipt '<literal>'`; this verifies the local manifest/table/tree digests only, while publication and its timing remain a human gate that the validator cannot observe. Do not accept a receipt regenerated after implementation began.

Return exactly:

# Critic Review

## Reviewed SHA / diff hash
reviewed-commit: <40-hex sha you examined>
tree-id: <40-hex tree-id from `trace-check.sh tree-id`>

## Round 1
[The first round of this critic loop uses "## Round 1"; a second round appends "## Round 2", a third "## Round 3", and so on - one heading per round, never renumbered. `trace-check.sh` requires at least one heading matching `^## Round [0-9]+$`. Summarize what changed since the prior round, or state this is the first pass.]

## Verdict
APPROVE / NEEDS_REVISION / BLOCKED

## Check replay
[For each row in the Acceptance checks table: did you independently reproduce the recorded pre-fix result? Any discrepancy is a blocker.]

## Evidence Sufficiency
[Is root cause proven? What evidence is missing?]

## Plan Correctness
[Would the selected fix address the root cause?]

## Unwired Functionality
[Any entry point, export, caller, config, route, UI path, CLI path, docs path, or test path not connected?]

## Edge Cases
[Missed null/empty/error/concurrent/idempotent/security/backward-compat cases.]

## Defect-Class Sweep
[Is the anticipated Phase 4.2 sweep scoped to the real class, or too narrow?]

## Test Gaps
[Positive, negative, regression, integration, fixture, drift, and adversarial gaps.]

## Scope Risk
[Overreach, underreach, public API, migration, external service, or rollout risks.]

## Required Revisions
- [Required change or NONE]
```

### Fallback Invocation

If no independent subagent is available, create `06-critic-review.md` with the same headings (including `## Reviewed SHA / diff hash`) in one clean adversarial pass, prefixed with "Fallback self-critic: independent critic unavailable." Do not leave a stub artifact containing only the disclosure.

### Required Critic Questions

The critic must answer:

1. Does the reproduction actually match the issue, or did the tracer reproduce a nearby symptom?
2. Is the claimed root cause necessary and sufficient?
3. Could the fix make the test pass while leaving the real runtime path unwired?
4. Are all callers/importers/entry points covered?
5. Are config defaults, feature flags, docs, and generated code surfaces considered?
6. Are both positive and negative tests included?
7. Are boundary cases covered: null, empty, missing, malformed, duplicate, concurrent, retry, cancellation, timeout, permission denied, and partial failure?
8. Does the patch preserve public API and backward compatibility?
9. Does the plan avoid broad refactors and unrelated cleanup? (The Phase 4.2 defect-class sweep is in-scope by definition and is NOT "unrelated cleanup".)
10. Is rollback straightforward?
11. If the fix's exact invocation depends on subtle CLI/subprocess/flag semantics (git flags, gitignore anchoring, shell globs), was the exact candidate invocation empirically verified in an isolated environment - not just asserted as correct?
12. If the fix scopes or restricts a destructive/broad-acting operation, was it checked against the real target's full blast radius (a dry-run against the actual environment), not only a minimal reproduction?
13. Do the DISCRIMINATING checks actually fail on the pre-fix tree for the reported reason, not a vacuous or unrelated failure?
14. Do the PRESERVING checks cover the exact callers the impact analysis named?
15. Is every numbered acceptance criterion covered by exactly one typed row?
16. Is each NON-EXECUTABLE row justified with named substitute evidence, and not a shortcut around a feasible executable check?
17. Is each `--expect` regex specific enough to distinguish the reported failure from an unrelated one?

### Verdict Semantics

- `APPROVE`: No blocker remains. Implementation can proceed after user approval.
- `NEEDS_REVISION`: The plan is probably fixable, but one or more revisions are required before user approval.
- `BLOCKED`: The plan lacks enough evidence, has a wrong root cause, requires a product decision, or needs unavailable context.

### Revision Rules

If the critic returns `NEEDS_REVISION` or `BLOCKED`: revise `05-fix-plan.md`, record the response to every critic item, and re-run the critic, appending a new `## Round N` section for each cycle. Do not present the plan as ready until blockers are resolved or explicitly escalated. **Loop bound:** after three `## Round N` sections without convergence, stop and escalate to the user with both positions and the evidence, or record the user's explicit instruction to continue past the bound, quoted verbatim. Never resolve a deadlock by rewording a blocker.

### Delegation failure

If delegation genuinely fails (no independent context available and the fallback applies), the fallback artifact must still contain a `## Delegation failure` section with a fenced block holding the verbatim tool-call error or the quoted user/session text forbidding subagents. The validator checks only that the section and fenced block are present; distinguishing real tool-call output from invented prose is a reviewer/critic judgment, not something a grep can certify.

### Cross-CLI invocation

When dispatching a critic through a separate CLI process rather than an in-session subagent tool, use role/tier placeholders, never a fixed vendor or model name, and confirm every flag against that CLI's own `--help` before relying on it (flags drift across versions). Example shapes, with `<model>` as a placeholder for whatever tier/role your session routes to:

```sh
<critic-cli> -p --model <model> --effort high --permission-mode plan --allowedTools "Read,Grep,Glob,Bash(git *)" < prompt.md
<critic-cli> exec -s read-only -m <model> -c model_reasoning_effort=<level> -o <verdict-file> - < prompt.md
```

Treat these as illustrative shapes, not verified invocations for any specific runner - verify against the actual CLI in use before trusting the flags.

## Implementation Review (Phase 4.5)

Use AFTER the fix is implemented and validated, to challenge the actual diff. It is independent of the Phase 3 plan critic: the plan critic challenges the plan; this reviewer challenges the real patch and its evidence. The context that wrote the patch must not be the only context that approves it.

### Reviewer Mission

Find a concrete case where the implemented patch is wrong, incomplete, overfits the regression test, leaves a runtime path unwired, misses a defect-class sibling, or regresses an existing contract. Verify claims against the real code and captured command output - do not trust the implementer's narrative.

### Reviewer Inputs (strict)

The reviewer receives ONLY: the full diff, `04-root-cause.md`, `07-approved-plan.md`, `08-test-results.md`, `08a-recurrence-sweep.md`, and the files the diff touches. It is NOT given the implementer's `05-fix-plan.md` reasoning or `06-critic-review.md` narrative - those can anchor the reviewer to the implementer's framing. Open the touched files; do not trust summaries.

### Preferred Invocation

If subagent delegation is available, launch a separate reviewer with this prompt:

```markdown
You are an independent implementation reviewer for an issue-tracer fix that has already been implemented and validated. Your job is to REFUTE it, not to agree with it.

Inputs (and only these):
- the full diff (e.g. `git diff origin/<default-branch>...HEAD`)
- 04-root-cause.md, 07-approved-plan.md, 08-test-results.md, 08a-recurrence-sweep.md
- the files the diff touches (open them; do not trust summaries)

Find, with concrete evidence:
- a specific input/environment/caller/sequence where the patch is wrong or incomplete
- whether the new test would still pass if the bug were only partially fixed (overfitting / plausible-not-correct)
- any changed path that is not wired into the real runtime path
- any defect-class sibling the Phase 4.2 sweep missed or misdispositioned
- any regressed public API, CLI, UI, config, persistence, or concurrency contract
- any "passed"/"validated" claim not backed by a shown command + output
- if the fix depends on CLI/subprocess/flag semantics, independently re-run the exact invocation yourself and confirm the observed behavior matches the claim
- if the fix scopes a destructive/broad-acting operation, independently re-check it against the real target's full blast radius
- independently re-run every acceptance check yourself with `repro-check.sh run` on both the pre-fix and current trees
- verify `repro-check.sh verify-checkpoint`, scan for tautological checks, and (at tier M/L, any risk trigger, or any NEW-SURFACE row) run the revert/mutation probe from `references/acceptance-checks.md`

When a checkpoint anchor exists, independently compare the externally published receipt with `repro-check.sh verify-anchor --slug <slug> --receipt '<literal>'`; this verifies the local manifest/table/tree digests only, while publication and its timing remain a human gate that the validator cannot observe. Do not accept a receipt regenerated after implementation began.

Return exactly:

# Implementation Review

## Reviewed SHA / diff hash
reviewed-commit: <40-hex sha you examined>
tree-id: <40-hex tree-id from `trace-check.sh tree-id`>

## Verdict
APPROVE / NEEDS_REVISION / BLOCKED

## Independently re-run
[Your own repro-check.sh run output for every check, on pre-fix and current trees - not the implementer's recorded results.]

## Check integrity
[verify-checkpoint output; tautology scan result; revert/mutation probe result where required.]

## Correctness vs Root Cause
[Does the diff fix the documented root cause, or only the symptom/test?]

## Overfitting Check
[Could the patch be wrong while still passing the new test? Show how or why not.]

## Unwired / Runtime-Path Gaps
[Entry points, exports, callers, config, routes, CLI/UI paths not connected.]

## Defect-Class Sweep Integrity
[Did Phase 4.2 characterize the class correctly, sweep completely, and install a guardrail that bites?]

## Contract & Regression Risk
[Public API, backward-compat, migration, concurrency, security.]

## Evidence Integrity
[Validation claims not backed by captured command output.]

## Deferred / Scoped-Out / Unwired
[Any work silently deferred, scoped out, or left unwired. State NONE only if truly none.]

## Required Revisions
- [Required change or NONE]
```

### Fallback Invocation

If no independent subagent is available, write `08b-implementation-review.md` using the same headings (including `## Reviewed SHA / diff hash` and `## Deferred / Scoped-Out / Unwired`) in one clean adversarial pass, prefixed with "Fallback self-review: independent reviewer unavailable." Do not leave a stub containing only the disclosure.

### Verdict Semantics

- `APPROVE`: no blocker remains; closure may proceed.
- `NEEDS_REVISION`: one or more code or evidence changes are required before closure.
- `BLOCKED`: the patch does not address the root cause, overfits, or needs context/decision the reviewer lacks.

### Revision Rules

Resolve every `NEEDS_REVISION`/`BLOCKED` item by changing code or capturing real evidence, then re-review. Do not downgrade a blocker by rewording it. Record the response to every reviewer item in `08b-implementation-review.md`. **Loop bound:** after three reviewer/critic revision cycles without convergence, stop and escalate to the user with both positions and evidence.

## Final Critic (Phase 4.6)

Use after the implementation reviewer has approved the current diff. This critic challenges the entire completion claim, including code, tests, docs, release notes, package metadata, validation evidence, and the reviewer artifact.

### Preferred Invocation

If subagent delegation is available, launch a separate critic with this prompt:

```markdown
You are the final critic for an issue-tracer implementation that already passed implementation review. Your job is to prove the completion claim is still wrong.

Inputs:
- the current full diff
- 01-issue-summary.md through 08b-implementation-review.md, including 08a-recurrence-sweep.md
- 08-test-results.md with captured command output
- all changed files

Check:
- the reviewer approval is on the latest diff (matching SHA/hash), not an earlier state
- every NEEDS_REVISION/BLOCKED reviewer item was actually fixed and re-reviewed
- docs, release notes, package metadata, CLI/API claims, and tests match the implemented behavior
- the Phase 4.2 guardrail exists and demonstrably bites
- every acceptance criterion maps to concrete evidence
- validation claims are backed by commands and output
- no work was silently deferred, scoped out, or left unwired
- if a checkpoint anchor exists, verify the externally published literal with `repro-check.sh verify-anchor` and record human confirmation that it was published before implementation (the local validator cannot verify publication or timing)

Return exactly:

# Final Critic

## Reviewed SHA / diff hash
reviewed-commit: <40-hex sha you examined; confirm it equals the shipped HEAD>
tree-id: <40-hex tree-id from `trace-check.sh tree-id`>

## Verdict
APPROVE / NEEDS_REVISION / BLOCKED

## Completion Integrity
[Does the current diff satisfy the issue, the Full-Resolution Contract, and the no-gap checklist?]

## Review Freshness
[Did reviewer approval happen on this exact SHA/hash?]

## Drift Check
[Any mismatch among code, tests, docs, release notes, package metadata, and final summary?]

## Acceptance criteria evidence
[For every numbered AC: the exact evidence (command + output, or test name) that closes it. An AC with no evidence blocks APPROVE.]

## Deferred / Scoped-Out / Unwired
[Any work silently deferred, scoped out, or left unwired. State NONE only if truly none.]

## Evidence Integrity
[Any unbacked validation or correctness claim?]

## Required Revisions
- [Required change or NONE]
```

### Fallback Invocation

If no independent critic is available, write `09-final-critic.md` with the same headings (including `## Reviewed SHA / diff hash` and `## Deferred / Scoped-Out / Unwired`) in one clean adversarial pass, prefixed with "Fallback final critic: independent critic unavailable." Do not leave a stub artifact containing only the disclosure.

### Verdict Semantics

- `APPROVE`: no blocker remains; closure may proceed if no later edit happens.
- `NEEDS_REVISION`: one or more code, docs, tests, or evidence changes are required before closure.
- `BLOCKED`: the completion claim depends on missing context or an unresolved decision.

Any edit after final critic approval invalidates the approval. Re-run implementation review when the edit changes the diff, then re-run the final critic. **Loop bound:** after three reviewer/critic revision cycles without convergence, stop and escalate to the user with both positions and evidence.
