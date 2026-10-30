# work: addyosmani/agent-skills

Extends the worker's `work` step only on a project whose delivery mode is `no-mistakes`, read from the brief in code; everywhere else `work` is untouched, because the slicing it needs is already in the floor, and no test-driven step is inserted before it.
`bin/fm-best-practices.sh` composes each `##` block below into the brief, where the block's heading is its id and a routing row in `manifest.json` may select it.

## doubt-cycle
On non-trivial decisions as `doubt-driven-development` defines them, run its in-flight doubt cycle, adapted in two places.
Skip the cross-model offer and announce the skip, which is the skill's own rule for a non-interactive context.
Turn three unresolved cycles into a `needs-decision:` status line to firstmate instead of a question to a user.
The cycle checks your own work before anything reaches the pipeline, and it is not a gate.
