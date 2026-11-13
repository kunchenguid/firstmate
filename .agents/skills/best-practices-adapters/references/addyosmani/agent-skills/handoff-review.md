# handoff.review: addyosmani/agent-skills

Extends what firstmate checks when a worker reports done, beside `validation-supervision`, `ship-landing`, and `scout-completion`, which keep owning the handoff.
Nothing here is a gate on the pipeline or a reason to hold work outside it.

## Every ship

Check that the done summary carries what the brief's practice section asks for: the checks run, the author's own review, the verification story, the doubt cycles and whether cross-model review was skipped, whether a `CONSTRAINTS.md` was present and followed, the sources when `source-driven-development` was routed, the "noticed but not touching" list, and the follow-up list with any code the change left unused.
On a risky change to a project that deploys from its default branch, check that the rollout and rollback plans are there.
A ship promoted from a scout through `bin/fm-promote.sh` keeps its scout composition, which omits the ship-only facets: promoted work follows firstmate's defaults for now, and the done-summary, doubt-cycle, and constraints expectations above do not apply to it at handoff, while the two checks below still do.
When the worker launched with `FM_BEST_PRACTICES_VERSION=missing`, check that the summary says it followed firstmate's defaults; when it launched with `unreviewed`, check that the summary names the unreviewed skills the spawn's notice named.
File each follow-up as its own work item with `bin/fm-tasks-axi.sh add`.

## Every scout

Hold each open question in the spec as its own captain decision under `captain-hold-lifecycle`, with `bin/fm-captain-hold.sh hold`.
Nothing is built until the captain's word, because a scout report is evidence, not authorization; implementation then goes through `bin/fm-promote.sh` or a new ship.

## A map scout

When the report is a capability map, bring it to the captain and hold its approval as a captain decision.
After the captain's word, dispatch one scout per module through the ordinary scout path, each with its own spec scoped to that module, in the map's build order, so a module's scout starts after the modules it depends on have their spec, which is the one true dependency `AGENTS.md` section 7 lets firstmate serialize on.
That follow-on dispatch is firstmate intake after this position, and each module scout is its own task with its own flow.
The approved map and the module specs land in the project, at its root as the pack says, through the ship that later implements them, since a scout commits nothing.

## An idea scout

When the report is an `idea-refine` one-pager, put the two or three directions it converged on on a review page for the captain to pick from, the board firstmate already uses for a visual deliverable, and hold its open questions as captain decisions the same way.
The one-pager stays in firstmate's records, the scout's report and the work item, rather than in the skill's `docs/ideas/` file in the project.
