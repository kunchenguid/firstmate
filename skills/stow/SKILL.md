---
name: stow
description: Sweep the current conversation for durable knowledge - user preferences, project facts, operational gotchas, standing decisions, and unfinished next steps - and file each through explicit instructions, existing local conventions, or the private `.stow-notes.md` fallback, curating tiered, decaying destination files as it writes. Use when the user invokes /stow, asks to save or write down what was learned this session, or before a context reset or long break.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone, with no private project paths, tool assumptions, or environment branching. The firstmate-internal counterpart lives at .agents/skills/stow/SKILL.md - deliberately a separate file with no shared code. Keep them independent. -->

# stow

Sweep this conversation for durable knowledge that only exists in chat right now, and file it through the user's explicit instructions, the project's existing local conventions, or the private `.stow-notes.md` fallback in the current directory.
The goal is to leave the next session a compact, current operating map, not an accumulating journal: every durable finding lands on disk, and every file this skill touches comes out more accurate, not merely longer.
Entries are tiered and decay between passes, and stale material retires to a local archive instead of being deleted.
Everything files to a local destination by default; an external system such as an issue tracker is reached only through the explicit-instruction rule in step 3.

## What it does

1. **Sweep the conversation for uncaptured durable knowledge.**
   Read back over the session and look for:
   - User preferences: a working-style, tooling, formatting, or approval preference the user stated in passing rather than through a config file.
   - Project facts: build, test, deploy, architecture, or convention facts about the current project that would help anyone (or any agent) working in it later.
   - Operational gotchas: a sharp edge, workaround, recurring mistake, or non-obvious cause discovered while working here.
   - Standing decisions: a choice made this session that should outlive it, such as an approach settled on, an option ruled out, or a convention agreed to.
   - Undone next steps: anything left open or agreed to that has not yet been written down anywhere.
   Before filing any finding, check whether it already lives authoritatively somewhere - a README, a config file, existing docs, the code itself.
   If it does, record a one-line pointer to that owner instead of a copy, so the stowed note cannot go stale independently of its source.

2. **Discover the host's existing conventions before deciding where anything goes.**
   Don't assume a destination - look for what's actually there, roughly in this order:
   - A project-level memory file, such as `CLAUDE.md`, `AGENTS.md`, or an equivalent at the repo root or nearby.
   - A user-level (global) memory file the running agent reads across projects, if one exists and is readable.
   - A `TODO`, `BACKLOG`, `NOTES`, or similarly named plain file already tracked in the project.
   This step is about local files only; do not scan for or infer an issue tracker here - step 3 owns external routing.

3. **Route each finding using this fixed priority order, local-first.**
   1. **Highest - an explicit instruction wins.** If the user has explicitly said, earlier in this conversation or as a standing choice previously recorded in the discovered user-level memory file (see step 4), to use a particular system for this kind of finding, route it there.
      This is the *only* path to an external or public system such as an issue tracker, hosted project board, or ticketing system.
      A configured git host remote, a `.github`/`.gitlab` folder, or any other signal that a tracker probably exists is never by itself grounds to file anything there - never route externally on inference.
   2. **Otherwise - the local convention the project or user already has.** The discovered project memory file for project facts, operational gotchas, and standing decisions; an existing `TODO`/`BACKLOG`/`NOTES` file for undone next steps; a discovered user-level memory file for user preferences *when one happens to be accessible* - a bonus if reachable, never an assumption or a requirement.
      This is the only tier that writes findings into a tracked, shared file or outside the current directory, and only because the user already established that destination.
   3. **Fallback - `.stow-notes.md` in the current directory, for every finding-kind.** When no existing convention fits, don't improvise a location or invent an ad hoc filename.
      In a git worktree, first verify `.stow-notes.md` is not already tracked in the index; if it is tracked, do not write private findings there - report that the fallback is blocked until the user chooses a safe destination.
      Otherwise create or update `.stow-notes.md` in the current working directory - never a user-level or home-directory path, so the fallback works even for agents sandboxed to the current directory.
      Then keep it out of git: add a `.stow-notes.md` line to a `.gitignore` file in the current directory - an ordinary file at that path, not git's internal exclude mechanism, which can resolve outside the working directory in a linked worktree.
      Leave staging or committing that `.gitignore` line to the user, same as everything else this skill writes.
      If even the `.gitignore` write fails, don't block or error - still write `.stow-notes.md` and tell the user to ignore it manually.

