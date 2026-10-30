# landing.post-merge: addyosmani/agent-skills

Pairs with firstmate's landing, firstmate's first: finish the landing `ship-landing` owns, then, only on a project that deploys from its default branch, run the post-launch verification below.
A project that does not deploy from its default branch gets firstmate's landing alone.

## Dispatch a verification scout

Firstmate does no project work itself, so file one work item and dispatch a small verification scout through the path it already has: `bin/fm-brief.sh <id> <project> --scout --best-practices addyosmani/agent-skills`, `bin/fm-spawn.sh <id> <project-dir> --scout`, and the report back through `scout-completion`.
The scout is its own task with its own flow and no delivery or landing of its own, and the ship's own `cleanup.record` does not wait for it.

## What the scout checks

The scout runs `shipping-and-launch`'s post-launch checks as observation only, reported and never gated on:

- the health endpoint returns 200;
- monitoring shows no new error types;
- latency shows no regression;
- the critical user flow works when tried by hand;
- logs are flowing and readable;
- when the project has an SLO dashboard, the error-budget burn rate.

The skill's sixth item, the rollback dry run, is converted: the scout reports whether a rollback path exists and, where a dry run is warranted, raises it as a `needs-decision` instead of running one, because a dry run can change production and that sits with the off-limits rules.
Its findings reach the captain as findings, the way every scout's do.
