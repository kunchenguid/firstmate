---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
  Also detects when the fork is behind its upstream repo and opens a reviewable upstream merge PR (never a blind merge into main).
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
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by three action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`
   - `upstream-merge: none | current | needed (<N> behind, <M> ahead) | skipped: <reason>`

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

4. **Open an upstream merge PR when the fork is behind upstream.**
   Act on the `upstream-merge:` line:
   - `none` or `current` - nothing to do; the fork has no upstream remote or is already in sync with it.
   - `skipped: <reason>` - surface to the captain only when the reason needs attention (a dirty tree or an upstream fetch failure means the check could not run and should be looked at); an off-default-branch skip during other in-flight firstmate work is expected and needs no report.
   - `needed (<N> behind, <M> ahead)` - the fork is behind upstream and an upstream merge PR should be opened, but firstmate does NOT perform the merge in its primary checkout: the merge produces shared tracked changes that must ship through no-mistakes and a captain-approved PR.
     Do this in two steps:
     1. **Check for an already-open upstream merge PR first**, so a run does not open a duplicate every time the fork is behind.
        List open PRs whose head branch matches the upstream-merge convention:
        ```sh
        gh-axi pr list --state open
        ```
        If any open PR has a head branch matching `fm/merge-upstream-*`, report that existing PR's full URL to the captain and do NOT open another.
     2. **Otherwise dispatch a crewmate** (firstmate-repo, no-mistakes ship) to prepare the merge on a branch and open the PR.
        The brief must instruct the crewmate to:
        - create branch `fm/merge-upstream-<YYYY-MM-DD>` from the up-to-date `main`;
        - `git fetch upstream` and `git merge upstream/<default-branch>`;
        - resolve conflicts using firstmate's fork-merge convention - superset-wins: keep the union of both sides' intent, and take upstream wholesale for files the fork never customized;
        - load `firstmate-coding-guidelines` (this touches firstmate's own shared tracked material);
        - run no-mistakes and open the PR.
     The captain owns the actual merge; firstmate never merges the upstream PR without the captain's explicit word (prime directive #2).

5. **Report to the captain in plain outcomes.**
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
- **Upstream merges land only through a reviewed PR, never a direct write to `main`.**
  Unlike the origin path, the fork is diverged from upstream, so pulling upstream is a real 3-way merge with likely conflicts on shared files (`AGENTS.md` and the like) - not a fast-forward.
  `bin/fm-update.sh` only DETECTS the divergence and reports it; it never branches, merges, resolves conflicts, or pushes for upstream.
  The merge and conflict resolution happen on a `fm/merge-upstream-<date>` branch in a dispatched crewmate's isolated worktree, ship through no-mistakes, and reach `main` only via a captain-approved PR.
  The captain owns the merge (prime directive #2), and nothing ever writes upstream commits straight into `main`.
