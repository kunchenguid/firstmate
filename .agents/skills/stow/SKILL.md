---
name: stow
description: Sweep the current session for uncaptured durable knowledge, file it to disk, persist the open work records this session knows are unfiled or now wrong, and curate the home's startup memory before a context reset. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge and open-work state that exist only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
Stale material retires to a cold archive instead of being deleted.
This skill writes only through the existing Firstmate ownership and write boundaries.

Four things were abolished on 2026-08-26 and must not come back (`regeln/ABGESCHAFFT.md`): the seven-field completion receipt, the verb vocabulary policing that went with it, the tier-marker microformat, and the unreinforced-pass counter.
Report the outcome in plain captain-facing language instead; the sweep is judged by what it filed, never by the shape of its report.

## Memory files and what belongs in them

Three files, each read completely on every pass:

- `data/captain.md` - this home's captain preferences and authority boundaries.
- `data/captain-shared.md` - the fleet-wide shared preferences. Main-authoritative in the primary home, **read-only** in a secondmate home: count it, never edit it, and route a needed change to the primary owner.
- `data/learnings.md` - operational facts. Create it only for a genuinely new local learning with no stronger owner.

Keep in always-loaded memory only current captain preferences, authority and safety boundaries, recurring working style, fleet-wide or frequently relevant operating facts, and concise pointers that are expensive to rediscover.
Everything else belongs somewhere with a real reader: current-but-conditional knowledge goes to a just-in-time owner, and stale, superseded, or low-recurrence material goes to the cold archive.
Preferences and authority boundaries do not age; operational facts do, and one that has stopped being exercised is a candidate for the archive rather than something to keep by inertia.
An entry that names a checkable expiry condition - a backlog id, a version floor, a dated expectation - is judged against that condition; one that cannot name any is simply a durable fact.
Treat an absent local file as absent, not as an invitation to manufacture content.

## The pass

Every `/stow` performs this pass, even when the session produced no new finding.

1. Run `bin/fm-startup-memory-budget.sh report` and record the effective budget plus each file's estimated total.
   The budget is per home, never a fleet total, and its estimate is a documented conservative approximation.
   If the helper rejects the setting or a file, report that concrete exception and do not call the session reset-safe.
2. Read all three files completely and build one whole-file retention plan before editing, ordered by likelihood of informing a future session.
3. Refresh or retire.
   Update an entry only when this session actually exercised, confirmed, or re-derived it - **plausibility, importance, and the entry's own text are not evidence**.
   Re-validate a fact that has gone stale from current evidence, or archive it.
   Re-confirm an entry with a named expiry condition against that condition: still open means keep, while resolved or no longer checkable means archive it in this pass.
4. Consolidate every file, not only the one a new finding touched: one concise current rule or authoritative pointer beats duplicate prose.
   Archive completed incident chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, and report-sized procedures.
   Merge or remove only superseded claims and duplicates whose facts survive elsewhere - **never plainly remove a unique current fact**; every exit archives it with provenance, relocates it to a live owner, or merges it somewhere the fact is preserved.
5. If still over budget, reduce in this order: archive everything eligible, consolidate tighter, run the offload sweep below and relocate every eligible conditional entry into an already-existing owner (only after that owner holds it), then archive the oldest-unexercised operational facts until within budget.
   A proposal, a future migration, or an accepted exception is never budget relief.
   Before evicting anything, check that archiving the whole eligible pool would actually reach the budget; when it cannot, skip that step entirely and carry the concrete inability forward.
   Preferences and authority boundaries are never moved automatically - only a captain-approved, per-item relocation may move one.
6. Re-run the budget report.
   Finish at or below budget, or open one concrete captain decision naming the shortfall and the safe action still required.
   A secondmate whose inherited shared file alone exceeds its allowance reports that to the primary owner, because local curation cannot resolve it.
   Never end a pass over budget as an accepted exception, and never describe a session as reset-safe while it is.

A net increase is allowed only for a genuinely new current fact with no stronger owner, and only after consolidating enough lower-priority material to stay within budget.

## The cold tier: data/memory-archive.md

Stale never means deleted: pruning an entry always means moving it to `data/memory-archive.md`, this home's append-only, never-injected, never-budget-counted cold tier.
Each archived entry keeps its provenance under a dated pass heading - source file, when it was last confirmed, and why it left - because the cold tier can afford verbosity.
Archiving is a move, so recovery is `grep` plus copy back with no tooling.
Each home keeps its own archive, the archive never cascades, and truncating a grown one is a captain decision, not a mechanism.

## Offload to just-in-time owners

