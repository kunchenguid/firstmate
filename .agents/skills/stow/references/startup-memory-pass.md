# stow: startup-memory pass

Reference of the `stow` skill, loaded on demand from its `SKILL.md` table; the always-resident rules stay in that `SKILL.md`.

## Required startup-memory pass

Every `/stow` invocation performs this complete pass, even when the session contains no new finding:

1. Identify the active Claude account's auto-memory index for this session's project: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<slug>/memory/MEMORY.md`, where `<slug>` is Claude's project key for the session's project root.
   Use the active harness's project path, not an arbitrary checkout, a guessed account, or an index from another home.
   Run `bin/fm-startup-memory-budget.sh report --claude-index "$index"` before considering a write when that index is in scope, including when its exact path is known but the file is absent.
   If the active harness has no Claude auto-memory, run `report` without the flag and note that the fourth input does not apply.
   If an applicable index cannot be located or read, name the accounting exception and do not claim reset-safe.
   Record the effective budget and each input's estimated-token total.
   All inputs count against the same per-home allowance, never a fleet total.
   The helper's stable estimate is the documented conservative local approximation, not provider-exact accounting.
   If it rejects the setting or a memory file, do not infer a default or silently continue.
   Report that concrete exception and do not call the session reset-safe.
2. Read every current memory file completely: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`.
   Read the applicable Claude `MEMORY.md` completely as the fourth input, but do not recursively load the topics it links to or edit anything in the harness store.
   Treat an absent input as absent, not as an invitation to manufacture content.
   Check the index for duplicates, stale pointers, and current unique facts; route current facts through the normal ownership rules, and report any needed index cleanup to the harness-store owner without claiming that routing reduced the index's measured size.
   Note any `Memory layering` declaration in the Firstmate files (schema: `docs/configuration.md`) and which declared tiers this session can reach; every later step consults it.
   When neither `data/captain.md` nor `data/captain-shared.md` holds one, treat the local files as the only owners.
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
   Where the optional pass horizon is enabled, refreshing that date also clears the entry's unreinforced-pass counter, and nothing else clears it.
   **Hard rule: reinforcement requires independent evidence from this session that you can name in the receipt; plausibility, importance, prior knowledge, and the entry's own text are not evidence, and any explicit statement that no confirming session evidence exists requires the no-evidence path.**
   For an unmarked `data/learnings.md` entry with no such evidence, the no-evidence path is always to append `<!--g-->` and retain it for this entire pass; never stamp or archive it during that same invocation.
   Stamp each newly written entry with today's date and its tier per the marking rules, and admit a new `perishable` entry only with its named checkable expiry condition in the prose.
5. Evaluate every dated entry in each editable memory file against its tier clock.
   Where the optional pass horizon is enabled, first increment the unreinforced-pass counter of every dated entry step 4 did not reinforce - that increment is the pass tick - then judge each dated entry against both of its horizons and treat it as stale at whichever it reaches first.
   Re-validate a stale `aging` entry from current evidence and refresh its date, or archive it.
   Re-confirm a stale `perishable` entry against its named condition: still open means refresh the date, while resolved, expired, or no longer checkable means archive it in this pass.
   Promote `perishable` to `aging` when its condition keeps proving durable past its expected life, and retier in place when a supersession changes an entry's lifetime.
   `pinned` is exempt from this automatic decay step entirely.
6. Consolidate every editable memory file as needed, not only the file apparently related to a new finding.
   Prefer one concise current rule or authoritative pointer over duplicate prose.
   Archive completed incident and release chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, and report-sized procedures; merge or remove only superseded claims and duplicates whose facts are preserved elsewhere.
   Never plainly remove a unique current fact: every such exit must archive it with provenance in the recoverable cold tier or relocate it to a live JIT owner or a consolidation merge that preserves the fact.
   **Declared-tier guard: before any archive, eviction, offload, or consolidation removes an entry whose knowledge class a declared tier owns, confirm that tier holds the fact or capture it there first under the tier's declared rule; when the tier is unreachable from this session, leave the entry in place with its pending-capture marker instead of removing it, and name the uncaptured entry in the receipt.**
   This guard binds every removal rung in this pass, including budget eviction and decay archival.
