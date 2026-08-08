---
name: stow
description: Sweep the current session for uncaptured durable knowledge and file it to disk before a context reset. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge that exists only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
This skill writes only through the existing Firstmate ownership and write boundaries.

## Required startup-memory pass

Every `/stow` invocation performs this complete pass, even when the session contains no new finding:

1. Run `bin/fm-startup-memory-budget.sh report` before considering a write.
   Record its effective budget and each file's estimated-token total.
   The budget is per home: this home's three files against this home's own allowance, never a fleet total.
   The helper's stable estimate is the documented conservative local approximation, not provider-exact accounting.
   If it rejects the setting or a memory file, do not infer a default or silently continue.
   Report that concrete exception and do not call the session reset-safe.
2. Read every current memory file completely: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`.
   Treat an absent local file as absent, not as an invitation to manufacture content.
   In a primary home, all three are curation inputs under their existing ownership rules.
   In a secondmate home, `data/captain-shared.md` is a read-only primary-owned input: count it, never edit it, and curate only the editable local files.
3. Build one whole-file retention plan before editing.
   Retain, in order: current captain preferences, authority and safety boundaries, and recurring working style; stable home-local operating facts that repeatedly affect future work and are expensive to rediscover; then concise pointers to an existing authoritative report, project document, configuration, or backlog item.
   Retain lower-priority material only while budget remains.
4. Consolidate every editable memory file as needed, not only the file apparently related to a new finding.
   Prefer one concise current rule or authoritative pointer over duplicate prose.
   Remove, merge, or route completed incident and release chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, superseded claims, duplicates, and report-sized procedures.
   Do not remove a unique current fact unless it is preserved directly elsewhere through a stronger existing owner.
5. Run `bin/fm-startup-memory-budget.sh report` again after the complete pass.
   Finish at or below the effective budget unless a concrete inability remains.
   A secondmate must explicitly report `primary-owned-shared-file-alone-exceeds-budget` when the inherited shared file alone exceeds its allowance, because local curation cannot resolve it.
   Any other unresolved excess must identify the fact that cannot safely be removed or routed and why.

A net increase is allowed only for a genuinely new current fact with no stronger owner.
Before allowing it, consolidate enough lower-priority material to remain within budget.
Never describe the session as reset-safe while the memory total is over budget or an exception is unresolved.

## Knowledge sweep and routing

1. **Sweep the session for uncaptured durable knowledge.**
   Look for operational learnings, captain preferences expressed in passing, project-intrinsic facts, standing decisions, and undone next steps.
2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md section 6 is the source of truth for destinations.
   Do not re-derive or duplicate that mapping here.
3. **Write within the existing boundaries.**
   - Captain preferences and fleet-local operational facts belong in the destination selected by AGENTS.md after the required whole-file curation pass.
     Create `data/learnings.md` only for a genuinely new local learning with no stronger owner.
   - In a primary home, curate shared captain preferences only under the existing primary-authoritative shared-preference contract.
     In a secondmate home, route a newly discovered shared preference to the main firstmate through marked status or a document pointer instead of editing the inherited file.
   - Project-intrinsic knowledge never goes directly into a project's `AGENTS.md`.
     Route it through a normal ship task so a crewmate records it with `bin/fm-ensure-agents-md.sh` and the project's delivery path.
   - Knowledge general to every Firstmate user belongs in this repo's shared tracked material through the normal branch, no-mistakes, PR, and captain-merge path.
   - For task-scoped notes, inspect the item with `tasks-axi show <id> --full`, classify the change as new, duplicate, superseding, or obsolete, then use a considered replacement body through `tasks-axi update <id> --body-file <path>`.
     Use `--archive-body` when recoverability matters.
     Never append.
   - File each undone next step as a queued backlog item with a genuine `blocked-by` dependency when applicable.
4. **Use inspect-then-update.**
   For every retained fact, ask which current statement it supersedes, whether it can be a one-sentence rewrite, and whether a stale entry should be deleted, retired, or routed to an existing stronger owner.
   The only graduation moves are promotion to tracked shared material through a PR, folding a learning into the captain-preference destination selected by AGENTS.md, or deletion of a stale entry.
   Do not invent another graduation path.

## Completion receipt

Report the outcome in plain captain-facing language with all of these facts:

- effective startup-memory budget and total estimated tokens before and after;
- one or more actions for each of `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`: `unchanged`, `added`, `rewritten`, `pruned`, or `routed`;
- each durable finding filed outside memory and its authoritative owner;
- every unresolved exception, including a primary-owned shared-file constraint in a secondmate home;
- whether the session is safe to reset, only when all durable findings are captured and the post-pass result is within budget with no exception.

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

Extend the completion receipt with one entry per secondmate alongside the primary's own, carrying that home's budget before and after, its per-file actions, its exceptions, and whether that home swept itself or was curated from here.
Keep those entries in the same plain captain-facing language the rest of the receipt uses.
The session is reset-safe only when every home is within its own budget with no unresolved exception.

## Scope exclusion: no skill storage

`/stow` must never store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
Until a human deliberately scopes a skill change as Firstmate repository work, route generalizable knowledge to shared tracked material through its pipeline and fleet-local knowledge to `data/`, never to `.agents/skills/` or public `skills/`.
