---
name: stow
description: >-
  Sweep the session for uncaptured durable knowledge and unfiled or wrong open work records, and curate startup memory.
  Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), on a startup-growth "run the stow pass" wake, before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge and open-work record state that exist only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
Memory entries are tiered and decay between passes, and stale material retires to a cold archive instead of being deleted.
This skill writes only through the existing Firstmate ownership and write boundaries.

## Reference files

Files under `references/` are resources of this skill, not additional catalogued skills.
Their text moved verbatim, so "above" or "below" may name a heading in another file of this skill; the table locates each one.

Every `/stow` performs the whole sequence: the required startup-memory pass, the knowledge sweep, open-record persistence, the completion receipt, and in a primary home the cascade.

| Read | When |
| --- | --- |
| `references/memory-tiers.md` ("Memory tiers and entry markers", "Optional pass horizon") | reading, writing, or judging any memory marker, tier, or clock |
| `references/startup-memory-pass.md` ("Required startup-memory pass", "The cold tier", "One-time migration of unmarked entries") | running the required pass, including the active Claude auto-memory index, archiving an entry, or meeting an unmarked legacy entry |
| `references/offload.md` ("Over-budget offload to JIT-loaded owners", "Destinations", "Flow") | the pass is still over budget after decay and consolidation, or a pinned offload is proposed or approved |
| `references/knowledge-sweep.md` ("Knowledge sweep and routing", "Open-record persistence") | sweeping the session for findings and open work records |
| `references/receipt-and-cascade.md` ("Completion receipt", "Automatic cascade to secondmates") | writing the receipt, or cascading from a primary home to its secondmates |

## Rules that hold without a reference loaded

A net increase is allowed only for a genuinely new current fact with no stronger owner.
Before allowing it, consolidate enough lower-priority material to remain within budget.
Never describe the session as reset-safe while the memory total is over budget or an exception is unresolved.

Stale never means deleted: pruning an entry from an editable memory file always means moving it to `data/memory-archive.md`, this home's append-only, never-injected cold tier, gitignored with the rest of `data/` and never counted by the budget report.

**Hard rule: the stow process never creates or writes a firstmate-repo-tracked skill.**
**Every skill stow's offload produces for a Firstmate home is user-owned and local, excluded through that active home's repository-local exclude file resolved with `git -C "$home_root" rev-parse --git-path info/exclude`; contributing a lesson to the shared tracked template is a separate deliberate captain action, never automatic.**
Approved project-level destinations are not produced by stow: they ship normally through that project's own registered delivery path.

## Scope exclusion: no skill storage by the pass

The stow pass itself must never store, create, or edit a skill as a destination for any finding.
The exclusion binds the pass as a writer: proposing an offload and letting the migration step execute a captain-approved candidate later is not the pass storing a skill.
Every Firstmate-home skill that migration produces is user-owned and local under the destinations hard rule, while an approved project-level destination is produced and shipped through that project's registered delivery path, never by stow.
Changing firstmate's tracked `.agents/skills/` or public `skills/` remains a deliberately scoped Firstmate repository task through its pipeline, gated by this home's firstmate-repository publication authority, never a stow product.
Outside a captain-approved offload, generalizable knowledge still routes to shared tracked material through its pipeline where that authority exists and to `data/` otherwise, and fleet-local knowledge to `data/` or to the declared memory tier that owns its class.
