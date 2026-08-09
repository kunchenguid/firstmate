---
name: stow
description: Sweep the current session for uncaptured durable knowledge, file it to disk, and curate the home's tiered, decaying startup memory before a context reset. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge that exists only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
Memory entries are tiered and decay between passes, and stale material retires to a cold archive instead of being deleted.
This skill writes only through the existing Firstmate ownership and write boundaries.

## Memory tiers and entry markers

Every entry in the three memory files may carry one trailing HTML-comment marker holding a tier and a last-reinforced date:

```markdown
- Never merge a red PR; destructive, irreversible, and security-sensitive choices stay with the captain. <!-- tier: pinned -->
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!-- reinforced: 2026-08-03 -->
- While state/.afk exists, the away-daemon owns triage (until the afk-wake fix lands; tracked: afk-pi-wake-bypass-r1). <!-- tier: perishable | reinforced: 2026-07-20 -->
```

The tier names say what the pass does with an entry:

- `pinned` - no clock is ever read for it: exempt from decay and from budget eviction, changed only through inspect-then-update when the captain or reality changes it, except that an explicit per-item captain approval may offload it under the flow below.
- `aging` - it must re-prove itself: an entry whose age is greater than or equal to 30 days since its `reinforced:` date is stale, and a stale entry is re-validated (date refreshed) or archived, never kept by inertia alone.
- `perishable` - it is stored expecting disposal: an entry whose age is greater than or equal to 7 days since its `reinforced:` date is stale, and its prose must name a checkable expiry condition, such as a backlog id, a version floor, or a dated expectation.
  An admitted durable entry that cannot name a checkable expiry condition is not `perishable` and must be stored as `aging`.
  Omission is reserved for non-durable material or facts already owned elsewhere.

Marking rules:

- Tier defaults are file-scoped: entries in `data/captain.md` and `data/captain-shared.md` default to `pinned` because preferences and authority boundaries do not age, and entries in `data/learnings.md` default to `aging` because operational facts must re-prove themselves.
- An entry carries `tier:` only when it deviates from its file's default.
- `pinned` entries carry no date because no clock applies; `aging` and `perishable` entries always carry `reinforced: YYYY-MM-DD`.
- During legacy migration only, `legacy-grace: pending` may appear in the trailing marker without a `reinforced:` date; it records that the entry has consumed its grace cycle and is not reinforcement.
- Each memory file's header carries a one-line legend stating that file's default tier, the marker spelling (including the migration-only grace state while one exists), and the current clocks, so the scheme is self-describing to any reader.
- The clocks are policy owned by this skill text and echoed by the legends, deliberately not configuration.
- A missing or hand-dropped marker is never an error: it means the file's default tier; an unmarked entry in a default-pinned file is simply pinned, while an unmarked entry in a file whose default tier carries a clock follows the migration rule below.

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
3. Build one whole-file retention plan before editing.
   Retain, in order: current captain preferences, authority and safety boundaries, and recurring working style; stable home-local operating facts that repeatedly affect future work and are expensive to rediscover; then concise pointers to an existing authoritative report, project document, configuration, or backlog item.
   Retain lower-priority material only while budget remains.
4. Reinforce and stamp.
   Refresh `reinforced:` to today only on entries this session actually exercised, confirmed, or re-derived.
   The bar is session evidence: an entry's presence in the file is not evidence, and re-reading your own memory is never reinforcement.
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
7. When the total is still over budget after decay and consolidation, relieve it using editable files only and in this order: archive every editable entry already stale, which needs no further judgment; consolidate tighter; run the over-budget offload sweep below and file its proposals, whose relief lands at migration cadence rather than inside this pass; then archive editable `aging` entries oldest-`reinforced`-first until within budget.
   Automatic processes never move a `pinned` entry: decay clocks, legacy grace cycles, oldest-first budget eviction, and immediate budget archiving do not apply to it.
   The sole exception is relocation to a JIT owner after explicit, per-item captain approval under the offload flow below, and that entry remains in memory until its destination is live.
8. Run `bin/fm-startup-memory-budget.sh report` again after the complete pass.
   Finish at or below the effective budget unless a concrete inability remains.
   A secondmate must explicitly report `primary-owned-shared-file-alone-exceeds-budget` when the inherited shared file alone exceeds its allowance, because local curation cannot resolve it.
   Any other unresolved excess must identify the fact that cannot safely be archived or routed and why.

