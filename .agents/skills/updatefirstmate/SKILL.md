---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate with surface-appropriate wording that names the files that moved, so the whole tree runs the latest bin/ and instructions and every home can re-validate its own memory against the change.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `firstmate-changed-surface: <comma-list>|none`
   - `firstmate-changed-files: <comma-list>|none`
   - `firstmate-changed-range: <before>..<after>|none`
   - `nudge-secondmates: fm-<id>...|none`
   - `nudge-surface fm-<id>: <comma-list>|unknown` (one per nudge target)
   - `nudge-files fm-<id>: <comma-list>|unknown` (one per nudge target)
   - `nudge-range fm-<id>: <before>..<after>|unknown` (one per nudge target)

   The changed-FILES lines are what make an update checkable rather than merely announced.
   A list ending in a `+N-more` element was capped to keep the nudge one line; the matching range recovers the rest.

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

   **Then re-validate your own memory against `firstmate-changed-files`.**
   Load the `stow` skill and run its mechanism-change re-validation over that file list.
   A memory entry that names one of those files is due for re-validation regardless of how recently it was reinforced: the tier clocks measure elapsed time, and a mechanism that moved yesterday falsifies an entry admitted yesterday.
   Skip this only when `firstmate-changed-files` is `none`.

3. **Nudge each updated live secondmate, naming what moved.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), read its matching `nudge-surface fm-<id>:`, `nudge-files fm-<id>:`, and `nudge-range fm-<id>:` lines.
   The surface chooses the wording; the files and range are what the receiving home checks its own holdings against.

   **Every nudge names the changed files.**
   A notice that says only that something moved catches only what you already knew to mention, and you cannot know what that home is holding.
   Substitute the target's real `<files>` and `<range>` into the wording below - never a placeholder, never a summary of them.

   - **Instructions changed** - the surface includes `AGENTS.md` or `.agents/skills` (with or without `bin`).
     ```sh
     FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest (<range>) - changed: <files>. Re-read your AGENTS.md, then re-validate any memory entry that names one of those files, whatever its date.'
     ```

   - **Tooling only** - the surface is exactly `bin` with no instruction paths.
     ```sh
     FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate tooling was updated to the latest (<range>) - changed: <files>. Your operating instructions did not change, so no AGENTS.md re-read, but re-validate any memory entry that names one of those files, whatever its date.'
     ```

   - **Indeterminate** - the surface or file list is `unknown` (a remote route, or paths that could not be determined).
     Prefer the re-read as the safe default, and leave the home to recover the changed set locally, which the `stow` skill owns:
     ```sh
     FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest but the changed files could not be determined here - re-read your AGENTS.md, then re-validate your memory against whatever moved in your own home.'
     ```

   The tooling-only notice is not a courtesy line.
   It is load-bearing for memory correctness: it is the only signal that reaches a home before a falsified entry is read as settled fact, so send it even when nothing about the instructions changed.
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A local or remote secondmate gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
