---
name: stow
description: Sweep the current session for uncaptured durable knowledge, file it to disk, persist the open work records this session knows are unfiled or now wrong, and curate the home's tiered, decaying startup memory before a context reset. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge and open-work record state that exist only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
Memory entries are tiered and decay between passes, and stale material retires to a cold archive instead of being deleted.
This skill writes only through the existing Firstmate ownership and write boundaries.

## Memory tiers and entry markers

Markers are compact trailing HTML comments, deliberately cheap because marker bytes are counted content:

- `<!--a:YYYY-MM-DD-->` - an `aging` entry; the embedded date is its last-reinforced date.
- `<!--p:YYYY-MM-DD-->` - a `perishable` entry; the embedded date is its last-reinforced date.
- `<!--P-->` - an explicitly `pinned` entry in a file whose default tier is not `pinned`.
- `<!--g-->` - migration-only: an unconfirmed legacy entry that has consumed its one grace cycle, carrying no date because grace is not reinforcement.

```markdown
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-08-03-->
- While state/.afk exists, the away-daemon owns triage (until the afk-wake fix lands; tracked: afk-pi-wake-bypass-r1). <!--p:2026-07-20-->
- Never restart the shared no-mistakes daemon while runs are active. <!--P-->
```

The tier names say what the pass does with an entry:

- `pinned` - no clock is ever read for it: exempt from decay and from budget eviction, changed only through inspect-then-update when the captain or reality changes it, except that an explicit per-item captain approval may offload it under the flow below.
- `aging` - it must re-prove itself: an entry whose age is greater than or equal to 30 days since its last-reinforced date is stale, and a stale entry is re-validated (date refreshed) or archived, never kept by inertia alone.
- `perishable` - it is stored expecting disposal: an entry whose age is greater than or equal to 7 days since its last-reinforced date is stale, and its prose must name a checkable expiry condition, such as a backlog id, a version floor, or a dated expectation.
  An admitted durable entry that cannot name a checkable expiry condition is not `perishable` and must be stored as `aging`.
  Omission is reserved for non-durable material or facts already owned elsewhere.

Marking rules:

- Tier defaults are file-scoped: entries in `data/captain.md` and `data/captain-shared.md` default to `pinned` because preferences and authority boundaries do not age, and entries in `data/learnings.md` default to `aging` because operational facts must re-prove themselves.
- An entry matching its file's `pinned` default carries no marker at all; every `aging` and `perishable` entry always carries its dated marker, whose letter names the tier, so a clock-carrying entry is never ambiguous with unmarked legacy material.
- Marker and header-pointer bytes count toward the startup-memory budget: the pass's own bookkeeping is costed content, never free, which is why the spellings above are as short as they are.
- Each memory file's header carries at most a one-line pointer naming this skill as the scheme owner, such as `<!-- memory tiers: see the stow skill -->`.
  This skill text is the single owner of tier semantics, marker spellings, and clocks - deliberately policy, not configuration - and no memory file header may restate them.
- Inspect each editable file's header pointer on every pass and add or correct it; for a read-only `data/captain-shared.md`, leave the file byte-identical and route a missing or outdated pointer to the primary owner.
  The required receipt action for that file is `routed`, not `unchanged`; name the ownership exception and do not declare the session reset-safe.
- A pre-existing missing or hand-dropped marker is never grounds for destructive treatment: it means the file's default tier; an unmarked entry in a default-pinned file is simply pinned, while an unmarked entry in a file whose default tier carries a clock follows the migration rule below.

Decay advances only when a pass runs, so a home stowed less often than a clock experiences that clock at its stow interval.

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
   Every mutation in the rest of this pass, including reinforcement, retiering, decay archival, legacy migration, consolidation, budget archival, and offload, applies only to an editable memory file.
   When a read-only shared entry appears to require one of those changes, leave it untouched, report the required change as an ownership exception, and route it to the primary owner.
3. Build one whole-file retention plan before editing, ordered by likelihood of informing a future session.
   Keep in always-loaded memory only current captain preferences, authority and safety boundaries, recurring working style, fleet-wide or frequently relevant operating facts, and concise pointers that are expensive to rediscover.
   Prefer offloading current but conditional, narrow, project-specific, or context-specific material to a live on-demand owner, and archive stale, superseded, or low-recurrence material to the cold tier.
   Retain lower-utility material only while budget remains.
