---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest effective revision.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards the pristine upstream base and publishes either that base or its configured held-improvement effective revision through guarded update paths, then re-reads AGENTS.md and nudges each updated secondmate.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

Without a held stack, the update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
With `config/held-improvements/` initialized, the default branch still fast-forwards only, while a scratch worktree transactionally reapplies the explicit patches and publishes a detached effective revision after the complete stack succeeds.
Content already present upstream retires automatically by verbatim patch or exact resulting content, independent of commit identity.
A genuine replay conflict keeps the last known-good effective revision live and writes the existing nightly attention alarm naming the held improvement, the upstream change, and the paths.
For a remote route in default mode, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
Held mode does not send primary-private patches to a remote host and reports that route as skipped.
It never creates a merge commit or stashes; anything dirty, diverged, offline, on the wrong branch, or outside the held stack's known-effective set is skipped and reported.
Tracked-file updates leave the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's pristine default branch from origin, publishes the configured held-stack candidate when active, then updates every registered secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live secondmate.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Pristine upstream plus transactional effective revision.**
  The default branch only fast-forwards.
  Held patches are explicit local configuration, are tested in a scratch worktree, and never change the live detached revision until the full candidate succeeds.
  Without held mode, a target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A linked local secondmate in held mode moves only from a clean detached known-effective commit to the primary's current effective commit.
  Other local or remote targets get their existing guarded fast-forward only when safe, plus a gentle re-read nudge when changed.
  It is never torn down, interrupted, or forced.