A net increase is allowed only for a genuinely new current fact with no stronger owner.
Before allowing it, consolidate enough lower-priority material to remain within budget.
Never describe the session as reset-safe while the memory total is over budget or an exception is unresolved.

## The cold tier: data/memory-archive.md

Stale never means deleted: pruning an entry from an editable memory file always means moving it to `data/memory-archive.md`, this home's append-only, never-injected cold tier, gitignored with the rest of `data/` and never counted by the budget report.
Each archived entry keeps its provenance under a dated pass heading: source file, tier, last-reinforced date, and the reason it left.

```markdown
## 2026-08-08 stow
- (from learnings.md, tier: perishable, reinforced: 2026-06-30) While state/.afk exists, the away-daemon owns triage... [archived: unreinforced 39d]
```

Reasons include `unreinforced <N>d`, `budget oldest-first`, `legacy-unvalidated`, and `offloading to <destination> via <task id>`.
Archiving is a move, not a removal, and recovery is `grep` plus copy back with no tooling.
Each home keeps its own archive, the archive never cascades, and truncating a grown archive is a captain decision, not a mechanism.

## Over-budget offload to JIT-loaded owners

Decay handles staleness over time; offload handles scope: knowledge that is current and durable but relevant only in a nameable context, and therefore wrong to pay for in every session of every fleet member.
For the offload sweep's evaluation only, each entry has exactly three outcomes decided in this fixed order:

1. Archive, the time outcome, always evaluated first: staleness is judged before scope, and offload never moves a stale fact anywhere.
2. Offload, the scope outcome, asked only of current durable entries: is this needed in nearly every session, or only in a nameable context?
3. Keep, the default outcome for this sweep: current, durable, and either fleet-wide-relevant or safety-relevant even in sessions that never name the topic.

The offload sweep runs only when the pass is still over budget after decay archiving and consolidation, so routine passes never see proposals.
Every test must hold for a candidate:

- Editable source: this home owns the memory file and may relocate the entry; a read-only shared entry is routed to its primary owner instead.
- Durable: not `perishable`, not stale, and expected to remain true for months.
- Eligible by authority: an `aging` entry may be proposed normally, while a `pinned` entry may be proposed only for explicit, per-item captain-approved relocation and can never be archived for budget relief.
- Conditional: a one-line nameable trigger exists, and a session that never touches that trigger runs no risk from omitting the fact.
- Fat enough to matter: roughly 50 estimated tokens or more, proposed largest-first, because consolidation handles smaller entries.
- A destination below fits the entry's privacy and visibility.
- Not already preserved by a stronger owner, which the consolidation counterweight already handles as ordinary curation rather than offload.

### Destinations

**Hard rule: the stow process never creates or writes a firstmate-repo-tracked skill.**
**Every skill stow's offload produces for a Firstmate home is user-owned and local, excluded through `.git/info/exclude`; contributing a lesson to the shared tracked template is a separate deliberate captain action, never automatic.**
Approved project-level destinations are not produced by stow: they ship normally through that project's own registered delivery path.

- A user-owned local skill: a directory under `.agents/skills/<freeform-name>/` whose path is appended to this home clone's local `.git/info/exclude`, never to a `.gitignore`.
  Before approval and again before migration, validate that the chosen freeform destination is absent from the git index and collides with no existing file or directory, and reject the destination if either check fails.
  The name is freeform with no user-vs-firstmate naming convention, the skill stays per-home and untracked, and the harness still lists and JIT-loads it because skill discovery scans the filesystem and ignores git status (verified in `docs/verification/stow-memory.md`).
  Its precise, condition-stated description line is its entire trigger; it gets no `AGENTS.md` declaration because `AGENTS.md` is shared tracked material.
  Because this destination is local and untracked, it is also the JIT home for private conditional knowledge that no committed surface may hold.
- A project's committed `AGENTS.md`, for project-intrinsic knowledge useful to nearly every session of that project, through a normal crewmate ship task using `bin/fm-ensure-agents-md.sh` and the project's registered delivery mode.
- A project-level skill in the project's own repository, for situation-conditional knowledge within one project, through the same ship-task path.

Forbidden destinations: any firstmate-repo-tracked skill per the hard rule; firstmate's own `AGENTS.md`, which is always-loaded for every fleet session; `docs/` alone, which is never agent-loaded on demand, though a skill body may point into docs for depth; and any committed surface for private content.
A local skill exists only in this home, so offloading an entry out of `data/captain-shared.md` removes it from every inheriting home's always-injected memory: the proposal must say so, and the default for shared entries is keep.