4. Reinforce and stamp.
   Refresh an entry's last-reinforced date to today only when this session actually exercised, confirmed, or re-derived it.
   **Hard rule: reinforcement requires independent evidence from this session that you can name in the receipt; plausibility, importance, prior knowledge, and the entry's own text are not evidence, and any explicit statement that no confirming session evidence exists requires the no-evidence path.**
   For an unmarked `data/learnings.md` entry with no such evidence, the no-evidence path is always to append `<!--g-->` and retain it for this entire pass; never stamp or archive it during that same invocation.
   Stamp each newly written entry with today's date and its tier per the marking rules, and admit a new `perishable` entry only with its named checkable expiry condition in the prose.
5. Evaluate every dated entry in each editable memory file against its tier clock.
   Re-validate a stale `aging` entry from current evidence and refresh its date, or archive it.
   Re-confirm a stale `perishable` entry against its named condition: still open means refresh the date, while resolved, expired, or no longer checkable means archive it in this pass.
   Promote `perishable` to `aging` when its condition keeps proving durable past its expected life, and retier in place when a supersession changes an entry's lifetime.
   `pinned` is exempt from this automatic decay step entirely.
6. Consolidate every editable memory file as needed, not only the file apparently related to a new finding.
   Prefer one concise current rule or authoritative pointer over duplicate prose.
   Archive completed incident and release chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, and report-sized procedures; merge or remove only superseded claims and duplicates whose facts are preserved elsewhere.
   Never plainly remove a unique current fact: every such exit must archive it with provenance in the recoverable cold tier or relocate it to a live JIT owner or a consolidation merge that preserves the fact.
7. When the total is still over budget after decay and consolidation, make aggressive reduction the default, using editable files only and in this order: archive every editable stale, superseded, or low-utility entry that is eligible for archival; consolidate tighter; run the over-budget offload sweep below and autonomously relocate every eligible non-pinned conditional entry into an already-existing allowed owner only after that owner holds it; then, only when the convergence precondition below holds, archive eligible `aging` entries oldest-reinforced-first until within budget.
   A proposal, a future migration, or an accepted exception is never budget relief in this pass.
   Budget eviction considers only editable `aging` entries that carry a last-reinforced date and are not pending offload; a `<!--g-->` legacy-grace entry is ineligible until its grace cycle resolves, so eviction can neither cancel a promised grace cycle nor prefer just-validated entries over unvalidated ones.
   Convergence precondition: before evicting anything, total the eligible pool and check that archiving all of it would reach the budget; when even that cannot, skip the eviction rung entirely, archive nothing for budget reasons, and carry the concrete inability to the final step, naming the exempt pinned floor that crowds out the budget.
   Automatic processes never move a `pinned` entry: decay clocks, legacy grace cycles, oldest-first budget eviction, immediate budget archiving, and autonomous offload do not apply to it.
   The sole exception is relocation to a JIT owner after explicit, per-item captain approval under the offload flow below, and that entry remains in memory until its destination is live.
8. Run `bin/fm-startup-memory-budget.sh report` again after the complete pass.
   Finish at or below the effective budget, or open a concrete captain decision before ending the pass.
   A secondmate must explicitly report `primary-owned-shared-file-alone-exceeds-budget` when the inherited shared file alone exceeds its allowance, because local curation cannot resolve it.
   Route that constraint to the primary owner and open one concrete captain decision at the primary owning level that names the shortfall, with exactly these options: raise the affected home's effective budget, or explicitly approve the primary owner trimming or offloading each named shared-file entry.
   When the convergence precondition skipped eviction, report the exempt pinned floor and the remaining shortfall as that concrete inability rather than archiving eligible knowledge that could not close the gap.
   Only after every safe non-pinned archival, consolidation, offload, and eligible eviction action is exhausted may a remaining excess be attributed to pinned safety, authority, or genuine captain-preference entries.
   In that last-resort case, create one captain-held decision that names the shortfall and each relevant pinned entry, with exactly these options: raise the effective budget, or explicitly approve offloading or trimming a named pinned entry.
   Route a read-only ownership constraint to its primary owner, and make every other unresolved excess a concrete captain decision that names the safe action still required.
   Never end a pass over budget as an accepted exception.

