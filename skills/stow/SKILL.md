---
name: stow
description: Sweep the current conversation for durable knowledge - user preferences, project facts, operational gotchas, and unfinished next steps - and file each into wherever the project or user already keeps that kind of note, so nothing is lost when the session ends. Use when the user invokes /stow, asks to save or write down what was learned this session, or before a context reset or long break.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. The firstmate-internal counterpart lives at .agents/skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

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
   Do not scan for or infer an issue tracker here - see the hard rule in step 3.

3. **Route each finding to the most specific existing home, local-first.**
   - User preferences -> the discovered user-level memory file, if one exists and is writable.
   - Project facts -> the project's own memory file (e.g. `CLAUDE.md`/`AGENTS.md`), if it exists.
   - Operational gotchas -> the same project memory file, or a project `NOTES`/`BACKLOG` file if that is this project's convention for that kind of thing.
   - Undone next steps -> **always local by default**: the project's `TODO`/`BACKLOG`/`NOTES` file when one already exists, or otherwise a small local notes/scratch file you create for this purpose.
     A freshly created local notes file lives only on the user's own machine, is private, and is trivially reversible, so creating one for this specific case is fine even though step 5 otherwise avoids inventing new files.
   **Hard rule: never route anything to an external or public system - an issue tracker, a hosted project board, a ticketing system, or similar - based on inference or heuristics.**
   A configured git host remote, a `.github/`/`.gitlab/` folder, or any other signal that a tracker probably exists is never by itself grounds to file anything there.
   Use a tracker (or any other non-local system) only when the user has explicitly told you to - either said plainly earlier in this conversation, or previously recorded as a standing choice in the discovered user-level memory file (see step 4).
   Absent that explicit instruction, everything stays local, and no confirmation dance is needed for the local-first default itself.

4. **When it's genuinely ambiguous, ask once - then remember the answer.**
   If no discovered convention clearly fits a finding (for user preferences, project facts, or operational gotchas), or more than one plausibly does, ask the user once, plainly, where they want that kind of note to live going forward.
   The same applies if the user gives an explicit instruction to use a tracker or other non-local system going forward rather than just for one item right now.
   Once they answer, offer to remember it for next time: with their explicit permission, record a short standing note of that choice in the discovered (or newly agreed) user-level memory file, so the same question - or the same tracker instruction - doesn't need to be repeated in this project.
   Always ask before adding that note - never establish the convention silently on your own judgment.

5. **Write only into locations that already exist as a real convention, the local scratch-file fallback from step 3, or a destination the user just approved in step 4.**
   Do not invent new shared files, new folders, or new tracker categories the project doesn't already have.
   If nothing existing fits and the user doesn't want to establish a new convention, say so plainly and leave that finding unfiled rather than fabricate a destination for it.

6. **Curate, don't just append.**
   When a finding overlaps or supersedes something already recorded, prefer editing or replacing the existing note over piling on a duplicate.

7. **Finish with an honest safe-to-end verdict.**
   Tell the user, in plain language, what was captured and where, what could not be captured (and why), and whether the conversation is now safe to end or reset - i.e. whether every durable finding from this sweep now lives on disk or in an explicitly requested tracker rather than only in this chat.
   If something could not be captured yet, say so explicitly instead of reporting the session fully safe.

## What this skill does not do

It does not invent a new note-taking system, initialize version control, or commit/push anything on the user's behalf beyond editing a file the discovered convention already made writable, creating the local scratch-file fallback for undone next steps, or using a destination the user explicitly approved.
It never files credentials, secrets, or other sensitive material - only knowledge that's safe to keep in plain text wherever it lands.
It never files anything to an issue tracker, hosted board, or other external/public system on its own inference - that only ever happens on the user's explicit say-so, per the hard rule in step 3.
