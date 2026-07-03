---
name: stow
description: Sweep the current conversation for durable knowledge - user preferences, project facts, operational gotchas, and unfinished next steps - and file each into wherever the project or user already keeps that kind of note, so nothing is lost when the session ends. Use when the user invokes /stow, asks to save or write down what was learned this session, or before a context reset or long break.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. The internal counterpart for this repo lives at .agents/skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this conversation for durable knowledge that only exists in chat right now, and write it to wherever this project or user already keeps that kind of note.
The goal is a conversation that is safe to end, reset, or hand off because everything durable has already been captured on disk, not left stranded in the transcript.
Everything this skill files goes to a local file by default; it only ever reaches an external system such as an issue tracker when you have explicitly said to use one.

## What it does

1. **Sweep the conversation for uncaptured durable knowledge.**
   Read back over the session and look for:
   - User preferences: a working-style, tooling, formatting, or approval preference the user stated in passing rather than through a config file.
   - Project facts: build, test, deploy, architecture, or convention facts about the current project that would help anyone (or any agent) working in it later.
   - Operational gotchas: a sharp edge, workaround, recurring mistake, or non-obvious cause discovered while working here.
   - Undone next steps: anything left open or agreed to that has not yet been written down anywhere.

2. **Discover the host's existing conventions before deciding where anything goes.**
   Don't assume a destination - look for what's actually there, roughly in this order:
   - A project-level memory file, such as `CLAUDE.md`, `AGENTS.md`, or an equivalent at the repo root or nearby.
   - A user-level (global) memory file the running agent reads across projects, if one exists and is readable.
   - A `TODO`, `BACKLOG`, `NOTES`, or similarly named plain file already tracked in the project.
   This step is about local, private files only.
   Do not scan for or infer an issue tracker here - see the priority order in step 3.

3. **Route each finding using this fixed priority order, local-first.**
   1. **Highest - an explicit instruction wins.** If the user has explicitly said, earlier in this conversation or as a standing choice previously recorded in the discovered user-level memory file (see step 4), to use a particular system for this kind of finding - including an external tracker - route it there. This is the *only* path to an external or public system: an issue tracker, a hosted project board, a ticketing system, or similar. A configured git host remote, a `.github/`/`.gitlab/` folder, or any other signal that a tracker probably exists is never by itself grounds to file anything there - never route externally on inference.
   2. **Otherwise - the local system the user already uses.** Route to whatever local memory/backlog convention this project or user already has for that kind of finding: the discovered project memory file (`CLAUDE.md`/`AGENTS.md`) for project facts and operational gotchas, the discovered user-level memory file for user preferences, or an existing `TODO`/`BACKLOG`/`NOTES` file for undone next steps. This tier is the only one that writes into a tracked, shared file - use it only because that sharing was already the project's or user's own established convention, not your own judgment call.
   3. **Fallback - the default prescribed private file, scoped to match the finding.** If no existing local convention fits, don't improvise a location or invent an ad hoc filename; use the one prescribed default for that finding's natural scope, both host-local:
      - **User preferences**, when no user-level memory file was discovered: `~/.stow/notes.md` in the user's home directory. Preferences are cross-project by nature, so this fallback lives outside any one project entirely and stays available in every project, never siloed into a single repo.
      - **Project facts, operational gotchas, and undone next steps**, when no project convention was discovered: `.stow-notes.md` at the project root. If the project is a git repository and that path isn't already excluded, add a line for it to `.git/info/exclude` - git's local-only exclude file, never the tracked `.gitignore` - so it is kept out of git with zero shared-repo diff and nothing for the user to review or commit. If the project is not a git repository, just create the file - there is nothing to exclude.
   Tiers 2 and 3 are always local; only tier 1 - an explicit instruction - ever reaches an external or public system. Tier 2 is the only tier that lands in a tracked/shared file, because tier 2 only fires when that sharing was already the project's own convention; tier 3 stays private and host-local precisely because nothing established that convention.

4. **When it's genuinely ambiguous between two existing conventions, ask once - then remember the answer.**
   If more than one discovered local convention plausibly fits a finding, ask the user once, plainly, which one they want that kind of note to live in going forward.
   The same applies if the user gives an explicit instruction to use a tracker or other non-local system going forward rather than just for one item right now.
   Once they answer, offer to remember it for next time: with their explicit permission, record a short standing note of that choice in the discovered (or newly agreed) user-level memory file, so the same question - or the same tracker instruction - doesn't need to be repeated in this project.
   Always ask before adding that note - never establish the convention silently on your own judgment.
   When nothing existing fits at all (not merely ambiguous), that's tier 3, not this step - route to `~/.stow/notes.md` for user preferences or `.stow-notes.md` for everything else, per step 3, instead of asking.

5. **Write only into locations that already exist as a real convention, the tier-3 fallback files from step 3 (`~/.stow/notes.md` for user preferences; `.stow-notes.md`, plus its `.git/info/exclude` entry when the project is a git repo, for everything else), or a destination the user just approved in step 4.**
   Do not invent new shared files, new folders, or new tracker categories the project doesn't already have, and do not pick an ad hoc filename or location for either fallback - these two prescribed defaults are it.
   If even the applicable fallback is unwritable and the user doesn't want to establish a new convention, say so plainly and leave that finding unfiled rather than fabricate a destination for it.

6. **Curate, don't just append.**
   When a finding overlaps or supersedes something already recorded, prefer editing or replacing the existing note over piling on a duplicate.

7. **Finish with an honest safe-to-end verdict and a resume pointer for the next session.**
   Tell the user, in plain language, what was captured and where, what could not be captured (and why), and whether the conversation is now safe to end or reset - i.e. whether every durable finding from this sweep now lives on disk or in an explicitly requested tracker rather than only in this chat.
   If something could not be captured yet, say so explicitly instead of reporting the session fully safe.
   If anything landed in a tier-3 private fallback (`~/.stow/notes.md` or `.stow-notes.md`), say so explicitly - note that it is private and host-local (and, for the project file in a git repo, that a `.git/info/exclude` entry now keeps it out of git with no shared-file diff to review or commit) - and that it can be promoted into a shared, tracked file later if the user wants it more widely visible.
   The real payoff of stowing is not this session, it's the next one: close with a short, copy-pasteable RESUME POINTER naming exactly which files a fresh session should load to pick this back up cold, e.g. `To pick this back up in a new session, load: CLAUDE.md (project conventions), .stow-notes.md (private project notes), ~/.stow/notes.md (private preferences)`.
   List only the files this sweep actually wrote or updated; skip the pointer if nothing was written.

## What this skill does not do

It does not invent a new note-taking system, initialize version control, or commit/push anything on the user's behalf beyond editing a file the discovered convention already made writable, creating the tier-3 private fallback files (`~/.stow/notes.md`, `.stow-notes.md`) and the project file's `.git/info/exclude` entry, or using a destination the user explicitly approved.
It never touches the tracked `.gitignore` for this purpose and never stages or commits anything on the project's behalf - `.git/info/exclude` is host-local by design, so there is nothing for the user to review or commit.
It never files credentials, secrets, or other sensitive material - only knowledge that's safe to keep in plain text wherever it lands.
It never files anything to an issue tracker, hosted board, or other external/public system on its own inference - that only ever happens on the user's explicit say-so, per the hard rule in step 3.
