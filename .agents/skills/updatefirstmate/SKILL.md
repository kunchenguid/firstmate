---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
  Also performs pull-only upstream sync from `kunchenguid/firstmate`, merging upstream commits into this repo's main through the validated gate, when the captain says "sync upstream" (or asks to bring in upstream commits).
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
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
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

## Upstream sync (kunchenguid/firstmate -> pruge/firstmate)

This repo is a downstream of the true upstream `kunchenguid/firstmate`, whose `main` evolves daily while ours carries local commits such as the planning-family skills.
Syncing means merging `upstream/main` into this repo's `main` through the same validated gate as any project change, then refreshing the fleet onto the synced commit.
This mode runs only when the captain invokes it by saying "sync upstream" (or asking to bring in upstream commits); it is pull-only - nothing is ever pushed to `kunchenguid/firstmate`.

1. **Confirm preconditions.**
   The captain asked for this sync.
   This repo has no uncommitted tracked changes.
   Prefer landing or rebasing in-flight feature PRs first, so conflicts resolve once instead of twice.

2. **Ensure the upstream remote exists, then fetch it:**
   ```sh
   git remote add upstream https://github.com/kunchenguid/firstmate.git
   git fetch upstream main
   ```

3. **Quantify divergence and report it to the captain:**
   ```sh
   git rev-list --left-right --count main...upstream/main
   ```

4. **Branch off `main`:**
   ```sh
   git switch -c sync/upstream-<YYYY-MM-DD>
   ```

5. **Merge upstream and resolve conflicts under the UNION policy:**
   ```sh
   git merge upstream/main
   ```
   Keep every downstream addition - planning-family skills, their AGENTS.md/docs references, documentation-audiences entries - AND take upstream's newer machinery everywhere else.
   Where both sides edited the same lines, prefer upstream unless doing so erases a planning-family reference.
   Never delete downstream-only files.

6. **Validate locally; green is required before push:**
   ```sh
   bin/fm-lint.sh
   bin/fm-test-run.sh
   ```

7. **Push through the gate, never straight to origin:**
   ```sh
   git push no-mistakes sync/upstream-<date>
   ```
   The pipeline validates the branch independently and opens the PR with its body signature.

8. **Leave merge authority with the captain.**
   On approval, merge the PR with a merge commit (`--merge`), never squash.
   Squashing would orphan upstream ancestry and break future syncs.

9. **After landing, rerun the origin refresh flow above (`bin/fm-update.sh`).**
   Every running home then fast-forwards onto the synced `main`, re-reads `AGENTS.md` when told, and nudges secondmates.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A local or remote secondmate gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
- **Upstream sync is pull-only.**
  Nothing is ever pushed to `kunchenguid/firstmate`; syncing only ever merges fetched upstream commits into this repo.