A net increase is allowed only for a genuinely new current fact with no stronger owner.
Before allowing it, consolidate enough lower-priority material to remain within budget.
Never describe the session as reset-safe while the memory total is over budget or an exception is unresolved.

## The cold tier: data/memory-archive.md

Stale never means deleted: pruning an entry from an editable memory file always means moving it to `data/memory-archive.md`, this home's append-only, never-injected cold tier, gitignored with the rest of `data/` and never counted by the budget report.
Each archived entry keeps its provenance under a dated pass heading: source file, tier, last-reinforced date, and the reason it left.
Archive provenance stays verbose rather than compact because the cold tier is never budget-counted.

```markdown
## 2026-08-08 stow
- (from learnings.md, tier: perishable, reinforced: 2026-06-30) While state/.afk exists, the away-daemon owns triage... [archived: unreinforced 39d]
```

Reasons include `unreinforced <N>d`, `budget oldest-first`, and `legacy-unvalidated`.
Archiving is a move, not a removal, and recovery is `grep` plus copy back with no tooling.
Each home keeps its own archive, the archive never cascades, and truncating a grown archive is a captain decision, not a mechanism.

## Over-budget offload to JIT-loaded owners

Decay handles staleness over time; offload handles scope: knowledge that is current and durable but relevant only in a nameable context, and therefore wrong to pay for in every session of every fleet member.
For the offload sweep's evaluation only, each entry has exactly three outcomes decided in this fixed order:

1. Archive, the time outcome, always evaluated first: staleness is judged before scope, and offload never moves a stale fact anywhere.
2. Offload, the scope outcome, asked only of current durable entries: is this needed in nearly every session, or only in a nameable context?
3. Keep, the default outcome for this sweep: current, durable, and either fleet-wide-relevant or safety-relevant even in sessions that never name the topic.

The offload sweep runs whenever the pass is still over budget after decay archiving and consolidation, so routine passes do not move entries speculatively.
It is an immediate reduction step for eligible non-pinned conditional material that can be added to an already-existing allowed owner, not a deferred proposal that leaves the pass over budget.
Every test must hold for a candidate:

- Editable source: this home owns the memory file and may relocate the entry; a read-only shared entry is routed to its primary owner instead.
- Durable: not `perishable`, not stale, and expected to remain true for months.
- Eligible by authority: only a non-pinned, dated `aging` entry that is not pending offload may be autonomously relocated to an already-existing allowed owner, while a `pinned` entry may be proposed only for explicit, per-item captain-approved relocation and can never be archived or autonomously offloaded for budget relief.
- Conditional: a one-line nameable trigger exists, and a session that never touches that trigger runs no risk from omitting the fact.
- Fat enough to matter: roughly 50 estimated tokens or more, handled largest-first, because consolidation handles smaller entries.
- A destination below fits the entry's privacy and visibility.
- Not already preserved by a stronger owner, which the consolidation counterweight already handles as ordinary curation rather than offload.

### Destinations

**Hard rule: the stow process never creates or writes a firstmate-repo-tracked skill.**
**Every skill stow's offload produces for a Firstmate home is user-owned and local, excluded through that active home's repository-local exclude file resolved with `git -C "$home_root" rev-parse --git-path info/exclude`; contributing a lesson to the shared tracked template is a separate deliberate captain action, never automatic.**
Approved project-level destinations are not produced by stow: they ship normally through that project's own registered delivery path.