4. **When it's genuinely ambiguous between two existing conventions, ask once - then remember the answer.**
   If more than one discovered local convention plausibly fits a finding, ask the user once, plainly, which one they want that kind of note to live in going forward.
   The same applies when the user gives an explicit instruction to use a tracker or other non-local system going forward rather than just for one item.
   Once they answer, offer to remember it: with their explicit permission, record a short standing note of that choice in the discovered (or newly agreed) user-level memory file, so the same question doesn't need repeating in this project.
   Always ask before adding that note - never establish a convention silently.
   When nothing existing fits at all (not merely ambiguous), that's the step-3 fallback, not a question.

5. **Write only into locations that already exist as a real convention, the step-3 fallback (plus its `.gitignore` line), or a destination the user just approved in step 4.**
   Do not invent new shared files, new folders, or new tracker categories the project doesn't already have.
   Never store, create, or edit a skill as a destination for a finding: there is no "graduate this to a skill" move, even in a repo whose existing `.claude/skills/` or `skills/` directory makes one look like a convention.
   The offload exit in step 7 does not weaken this: this skill only ever proposes such a move, and the on-demand home is created through the user's own change process, never by this skill's writes.
   If the fallback is unwritable and the user doesn't want a new convention, say so plainly and leave that finding unfiled rather than fabricate a destination.

6. **Read the destination before writing: inspect-then-update, never blind-append.**
   Before writing any finding, read the destination file's current contents in full.
   Then ask, for each finding: which existing entry does it supersede; can it be a one-sentence rewrite of an existing entry instead of a new one; and should a stale entry now be refreshed, archived, or replaced in a way that preserves its fact in the same pass?
   Stamp each entry written into a memory file or `.stow-notes.md` with a tier and date per the tier contract below, but never add tier markers to an existing `TODO`/`BACKLOG`/`NOTES` file.
   For an existing `TODO`/`BACKLOG`/`NOTES` item, inspect the full item, classify the change as new, duplicate, superseding, or obsolete, then write a considered replacement body rather than appending to it.
   File each undone next step with what it is waiting on, when it is genuinely blocked on something.

7. **Curate every memory file this pass has open, not only the one a finding routes to.**
   Evaluate each dated entry against its tier clock per the tier contract below, refreshing what current evidence re-validates and archiving what stays stale.
   Archive what is no longer current, including completed chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, and report-sized procedures; merge or remove only superseded claims and duplicates whose facts are preserved elsewhere.
   Prefer one concise current rule, or a pointer to the authoritative source, over duplicate prose.
   Never plainly remove a unique current fact: every such exit must archive it with provenance in the recoverable cold tier or relocate it to a live on-demand owner or a consolidation merge that preserves the fact.
   This is an accuracy discipline, not a length target - a stale entry misleads the next session; a current one earns its place.
   A `.stow-notes.md` note has exactly five exits: promotion into a shared, tracked file the user approves; folding into a discovered user-level memory file; archiving to the local, never-loaded archive file; a user-approved move into an on-demand-loaded home (a skill or scoped instruction file), executed through the user's own change process rather than by this skill; or deletion of a duplicate already preserved by a stronger owner - do not invent another.

8. **Finish with an honest safe-to-end verdict and a resume pointer for the next session.**
   Report one action per file this sweep touched or considered: `unchanged`, `added`, `rewritten`, `pruned`, `archived` (an entry moved to the local archive), or `routed` (the finding went to a different owner).
   Name any proposed moves into an on-demand home still awaiting the user's approval, so they are not mistaken for finished work.
   Then tell the user, in plain language, what was captured and where, what could not be captured (and why), and whether the conversation is now safe to end or reset - that is, whether every durable finding from this sweep now lives on disk or in an explicitly requested tracker rather than only in this chat.
   If something could not be captured yet, say so explicitly instead of reporting the session fully safe.
   If anything landed in `.stow-notes.md`, say so - note that it is private and confined to this project, and name its promotion exit from step 7 if the user wants it more widely visible.
   In a git repo, report the ignore protection as it actually happened: either the `.gitignore` line was added and awaits the user's own commit, or the write failed and the user must ignore `.stow-notes.md` manually before relying on git to hide it.
   If the fallback was blocked because `.stow-notes.md` was already tracked, say that no private fallback was written and the session is not fully safe to reset until the user chooses another destination or accepts that tracked file.
   If a user preference landed in `.stow-notes.md` because no user-level memory file was discovered, add one caveat: it now applies to this project only, and the user must copy it into their own global memory file themselves if they want it to follow them across projects.
   The real payoff of stowing is not this session but the next one: close with a short, copy-pasteable RESUME POINTER naming exactly which files a fresh session should load to pick this back up cold, e.g. `To pick this back up in a new session, load: CLAUDE.md (project conventions), .stow-notes.md (private notes, not shared)`.
   List only the files this sweep actually wrote or updated; skip the pointer if nothing was written.