7. When the total is still over budget after decay and consolidation, make aggressive reduction the default, using editable files only and in this order: archive every editable stale, superseded, or low-utility entry that is eligible for archival; consolidate tighter; run the over-budget offload sweep below and autonomously relocate every eligible non-pinned conditional entry into an already-existing allowed owner only after that owner holds it; then, only when the convergence precondition below holds, archive eligible `aging` entries oldest-reinforced-first until within budget.
   A proposal, a future migration, or an accepted exception is never budget relief in this pass.
   Budget eviction considers only editable `aging` entries that carry a last-reinforced date and are not pending offload or pending capture; a `<!--g-->` legacy-grace entry is ineligible until its grace cycle resolves, so eviction can neither cancel a promised grace cycle nor prefer just-validated entries over unvalidated ones.
   Convergence precondition: before evicting anything, total the eligible pool and check that archiving all of it would reach the budget; when even that cannot, skip the eviction rung entirely, archive nothing for budget reasons, and carry the concrete inability to the final step, naming the exempt pinned and pending-capture floor that crowds out the budget.
   Automatic processes never move a `pinned` entry: decay clocks, legacy grace cycles, oldest-first budget eviction, immediate budget archiving, and autonomous offload do not apply to it.
   The sole exception is relocation to a JIT owner after explicit, per-item captain approval under the offload flow below, and that entry remains in memory until its destination is live.
8. Run the same budget report from step 1 again after the complete pass, including the same applicable index.
   Finish at or below the effective budget, or open a concrete captain decision before ending the pass.
   A secondmate must explicitly report `primary-owned-shared-file-alone-exceeds-budget` when the inherited shared file alone exceeds its allowance, because local curation cannot resolve it.
   Route that constraint to the primary owner and open one concrete captain decision at the primary owning level that names the shortfall, with exactly these options: raise the affected home's effective budget, or explicitly approve the primary owner trimming or offloading each named shared-file entry.
   When the convergence precondition skipped eviction, report the exempt pinned and pending-capture floor and the remaining shortfall as that concrete inability rather than archiving eligible knowledge that could not close the gap.
   Only after every safe non-pinned archival, consolidation, offload, and eligible eviction action is exhausted may a remaining excess be attributed to pinned safety, authority, or genuine captain-preference entries.
   In that last-resort case, create one captain-held decision that names the shortfall and each relevant pinned entry, with exactly these options: raise the effective budget, or explicitly approve offloading or trimming a named pinned entry.
   Route a read-only ownership constraint to its primary owner, and make every other unresolved excess a concrete captain decision that names the safe action still required.
   Never end a pass over budget as an accepted exception.

## The cold tier: data/memory-archive.md

The rule that stale never means deleted stays in `SKILL.md`; the provenance below applies to every archived entry.

Each archived entry keeps its provenance under a dated pass heading: source file, tier, last-reinforced date, and the reason it left.
Include the unreinforced-pass counter only when the optional pass horizon itself made the entry stale, using the exact reason `unreinforced <N>p`; omit the counter when the wall-clock horizon or any other reason caused archival, even if the active marker carried one.
Archive provenance stays verbose rather than compact because the cold tier is never budget-counted.

```markdown
## 2026-08-08 stow
- (from learnings.md, tier: perishable, reinforced: 2026-06-30) While state/.afk exists, the away-daemon owns triage... [archived: unreinforced 39d]
```

Reasons include `unreinforced <N>d`, `unreinforced <N>p`, `budget oldest-first`, and `legacy-unvalidated`.
Archiving is a move, not a removal, and recovery is `grep` plus copy back with no tooling.
Each home keeps its own archive, the archive never cascades, and truncating a grown archive is a captain decision, not a mechanism.

## One-time migration of unmarked entries

Legacy entries carry no markers; an unmarked entry is its file's default tier with unknown age, and unknown age is not guilt.
The first pass after adoption performs a one-time revalidation sweep of editable memory files instead of blanket restamping, while a read-only shared file remains untouched and any required change is routed to its primary owner:

- In `data/captain.md` and `data/captain-shared.md`, every unmarked entry is simply default-pinned and remains exempt from the aging clock, legacy grace cycle, and archive-by-age; consolidation still applies, and only genuine tier deviations receive markers.
- In `data/learnings.md`, stamp each entry the pass can confirm current with its compact dated marker for today, using a deviating tier letter or `<!--P-->` only where the entry genuinely deviates from the `aging` default.
- On the first pass that cannot cite independent current-session evidence for an unmarked entry in `data/learnings.md`, add `<!--g-->` as its trailing marker and retain it through the rest of that pass; carrying no date, it persists that the entry has consumed exactly one grace cycle without pretending it was reinforced.
- Only an entry that already carried `<!--g-->` when this invocation began is on the next-pass branch: replace that marker with the normal dated tier marker if independent current-session evidence confirms the entry; otherwise archive it with provenance `legacy-unvalidated`.
- The grace period is one full stow cycle, not a time window, and the same persisted transition applies when a hand edit later leaves an entry unmarked in `data/learnings.md`.