- A user-owned local skill: a directory under `.agents/skills/<freeform-name>/` whose path is appended to the active home clone's repository-local exclude file, never to a `.gitignore`.
  Resolve `home_root` to `$FM_HOME` when it is set and otherwise to the Firstmate code root, and anchor every destination index check, exclude-path lookup, and ignore verification to that root with `git -C "$home_root"`.
  Before approval and again before migration, validate that the chosen freeform destination under `home_root` is absent from that home's git index and collides with no existing file or directory, and reject the destination if either check fails.
  The name is freeform with no user-vs-firstmate naming convention, the skill stays per-home and untracked, and the harness still lists and JIT-loads it because skill discovery scans the filesystem and ignores git status (verified in `docs/verification/stow-memory.md`).
  Its precise, condition-stated description line is its entire trigger; it gets no `AGENTS.md` declaration because `AGENTS.md` is shared tracked material.
  Because this destination is local and untracked, it is also the JIT home for private conditional knowledge that no committed surface may hold.
- An already-existing user-owned local on-demand note with an established trigger, after confirming it is untracked, private, and able to hold the quoted entry.
  The pass may add the entry to that existing owner but never creates a new note, skill, or trigger for this purpose.
- A project's existing committed `AGENTS.md`, for project-intrinsic knowledge useful to nearly every session of that project, through a normal crewmate ship task using `bin/fm-ensure-agents-md.sh` and the project's registered delivery mode.
- A project-level skill in the project's own repository, for situation-conditional knowledge within one project, through the same ship-task path.

Forbidden destinations: any firstmate-repo-tracked skill per the hard rule; firstmate's own `AGENTS.md`, which is always-loaded for every fleet session; `docs/` alone, which is never agent-loaded on demand, though a skill body may point into docs for depth; and any committed surface for private content.
A local skill exists only in this home, so offloading an entry out of `data/captain-shared.md` removes it from every inheriting home's always-injected memory: the proposal must say so, and the default for shared entries is keep.

### Flow: reduce, approve, migrate, remove

1. Reduce non-pinned material now.
   For each eligible non-pinned candidate, record its first line, source file, estimated tokens, one-line trigger, live destination, privacy and visibility verdict, and actual budget relief in the completion receipt.
   Autonomously relocate it only by adding it to an already-existing allowed JIT note, or by routing it through a project's established delivery path to its existing owning `AGENTS.md`, then confirming that destination holds the quoted entry before removing the memory entry.
   A destination that needs creation, uncompleted project delivery, or any other future work is not live and cannot count as relief, so continue with the next archival or eviction rung instead of leaving an over-budget proposal pending.
2. Propose pinned relocation only.
   For a pinned candidate, append a `proposed-offload` section with the same fields to the completion receipt and create or refresh one durable captain-held backlog item using `tasks-axi add`, `tasks-axi hold`, `tasks-axi show <id> --full`, and `tasks-axi update <id> --body-file <path>` as appropriate.
   Preserve each candidate's approval state in that item, and require explicit plain-chat approval for that named item before any migration.
   If the captain never answers, nothing migrates and the held item persists, but it is never treated as budget relief.
3. Migrate an approved pinned candidate outside this pass.
   Resolve `home_root` to `$FM_HOME` when it is set and otherwise to the Firstmate code root, then re-validate the approved local-skill destination under that root for both index absence with `git -C "$home_root"` and filesystem collision absence.
   Before creating the destination or writing any private content, resolve the exclude file with `git -C "$home_root" rev-parse --git-path info/exclude`, append the destination directory path to it, and verify the future `SKILL.md` path is ignored with `git -C "$home_root" check-ignore`.
   Only after that verification succeeds, create the destination and write the `SKILL.md` with its precise description trigger, then confirm the skill appears in a fresh session's skill index.
   If any migration step fails, remove the destination content and the exclude rule written by this attempt, leaving neither partial private content nor a partial rule behind.
   An approved project destination ships as a normal task through that project's registered delivery mode.
   The migration's source of truth is the entry as quoted in the proposal.
4. Remove only once live.
   The memory entry leaves its always-injected file only after the destination is live: the local skill exists with its verified line in the active home's resolved repository-local exclude file, or the project change has landed.
   Until then the entry stays, so knowledge is never in limbo between owners.
   Leave no pointer behind by default, and at most one line only when the destination's discoverability is genuinely doubtful.

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
   For every retained fact, ask which current statement it supersedes, whether it can be a one-sentence rewrite, and whether a stale entry should be refreshed, archived, or routed to an existing stronger owner.
   The only graduation moves are promotion to tracked shared material through a PR, folding a learning into the captain-preference destination selected by AGENTS.md, archiving a stale entry to `data/memory-archive.md`, autonomous offload of an eligible non-pinned conditional entry to an already-existing allowed owner through the reduce flow above, captain-approved offload of a pinned durable conditional entry to a JIT-loaded owner executed through the migration step above, or deletion of an entry that is a duplicate or already preserved through a stronger existing owner.
   A stale unique fact is never deleted, only archived.
   Do not invent another graduation path.

