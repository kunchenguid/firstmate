---
name: firstmate-development-loop
description: >-
  Agent-only Firstmate discipline for non-trivial implementation planning, ship execution, implementation review feedback, and completion claims.
  Use before commissioning or acting on a non-trivial implementation plan, before a ship worker changes code, when implementation review feedback arrives, and before reporting implementation complete.
  Owns plan checks, test-first behavioral evidence, technically rigorous review handling, and fresh verification without replacing diagnostic-reasoning, delivery authority, or worktree lifecycle.
metadata:
  internal: true
---

# firstmate-development-loop

Apply this as the single owner of Firstmate's implementation discipline.
Preserve the selected delivery path, approval authority, and project instructions.
Do not add an independent reviewer to `direct-PR` or `local-only`.

## Check the plan

1. Read the accepted intent, constraints, exclusions, acceptance criteria, and definition of done from the task instructions.
2. Inspect the relevant project instructions, current implementation, tests, and history in proportion to the change.
3. For non-trivial work, identify the smallest independently verifiable increments, the files or public surfaces each increment is expected to affect, and the test or observation that will prove it.
4. Include compatibility, migration, rollout, rollback, and documentation work only when the accepted change needs them.
5. Review an existing plan against the current repository before executing it, and surface any contradiction, missing prerequisite, or ambiguity that could materially change scope or behavior.
6. Escalate a material plan conflict through the task's normal decision path instead of guessing, while making harmless implementation-detail adjustments transparently.
7. Keep a simple change's plan proportionate, and do not create a persistent design document unless the task requests one or the result must survive as a scout report.

A plan or scout recommendation is evidence, not implementation authority.
Use `decision-hold-lifecycle` for unresolved captain decisions discovered by a plan or review.

## Establish behavioral proof before production changes

1. Name the observable behavior or executable contract being changed.
2. Write the smallest behavioral test that demonstrates the missing or incorrect behavior before changing production code.
3. Run that test and confirm it fails for the expected behavioral reason rather than a fixture, syntax, environment, or unrelated failure.
4. Make the smallest production change that satisfies the test, then run the same test and confirm it passes.
5. Refactor only while the focused test stays green, then run the relevant surrounding regression checks.
6. For a bug fix, turn the end-user-aligned reproduction from `diagnostic-reasoning` into the regression test and preserve the red-to-green evidence.

Do not add production hooks solely to make a test possible, and prefer testing through a public or executable behavior over implementation-source assertions.
When a change has no meaningful executable contract, such as prose-only or metadata-only work, state why test-first does not apply and choose the closest fresh deterministic validation instead.
When the repository has no safe test harness for the behavior, record that limitation and establish the closest representative failing proof without presenting it as equivalent evidence.

## Handle implementation review feedback

1. Separate each review item and locate the requirement, code path, and evidence it depends on.
2. Verify the reviewer's technical claim against the current branch before accepting or rejecting it.
3. Ask one precise question when feedback is ambiguous, conflicts with accepted intent, or cannot be verified safely.
4. Address one coherent item at a time and run its covering test before moving to the next item.
5. Push back with code, requirement, or test evidence when a suggestion is incorrect or adds unrequested scope.
6. Re-read the complete branch diff and rerun the affected checks after the final feedback fix.

Treat review as technical input, not authority to bypass the task's accepted scope or Firstmate's decision boundaries.

## Verify before reporting completion

1. Translate every material completion claim into a command or observable check that proves it on the final task head.
2. Run the focused behavioral tests plus the relevant regression, build, lint, type, documentation, or integration checks required by the project and accepted scope.
3. Read the fresh exit status and output, and distinguish pre-existing or environmental failures from evidence about the change.
4. Confirm the final diff contains the accepted behavior, required tests, and no unintended scope before opening a PR or reporting a ready branch.
5. Report the exact checks and results with the task outcome, and name any check that could not run instead of calling the work fully verified.

Earlier output, a different commit, a worker's confidence, and a review verdict are not substitutes for fresh evidence from the final code.
For `direct-PR`, run focused and relevant behavioral checks, then the canonical zero-token verifier before push, and require terminal checks for the recorded exact PR head before completion.
