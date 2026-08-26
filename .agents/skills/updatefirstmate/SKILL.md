---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), rebuilds each updated home's rule index with fm-regeln ingest, then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/, rules, and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same gate as any project, so new tracked material (`AGENTS.md`, `regeln/`, `bin/`, `.agents/skills/`, and public `skills/`) reaches the default branch and then sits there until each running firstmate pulls it.
`AGENTS.md`, `regeln/`, `bin/`, and `.agents/skills/` are a running firstmate's instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
`regeln/` is main-authoritative and travels as a git diff, never as a copy - which is why the ingest step below is not optional.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.

**The update guard is part of the advance, not a separate check.**
Before every fast-forward, `ff_target` (`bin/fm-ff-lib.sh`) runs `bin/fm-regel-eval.sh run` against `regeln/INVARIANTEN.tsv` in a temporary worktree at the candidate commit.
Only a green result advances the home; a red one prints `skipped: regel-eval red at <commit>` and the update simply never takes effect, so there is nothing to roll back.
Read such a skip as "that commit would have broken a gate here", not as a transport failure: inspect the named commit rather than retrying, and never work around the guard by advancing a home by hand.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

2. **Rebuild the rule index in every home that advanced.**
   Tracked `regeln/*.yaml` is the source; each home's rule database and vector index are local build artifacts that a fast-forward does not regenerate, so an updated home keeps serving the OLD rules until it ingests.
   For this home:
   ```sh
   bin/fm-regeln ingest
   ```
   For each local secondmate that the updater reported as `updated`, run the same command in that home (`FM_HOME=<that-home> bin/fm-regeln ingest`); for a remote route, run it on that host through `bin/fm-on.sh`.
   Ingest is idempotent, so re-running it in an already-current home costs nothing.
   A refusal is actionable, not skippable: it means the new `regeln/` did not satisfy its own schema in that home, and that home is running stale rules until it is fixed.

3. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `regeln/`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

4. **Nudge each updated live secondmate.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

5. **Report to the captain in plain outcomes.**
   Say which parts of the fleet are now on the latest and which were left as-is and why, in his terms and without firstmate's internal vocabulary.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Surface any skipped target whose reason needs his attention - a home with its own un-landed changes (diverged), one with local edits (dirty), or one the update guard held back at a specific commit, all left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, on a non-default branch, or held by the update guard is skipped and reported, never forced or stashed.
  This path discards nothing and needs no salvage snapshot, because it never destroys: unlanded work simply stays where it is on a skipped target.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A local or remote secondmate gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
