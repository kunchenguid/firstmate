---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from this fleet's fork.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Merges upstream origin into fork/main, then fast-forwards this firstmate repo's default branch and every local or remote secondmate to the fork through its guarded update path (fast-forward only, never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.

This fleet runs a **fork**, so an update is two hops, never one:

- `origin` is the shared upstream that many fleets pull from.
- `fork` is this fleet's own remote, and `fork/main` carries upstream **plus this fleet's private adaptations**.
- Every home runs `fork/main`.

Upstream therefore enters only by being merged **into** `fork/main`, and each home then fast-forwards to `fork/main`.
A home is never advanced from origin: that would strip the fleet's adaptations, which is exactly what the fork exists to keep.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that update for the running main firstmate and every secondmate, without disturbing any in-flight work.

The home advance is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
For a remote route, it updates the configured Firstmate code root on that host from that host's own remote, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
The one commit an update may create is the upstream merge on `fork/main`, and a conflicting merge stops the run instead of forcing it; no home advance ever creates a commit.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It merges `origin/main` into `fork/main` and pushes the result to the fork, then fast-forwards this firstmate repo's default branch to `fork/main`, then updates every registered local or remote secondmate home to the fork through its placement-specific guarded path.
   It prints one `upstream: ...` ingest line, one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

   **If the ingest hits a conflict it stops and exits non-zero**, printing each conflicted path.
   Nothing was pushed and no home moved, so the fleet is simply still on its previous version - it is not half-updated.
   This is a captain-facing decision, not something to force past: report the conflicted paths and let the captain decide how upstream and the fleet's adaptations should be reconciled.

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

- **Fast-forward only for every home.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Never advance a home from origin.**
  Homes track the fork; origin reaches them only through the `fork/main` merge.
  An origin advance would silently strip the fleet's adaptations.
- **A conflicting ingest stops the run.**
  It is never forced and never partially applied: the fork keeps its tip and every home stays where it is.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A local or remote secondmate gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
