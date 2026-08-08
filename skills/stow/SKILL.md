---
name: stow
description: Sweep the current conversation for durable knowledge - user preferences, project facts, operational gotchas, standing decisions, and unfinished next steps - and file each through explicit instructions, existing local conventions, or the private `.stow-notes.md` fallback, curating the destination files as it writes. Use when the user invokes /stow, asks to save or write down what was learned this session, or before a context reset or long break.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone, with no private project paths, tool assumptions, or environment branching. The firstmate-internal counterpart lives at .agents/skills/stow/SKILL.md - deliberately a separate file with no shared code. Keep them independent. -->

# stow

Sweep this conversation for durable knowledge that only exists in chat right now, and file it through the user's explicit instructions, the project's existing local conventions, or the private `.stow-notes.md` fallback in the current directory.
The goal is to leave the next session a compact, current operating map, not an accumulating journal: every durable finding lands on disk, and every file this skill touches comes out more accurate, not merely longer.
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
   If the fallback is unwritable and the user doesn't want a new convention, say so plainly and leave that finding unfiled rather than fabricate a destination.

6. **Read the destination before writing: inspect-then-update, never blind-append.**
   Before writing any finding, read the destination file's current contents in full.
   Then ask, for each finding: which existing entry does it supersede; can it be a one-sentence rewrite of an existing entry instead of a new one; and should a stale entry now be deleted or replaced in the same pass?
   For an existing `TODO`/`BACKLOG`/`NOTES` item, inspect the full item, classify the change as new, duplicate, superseding, or obsolete, then write a considered replacement body rather than appending to it.
   File each undone next step with what it is waiting on, when it is genuinely blocked on something.

7. **Curate every memory file this pass has open, not only the one a finding routes to.**
   Prune what is no longer current: completed chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, superseded claims, duplicates, and report-sized procedures that belong in a report or doc.
   Prefer one concise current rule, or a pointer to the authoritative source, over duplicate prose.
   The counterweight: never remove a unique current fact unless it is preserved elsewhere by a stronger owner.
   This is an accuracy discipline, not a length target - a stale entry misleads the next session; a current one earns its place.
   A `.stow-notes.md` note has exactly three exits: promotion into a shared, tracked file the user approves, folding into a discovered user-level memory file, or deletion as stale - do not invent another.

8. **Finish with an honest safe-to-end verdict and a resume pointer for the next session.**
   Report one action per file this sweep touched or considered: `unchanged`, `added`, `rewritten`, `pruned`, or `routed` (the finding went to a different owner).
   Then tell the user, in plain language, what was captured and where, what could not be captured (and why), and whether the conversation is now safe to end or reset - that is, whether every durable finding from this sweep now lives on disk or in an explicitly requested tracker rather than only in this chat.
   If something could not be captured yet, say so explicitly instead of reporting the session fully safe.
   If anything landed in `.stow-notes.md`, say so - note that it is private and confined to this project, and name its promotion exit from step 7 if the user wants it more widely visible.
   In a git repo, report the ignore protection as it actually happened: either the `.gitignore` line was added and awaits the user's own commit, or the write failed and the user must ignore `.stow-notes.md` manually before relying on git to hide it.
   If the fallback was blocked because `.stow-notes.md` was already tracked, say that no private fallback was written and the session is not fully safe to reset until the user chooses another destination or accepts that tracked file.
   If a user preference landed in `.stow-notes.md` because no user-level memory file was discovered, add one caveat: it now applies to this project only, and the user must copy it into their own global memory file themselves if they want it to follow them across projects.
   The real payoff of stowing is not this session but the next one: close with a short, copy-pasteable RESUME POINTER naming exactly which files a fresh session should load to pick this back up cold, e.g. `To pick this back up in a new session, load: CLAUDE.md (project conventions), .stow-notes.md (private notes, not shared)`.
   List only the files this sweep actually wrote or updated; skip the pointer if nothing was written.

## What this skill does not do

It does not invent a new note-taking system, initialize version control, or stage, commit, or push anything on the user's behalf - every write, including the `.gitignore` line, lands in the working tree for the user to review and commit like any other change.
It never files credentials, secrets, or other sensitive material - only knowledge that's safe to keep in plain text wherever it lands.
It never files anything to an issue tracker, hosted board, or other external or public system on its own inference - that only ever happens on the user's explicit say-so, per the hard rule in step 3.
