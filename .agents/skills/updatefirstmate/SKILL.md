---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  When private-upstream configuration is present, safely integrates and validates the public upstream in a disposable clone before publishing private origin/main.
  Then fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

An installation may opt into a private distribution with local `config/private-upstream`.
In that mode the updater first integrates the declared public branch into private `origin/main` in a disposable clone, validates the result, and publishes only to the declared private URL.
The running copy remains untouched until that publication succeeds, then the normal guarded origin fast-forward updates it and its secondmates.
The operator setup and current config contract are in [`docs/configuration.md`](../../../docs/configuration.md#private-upstream-distribution-configprivate-upstream), while `bin/fm-private-update.sh` owns exact parsing and mechanics.

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
   Without private-upstream configuration, it fast-forwards this firstmate repo's default branch from origin exactly as before, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   With private-upstream configuration, it first prints a `private-upstream:` outcome for the isolated integration and private publication, then fast-forwards this firstmate repo and every registered local or remote secondmate home from private origin the same way.
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
   In private mode, say whether the public update was already included or was validated and published to private main before the fleet advanced.
   If the private integration stopped, name the reason and the reported evidence path, and make clear that private main and the running fleet were left unchanged.
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Private integration is isolated.**
  Merge conflicts, validation failures, divergence, and push failures preserve a disposable evidence clone and stop before the running checkout or secondmates can advance.
- **Public remotes are read-only.**
  Private mode validates the declared private origin fetch and push URL, the declared public upstream fetch URL, and the public remote's disabled push sentinel before performing network work.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A local or remote secondmate gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