Decay handles staleness; offload handles scope - knowledge that is current and durable but relevant only in a nameable context, and therefore wrong to pay for in every session of every fleet member.
It runs only when the pass is still over budget after archiving and consolidation, and it is an immediate reduction into an owner that already exists, never a deferred proposal that leaves the pass over budget.
Judge staleness first: offload never moves a stale fact anywhere.
A candidate must be editable here, durable, non-pinned, conditional on a one-line nameable trigger, fat enough to matter (roughly 50 estimated tokens or more, largest first), and matched to a destination that fits its privacy.

**Hard rule: the stow pass never creates or writes a firstmate-repo-tracked skill.**
Approved destinations are an already-existing user-owned local note or local skill under the active home's repository-local exclude file (resolved with `git -C "$home_root" rev-parse --git-path info/exclude`, with `home_root` being `$FM_HOME` when set and the Firstmate code root otherwise), or a project's existing committed `AGENTS.md` or project-level skill through that project's registered delivery path.
Forbidden: any tracked firstmate skill, firstmate's own `AGENTS.md` (always loaded for every session), `docs/` alone (never agent-loaded on demand, though a skill body may point into it), and any committed surface for private content.
A local destination exists only in this home, so offloading an entry out of `data/captain-shared.md` removes it from every inheriting home - the default for shared entries is keep.
An entry leaves memory only once its destination is live, so knowledge is never in limbo between owners; a captain-approved relocation of a pinned preference is migrated outside this pass, and a failed migration leaves neither partial content nor a partial exclude rule behind.

## Knowledge sweep and routing

Sweep the session for uncaptured operational learnings, captain preferences expressed in passing, project-intrinsic facts, standing decisions, and undone next steps, then route each finding by one question: **who reads this at the point of action?**
If nobody does, it belongs in `regeln/` or `docs/`, not in memory.

- Captain preferences and fleet-local operational facts go into the memory file above after the whole-file curation pass.
  In a secondmate home, route a newly discovered shared preference to the main firstmate through marked status or a document pointer instead of editing the inherited file.
- Project-intrinsic knowledge never goes directly into a project's `AGENTS.md`; route it through a normal ship task using `bin/fm-ensure-agents-md.sh` and the project's delivery path.
- Knowledge general to every Firstmate user goes into this repo's shared tracked material through the normal branch, gate, PR, and merge path.
- For a task-scoped note, inspect with `tasks-axi show <id> --full`, classify the change as new, duplicate, superseding, or obsolete, then write a considered replacement body through `tasks-axi update <id> --body-file <path>` (`--archive-body` when recoverability matters). Never append.
- File each undone next step as a queued backlog item with a genuine `blocked-by` dependency where one applies.

For every retained fact, ask which current statement it supersedes and whether it can be a one-sentence rewrite.

## Open-record persistence

The sweep above preserves knowledge; this one preserves the state of work.
A reset destroys whatever exists only in this session, including what you have learned about work already under way.
So before the reset, file what was never filed and correct what you now know is stale, writing each thing through the owner that already governs that record.
One bound holds: this covers the open work you are actually holding in context, not the records at large - it is not a reconciliation of durable records against repository or forge reality and must never be reported as one.
Where the right correction is a judgment you cannot make, leave the record alone and raise the question instead of guessing.

## Reporting and cascade

Say in plain captain-facing language what changed: the budget before and after, what was filed and where, what was archived and why, what was offloaded and to which live destination, every unresolved exception, and each open record this pass filed, corrected, or deliberately left alone with the judgment it is waiting on.
Call the session reset-safe only when every durable finding is captured, every open record this session held is filed or explicitly left with its reason, and the result is within budget with no pending decision - and say what that claim means in the same breath: nothing this session knew has been lost, which is never a claim that the home's durable records are correct.

In a primary home, run `bin/fm-stow-cascade.sh` after this home's own pass; its header owns the stanza fields, bound, and exit codes.
Act on each home by its reported `transport`: `agent` sends the marked request so the live secondmate performs its own `/stow` (read its reply from its status file or the document it points to, never from chat); `direct` means curating that local home's editable files yourself under the same retention plan, then re-running the cascade to confirm; `deferred` is a remote home with no live agent, accounted read-only and reported as an unresolved exception (relaunching it is `secondmate-provisioning`'s decision, never stow's); `unavailable` means that home's accounting did not complete - report it and continue, because a slow home never blocks this one.
Every home is judged against its own allowance, so never add homes together.
Offload proposals and the cold archive are per-home and never cascade.
In a secondmate home, `/stow` curates that home only.
