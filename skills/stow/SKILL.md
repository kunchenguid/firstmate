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
   3. **Fallback - the default prescribed private file.** If no existing local convention fits, don't improvise a location or invent an ad hoc filename. Create or append to `.stow-notes.md` at the project root: a private, gitignored default, not a tracked or shared one. Because it is private, this fallback is safe for every finding-kind, including user preferences - nothing lands unprompted in a shared or committed file. If the project is a git repository and `.stow-notes.md` isn't already covered by an existing ignore rule, add one line for it to `.gitignore` so it can never be accidentally committed - do this transparently and note it in the closing verdict (step 7); leave staging or committing that `.gitignore` change to the user, same as everything else this skill writes. If the project is not a git repository, just create the file - there is nothing to ignore.
   Tiers 2 and 3 are always local; only tier 1 - an explicit instruction - ever reaches an external or public system. Tier 2 is the only tier that lands in a tracked/shared file, because tier 2 only fires when that sharing was already the project's own convention; tier 3 stays private precisely because nothing established that convention.

4. **When it's genuinely ambiguous between two existing conventions, ask once - then remember the answer.**
   If more than one discovered local convention plausibly fits a finding, ask the user once, plainly, which one they want that kind of note to live in going forward.
   The same applies if the user gives an explicit instruction to use a tracker or other non-local system going forward rather than just for one item right now.
   Once they answer, offer to remember it for next time: with their explicit permission, record a short standing note of that choice in the discovered (or newly agreed) user-level memory file, so the same question - or the same tracker instruction - doesn't need to be repeated in this project.
   Always ask before adding that note - never establish the convention silently on your own judgment.
   When nothing existing fits at all (not merely ambiguous), that's tier 3, not this step - use the `.stow-notes.md` fallback from step 3 instead of asking, for any finding-kind, since that fallback is private.

5. **Write only into locations that already exist as a real convention, the `.stow-notes.md` fallback from step 3 (plus its one-line `.gitignore` entry when the project is a git repo), or a destination the user just approved in step 4.**
   Do not invent new shared files, new folders, or new tracker categories the project doesn't already have, and do not pick an ad hoc filename or hidden location for the fallback - `.stow-notes.md` at the project root is the one prescribed default.
   If even that fallback is unwritable and the user doesn't want to establish a new convention, say so plainly and leave that finding unfiled rather than fabricate a destination for it.

6. **Curate, don't just append.**
   When a finding overlaps or supersedes something already recorded, prefer editing or replacing the existing note over piling on a duplicate.

7. **Finish with an honest safe-to-end verdict and a resume pointer for the next session.**
   Tell the user, in plain language, what was captured and where, what could not be captured (and why), and whether the conversation is now safe to end or reset - i.e. whether every durable finding from this sweep now lives on disk or in an explicitly requested tracker rather than only in this chat.
   If something could not be captured yet, say so explicitly instead of reporting the session fully safe.
   If anything landed in the `.stow-notes.md` private fallback, say so explicitly - note that it is private (and, when applicable, that a `.gitignore` entry for it is now in the working tree awaiting the user's own commit) - and that it can be promoted into a shared, tracked file later if the user wants their team to see it.
   The real payoff of stowing is not this session, it's the next one: close with a short, copy-pasteable RESUME POINTER naming exactly which files a fresh session should load to pick this back up cold, e.g. `To pick this back up in a new session, load: CLAUDE.md (project conventions), .stow-notes.md (private notes, not shared)`.
   List only the files this sweep actually wrote or updated; skip the pointer if nothing was written.

## What this skill does not do

It does not invent a new note-taking system, initialize version control, or commit/push anything on the user's behalf beyond editing a file the discovered convention already made writable, creating the `.stow-notes.md` fallback from step 3 and its accompanying one-line `.gitignore` entry, or using a destination the user explicitly approved.
It never stages or commits that `.gitignore` change itself - the edit lands in the working tree only, for the user to review and commit like any other change.
It never files credentials, secrets, or other sensitive material - only knowledge that's safe to keep in plain text wherever it lands.
It never files anything to an issue tracker, hosted board, or other external/public system on its own inference - that only ever happens on the user's explicit say-so, per the hard rule in step 3.