## Tiered, decaying entries

Every entry this skill writes into a memory file may carry one trailing HTML-comment marker holding a tier and a last-reinforced date:

```markdown
- Prefer concise progress updates during implementation work. <!-- tier: pinned -->
- The staging deploy needs the VPN profile active or the smoke test hangs. <!-- reinforced: 2026-08-03 -->
- CI is red on the flaky auth test until the pinned runner image updates (tracked in TODO). <!-- tier: perishable | reinforced: 2026-07-20 -->
```

The tier names say what this skill does with an entry:

- `pinned` - never decays and is never dropped to shorten a file; it changes only when the user or reality changes it.
- `aging` - must re-prove itself: an entry whose age is greater than or equal to 30 days since its `reinforced:` date is stale, and a stale entry is re-validated (date refreshed) or archived, never kept by inertia alone.
- `perishable` - written to be thrown out: an entry whose age is greater than or equal to 7 days since its `reinforced:` date is stale, and its text must name a checkable expiry condition, such as a ticket, a version, or a dated expectation.
  An entry that cannot name a checkable condition is `aging`, not `perishable`.

Rules:

- Unless a file's own legend says otherwise, a user-level memory file defaults to `pinned`, while a project memory file and `.stow-notes.md` default to `aging`.
- An entry carries `tier:` only when it deviates from its file's default, and `pinned` entries need no date.
- During legacy migration only, `legacy-grace: pending` may appear in the trailing marker without a `reinforced:` date; it records that the entry has consumed its grace cycle and is not reinforcement.
- When first writing a marked entry into a file, add a one-line header legend stating that file's default tier, the marker spelling (including the migration-only grace state while one exists), and the current clocks, so the scheme explains itself to any later reader or tool.
- Refresh a `reinforced:` date only on real evidence from the current session: the fact was used, confirmed, or re-derived.
  Mere presence in the file is not evidence, and re-reading memory is never reinforcement.
- Re-confirm a stale `perishable` entry against its named condition: still open means refresh the date, while resolved, expired, or no longer checkable means archive it now.
- Decay is evaluated only when this skill runs; nothing happens between passes, so an infrequently stowed project experiences the clocks at its stow interval.
- Stale never means deleted: a stale entry moves, with its marker and a one-line reason, to a `.stow-archive.md` in the source file's own directory, never loaded by any session.
  In a git worktree, verify that this archive path is not already tracked in the index before writing any archived fact there.
  If it is tracked, do not write to it and report that archival is blocked until the user chooses a safe destination.
  Otherwise add a `.stow-archive.md` line to a `.gitignore` file in the archive's directory, and never write archived facts into a git-tracked file.
  Recovery is search plus copy back.
- Pre-existing unmarked entries are the file's default tier with unknown age, and unknown age is not guilt: an unmarked entry in a default-pinned file is simply pinned and exempt from the aging clock, legacy grace cycle, and archive-by-age, though consolidation still applies.
- In a file whose default tier carries a clock, the first pass stamps each unmarked entry it can confirm; otherwise it adds `<!-- legacy-grace: pending -->` without a `reinforced:` date to persist one grace cycle without treating presence as reinforcement.
  On the next pass, current evidence replaces that marker with the normal tier marker; without such evidence, archive the entry with a `legacy-unvalidated` note.
  The same persisted transition applies to an entry a hand edit later leaves unmarked in a file whose default tier carries a clock.
- When an always-loaded memory file has grown past what every session should pay for, this skill may propose - never execute - moving a durable entry that matters only in a nameable situation into an on-demand-loaded home, such as a skill or scoped instruction file the user's agent loads only when that situation arises.
  The user approves each move, the new home is created through the user's own change process rather than by this skill, and the entry leaves the memory file only once the new home exists.
  No unique current fact is ever plainly removed during this flow; before the on-demand home is live, its only exit from the loaded file is archival with provenance in the recoverable cold tier.

## What this skill does not do

It does not invent a new note-taking system, initialize version control, or stage, commit, or push anything on the user's behalf - every write, including the `.gitignore` line, lands in the working tree for the user to review and commit like any other change.
It never files credentials, secrets, or other sensitive material - only knowledge that's safe to keep in plain text wherever it lands.
It never files anything to an issue tracker, hosted board, or other external or public system on its own inference - that only ever happens on the user's explicit say-so, per the hard rule in step 3.
