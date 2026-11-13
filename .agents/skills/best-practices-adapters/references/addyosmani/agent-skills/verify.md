# verify: addyosmani/agent-skills

Extends the worker's `verify` step on ship tasks with the author's own passes; none of them is a review gate, and the pipeline's own review at `deliver` is untouched.
`bin/fm-best-practices.sh` composes each `##` block below into the brief, where the block's heading is its id and a routing row in `manifest.json` may select it; a block no row names is always composed.

## own-checks
Run the repository's own checks from the floor.

## five-axes
Then go through `code-review-and-quality`'s five axes, correctness, readability, architecture, security, and performance, as your own checklist before handoff.

## test-experiment
Answer by experiment on the tests, as that skill does: flip one condition the change adds, run the suite, and restore the file; a test that stays green names a missing test case.

## diff-guard
Run `constraint-driven-development`'s guard over your own diff, also as your own check: did a test get easier, did a checker get silenced, was work left unfinished.
When a `CONSTRAINTS.md` exists, also check whether a threshold moved or an exception appeared, and compare the change against any ratchet values in the file's "Measured, not yet enforced" table, using the commands the file names.
Fix what the guard finds or name it in your done summary.

## docs-drift
Check that the README, the API docs, and the user-facing docs reflect what the change did; follow a generated changelog's own convention and never hand-edit it.

## infrastructure
When your own diff touches deploy configuration, infrastructure definitions, or a migration, check `shipping-and-launch`'s code-side infrastructure items: a health endpoint exists, logging and error reporting are wired in, and any migration comes with a rollback plan.

## simplification-pass
Once the checks pass, make one behavior-preserving simplification pass over your own diff with `code-simplification`'s five principles, scoped to what changed, using `code-review-and-quality`'s Structural Remedies as the moves for what the five-axis check found, then run the checks again.
