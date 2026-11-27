# stow: receipt and cascade

Reference of the `stow` skill, loaded on demand from its `SKILL.md` table; the always-resident rules stay in that `SKILL.md`.

## Completion receipt

Report the outcome in plain captain-facing language with all of these facts:

- effective startup-memory budget and total estimated tokens before and after, including the fourth-input accounting or exception from the startup-memory pass;
- one or more actions for each of `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, using only `unchanged`, `added`, `rewritten`, `pruned`, `routed`, `archived`, or `proposed-offload`; adding or replacing a migration marker is `rewritten`, never a new action verb such as `migrated`;
- each durable finding filed outside memory and its authoritative owner, including every capture to a declared memory tier;
- every finding or entry a declared tier should hold but this session could not reach, left carrying its pending-capture marker and named so a session that can reach it captures it;
- each archived entry's reason, each autonomous offload's live destination and actual relief, and, when a pinned candidate was proposed, the `proposed-offload` section with every candidate's fields;
- every unresolved exception, including a primary-owned shared-file constraint in a secondmate home, and every concrete captain decision opened for an over-budget result;
- each open record this pass filed or corrected, and each one it deliberately left alone with the judgment it is waiting on;
- whether the session is safe to reset, only when all durable findings are captured, no tier-owned finding is waiting on an unreachable declared tier, every open record this session held is filed or explicitly left with its reason, and the post-pass result is within budget with no exception or pending budget decision.

State what reset-safe means in the same breath as the claim: nothing this session knew has been lost.
It is never a claim that the home's durable records are correct, because this pass checks no record the session did not name.
Do not hide an over-budget result behind a reset-safe claim.
In a primary home the receipt is written after the cascade below, not instead of it.

## Automatic cascade to secondmates

In a primary home, every `/stow` cascades to every registered secondmate after this home's own required pass and knowledge sweep are complete.
In a secondmate home, `/stow` curates that home only and never cascades further.
The cascade changes nothing until `/stow` is invoked: it adds no notification, no digest section, and no background work.

Run `bin/fm-stow-cascade.sh` once the primary's own pass is done.
It enumerates each registered secondmate exactly once, reports that home's own budget accounting, and resolves how the sweep reaches it; its header owns the stanza fields, the bound, and the exit codes.
Every home is judged against its own `config/startup-memory-budget` allowance, so never add homes together or treat one home's excess as another's.

Act on each home by its reported `transport`:

- `agent` - send the marked request with `bin/fm-send.sh fm-<id> "<request>"` so the live secondmate performs its own `/stow`, including the uncaptured knowledge that exists only in its session.
  Ask it for the same completion receipt this skill defines, and read its reply from its status file or the document it points to, never from its chat.
- `direct` - curate that local home's editable memory files yourself under the same retention plan, then re-run the cascade to confirm the after totals.
  `data/captain-shared.md` stays a read-only counted input there, exactly as it is in any secondmate home.
- `deferred` - a remote home with no live agent. Its memory is accounted read-only and cannot be curated from here, because there is no generic remote write path for a home's own memory files.
  Report it as an unresolved exception and leave it to its next cascade.
  Relaunching that secondmate is a separate decision owned by `secondmate-provisioning`, never something `/stow` does on its own.
- `unavailable` - that home's own accounting did not complete. Report the concrete exception and continue; a slow or unreachable home never blocks this home's `/stow`.

A newly discovered shared captain preference still routes to the primary's `data/captain-shared.md` under the existing primary-authoritative contract, whichever home found it.
Offload proposals and the cold archive are per-home: file proposals only in the home whose pass produced them, and never cascade either to another home.

Extend the completion receipt with one entry per secondmate alongside the primary's own, carrying that home's budget before and after, its per-file actions, its exceptions, and whether that home swept itself or was curated from here.
Keep those entries in the same plain captain-facing language the rest of the receipt uses.
The session is reset-safe only when every home is within its own budget with no unresolved exception.