## Open-record persistence

The sweep above preserves knowledge; this one preserves the state of work.
A reset destroys whatever exists only in this session, and that includes what you have learned about work already under way, not just facts worth remembering.
So before the reset, make sure the important open work you are holding in context is durably recorded: file what was never filed, and correct what you now know is stale.

Judge for yourself what is important and which record each thing belongs to, and write it through the owner that already governs that record.
One bound holds: this covers the open work you are actually holding in context, not the records at large.
It is not a reconciliation of durable records against repository or forge reality, cannot become one on input this volatile, and must never be reported as one.
Where the right correction is a judgment you cannot make, leave the record alone and raise the question instead of guessing.

## One-time migration of unmarked entries

Legacy entries carry no markers; an unmarked entry is its file's default tier with unknown age, and unknown age is not guilt.
The first pass after adoption performs a one-time revalidation sweep of editable memory files instead of blanket restamping, while a read-only shared file remains untouched and any required change is routed to its primary owner:

- In `data/captain.md` and `data/captain-shared.md`, every unmarked entry is simply default-pinned and remains exempt from the aging clock, legacy grace cycle, and archive-by-age; consolidation still applies, and only genuine tier deviations receive markers.
- In `data/learnings.md`, stamp each entry the pass can confirm current with its compact dated marker for today, using a deviating tier letter or `<!--P-->` only where the entry genuinely deviates from the `aging` default.
- On the first pass that cannot cite independent current-session evidence for an unmarked entry in `data/learnings.md`, add `<!--g-->` as its trailing marker and retain it through the rest of that pass; carrying no date, it persists that the entry has consumed exactly one grace cycle without pretending it was reinforced.
- Only an entry that already carried `<!--g-->` when this invocation began is on the next-pass branch: replace that marker with the normal dated tier marker if independent current-session evidence confirms the entry; otherwise archive it with provenance `legacy-unvalidated`.
- The grace period is one full stow cycle, not a time window, and the same persisted transition applies when a hand edit later leaves an entry unmarked in `data/learnings.md`.

## Completion receipt

Report the outcome in plain captain-facing language with all of these facts:

- effective startup-memory budget and total estimated tokens before and after;
- one or more actions for each of `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, using only `unchanged`, `added`, `rewritten`, `pruned`, `routed`, `archived`, or `proposed-offload`; adding or replacing a migration marker is `rewritten`, never a new action verb such as `migrated`;
- each durable finding filed outside memory and its authoritative owner;
- each archived entry's reason, each autonomous offload's live destination and actual relief, and, when a pinned candidate was proposed, the `proposed-offload` section with every candidate's fields;
- every unresolved exception, including a primary-owned shared-file constraint in a secondmate home, and every concrete captain decision opened for an over-budget result;
- each open record this pass filed or corrected, and each one it deliberately left alone with the judgment it is waiting on;
- whether the session is safe to reset, only when all durable findings are captured, every open record this session held is filed or explicitly left with its reason, and the post-pass result is within budget with no exception or pending budget decision.

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

## Scope exclusion: no skill storage by the pass

The stow pass itself must never store, create, or edit a skill as a destination for any finding.
The exclusion binds the pass as a writer: proposing an offload and letting the migration step execute a captain-approved candidate later is not the pass storing a skill.
Every Firstmate-home skill that migration produces is user-owned and local under the destinations hard rule, while an approved project-level destination is produced and shipped through that project's registered delivery path, never by stow.
Changing firstmate's tracked `.agents/skills/` or public `skills/` remains a deliberately scoped Firstmate repository task through its pipeline, never a stow product.
Outside a captain-approved offload, generalizable knowledge still routes to shared tracked material through its pipeline and fleet-local knowledge to `data/`.
