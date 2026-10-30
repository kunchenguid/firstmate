# brief.done: addyosmani/agent-skills

Extends the generated Definition of done in ship briefs; it adds to the done summary and changes nothing about how the work is delivered.
`bin/fm-best-practices.sh` composes each `##` block below into the brief, where the block's heading is its id and a routing row in `manifest.json` may select it; a block no row names is always composed.

## verification-summary
Your done summary also names the checks you ran and your own review of the change.
It carries `code-review-and-quality`'s verification story: the tests run, whether the build passed, what you tested by hand, and screenshots with a before and after for a UI change.
It names the doubt cycles you ran, if any, and whether cross-model review was skipped.
It says whether a `CONSTRAINTS.md` was present and followed.
It ends with the follow-up list, which also carries any code the change left unused, in place of the skill's "ask before deleting" stop.

## source-citations
When you followed `source-driven-development`, list the sources it had you cite.

## rollout-rollback
On a project that deploys from its default branch, a risky change, meaning irreversible blast radius, a production deploy path, a data migration, or a public API change as `doubt-driven-development` defines them, also carries `shipping-and-launch`'s two plans in short written form, in your done summary and in any PR body you write.
The rollout plan names the stages, what to watch at each, and when to hold.
The rollback plan names its trigger, its steps, and whether any database change can be reversed.