### Flow: propose, approve, migrate, remove

1. Propose.
   The sweep appends a `proposed-offload` section to the completion receipt: each candidate's first line, source file, estimated tokens, the one-line trigger, the proposed destination as a freeform skill name plus draft description line or a project plus file, the privacy and visibility verdict, and the expected budget relief.
   The same list is the body of a single durable captain-held backlog item, created on first use with `tasks-axi add <id> <title> --kind captain --repo firstmate --body "<proposal body>"` before `tasks-axi hold <id> --reason "<reason>" --kind captain` transitions it to a hold.
   On later passes, inspect it with `tasks-axi show <id> --full`, refresh unresolved proposals in place with `tasks-axi update <id> --body-file <path>`, preserve every candidate's recorded approval state, and keep the existing hold rather than appending or creating a duplicate.
   The held item's body is the durable approval record, so an approved candidate remains approved and is never forgotten or proposed again.
   If the captain never answers, nothing migrates and the held item simply persists; there is no auto-migration, ever.
2. Approve.
   The captain approves per candidate in plain chat, and firstmate records the approval in the held item's body.
3. Migrate, outside this pass.
   An approved local skill is created through firstmate's normal direct maintenance of private local material only after re-validating that its destination is absent from the git index and collides with no existing content: write the `SKILL.md` with its precise description trigger, append the directory path to `.git/info/exclude`, and confirm the skill appears in a fresh session's skill index.
   An approved project destination ships as a normal task through that project's registered delivery mode.
   The migration's source of truth is the entry as quoted in the proposal, or its archive line when budget pressure already retired it.
4. Remove only once live.
   The memory entry leaves its always-injected file only after the destination is live: the local skill exists with its exclude line in place, or the project change has landed.
   Until then the entry stays, so knowledge is never in limbo between owners.
   For a non-pinned entry, when the home is still over budget after approval, this remove-only-once-live rule relaxes solely into immediate archival with provenance `offloading to <destination> via <task id>` in the recoverable cold tier, never into plain removal, so the archive remains the source if migration fails.
   A pinned entry never takes that budget-archive exception and leaves memory only after its approved destination is live.
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
   The only graduation moves are promotion to tracked shared material through a PR, folding a learning into the captain-preference destination selected by AGENTS.md, archiving a stale entry to `data/memory-archive.md`, captain-approved offload of a durable conditional entry to a JIT-loaded owner executed through the migration step above, or deletion of an entry that is a duplicate or already preserved through a stronger existing owner.
   A stale unique fact is never deleted, only archived.
   Do not invent another graduation path.

## One-time migration of unmarked entries

Legacy entries carry no markers; an unmarked entry is its file's default tier with unknown age, and unknown age is not guilt.
The first pass after adoption performs a one-time revalidation sweep of editable memory files instead of blanket restamping, while a read-only shared file remains untouched and any required change is routed to its primary owner:

- In `data/captain.md` and `data/captain-shared.md`, every unmarked entry is simply default-pinned and remains exempt from the aging clock, legacy grace cycle, and archive-by-age; consolidation still applies, and only genuine tier deviations receive markers.
- In `data/learnings.md`, stamp each entry the pass can confirm current with `reinforced:` today, plus a `tier:` where it deviates from the `aging` default.
- On the first pass that cannot confirm an unmarked entry in `data/learnings.md`, add `<!-- legacy-grace: pending -->` as its trailing marker without a `reinforced:` date; this persists that it has consumed exactly one grace cycle without pretending it was reinforced.
- On the next pass, replace that marker with the normal tier marker if current evidence confirms the entry; otherwise archive it with provenance `legacy-unvalidated`.
- The grace period is one full stow cycle, not a time window, and the same persisted transition applies when a hand edit later leaves an entry unmarked in `data/learnings.md`.

## Completion receipt

Report the outcome in plain captain-facing language with all of these facts:

- effective startup-memory budget and total estimated tokens before and after;
- one or more actions for each of `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`: `unchanged`, `added`, `rewritten`, `pruned`, `routed`, `archived`, or `proposed-offload`;
- each durable finding filed outside memory and its authoritative owner;
- each archived entry's reason, and, when the offload sweep ran, the `proposed-offload` section with every candidate's fields, stated plainly as relief that lands at migration cadence rather than in this pass;
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
