# Backlog handoff

Load this with the `secondmate-provisioning` skill before handing main-backlog items to a secondmate.

Apply `AGENTS.md` section 10's work-items-only backlog contract before creation or handoff.
When a secondmate is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...
```

After seeding, run this handoff for the new secondmate's in-scope queued items.
For an existing or inherited domain, complete record intake first so no already-shipped plan row is handed off as open work.
For a local route, the helper resolves and validates the secondmate home from `data/secondmates.md`, then delegates the item move to `tasks-axi mv` (the single owner of the backlog format), which moves each named item - and a whole connected set, blocker plus dependents, atomically - from the main `data/backlog.md` into the secondmate home's `data/backlog.md`.
For a remote route, the same helper first moves the dependency-closed set atomically from the main backlog into `data/handoff/<id>.outbox.md`, then transfers that backlog-format outbox through `fm-on.sh` and lets the remote home's `fm-backlog-receive.sh` move every not-already-present key under the destination lock.
After a new local placement or a remote outbox receipt becomes durable, the helper attempts one marked routed-work instruction through the receiving secondmate's recorded endpoint.
[`bin/fm-backlog-handoff.sh`](../../../../bin/fm-backlog-handoff.sh) owns route-specific wake outcomes, remote outbox release after durable receipt, and stable wake-correlation retry behavior.
There is no two-phase handoff journal and no tasks-axi release beyond the already-required atomic `mv` capability.
Bootstrap retries pending outboxes and wakes when mutation is authorized and emits `SECONDMATE_HANDOFF:` for any outboxes that remain.
This delegated route remains required when `config/backlog-backend=manual`, which controls only routine firstmate backlog edits.
It moves each queued item's whole block - the `- [ ] <id> ...` header plus every following two-or-more-space-indented body line and blank separator, up to the next item or column-0 section heading - byte-exact under the same section, treating an indented `## ...` line as body rather than a section boundary, so neither the header nor its body is duplicated or orphaned.
It refuses a selected item with a single-space or tab-indented continuation rather than risk leaving content orphaned in the main backlog.
It accepts in-scope `## Queued` entries only and refuses `## In flight` and historical `## Done` entries.
Done records stay with their home for pruning or archiving.
It is idempotent; an item already in the secondmate backlog is skipped.
After a successful move it warns for any moved key that still owes a public relay reply bound to `main/<key>`, because that binding no longer names the home owning the work; rebind the commitment to `secondmate:<id>` through the `fmx-respond` promised-final procedure, which owns those commands.
That same rule governs routing generally: a Relay-linked request whose work goes to a secondmate cannot use the home-local mention link at all and needs a promised-final commitment bound to that secondmate's home.
It refuses any destination that is not a genuine seeded firstmate home with safe operational directories and a matching `.fm-secondmate-home` marker, so a move can never land in a project.
Do not hand off `local-only` items.
