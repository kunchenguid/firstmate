---
name: updatefirstmate
description: Self-update a running firstmate and its secondmates to the latest from origin. Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate"). Fast-forwards this firstmate repo's default branch and every secondmate home from origin (fast-forward only, never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, so shared tracked material reaches `main` through a green PR and exact-head Crosscheck, then waits for each running firstmate to pull it; `AGENTS.md` section 12 owns that material's self-update boundary.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then fast-forwards every registered secondmate home (each a treehouse worktree of this same repo, leased at a detached HEAD on the default branch) the same way.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`
   If an older updater skips a home whose only reported dirt is untracked `config/` content or root `.*.crosscheck.lock` files, rerun that same stale entrypoint with a command-scoped excludes file:
   ```sh
   (
     fm_update_state="${FM_HOME:-$(pwd -P)}/state"
     mkdir -p "$fm_update_state" || exit
     fm_update_excludes=$(mktemp "$fm_update_state/.fm-update-bootstrap-excludes.XXXXXX") || exit
     trap 'unlink "$fm_update_excludes"' EXIT
     trap 'exit 129' HUP
     trap 'exit 130' INT
     trap 'exit 143' TERM
     printf '/config/\n/.*.crosscheck.lock\n' > "$fm_update_excludes" || exit
     GIT_CONFIG_COUNT=1 \
     GIT_CONFIG_KEY_0=core.excludesFile \
     GIT_CONFIG_VALUE_0="$fm_update_excludes" \
     bin/fm-update.sh
     fm_update_result=$?
     exit "$fm_update_result"
   )
   ```
   This changes only the stale process's untracked-file view, so tracked changes and unrelated untracked files still block while the fast-forward lands the durable ignore rules.

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
   Summarize what landed without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both domain supervisors are now on the latest."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  The artifact bootstrap is allowed only for untracked home-local config and root Crosscheck locks; unrelated dirt remains a refusal.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A secondmate gets a tracked-files fast-forward (safe while it is mid-task, since its work lives in gitignored operational dirs and separate project worktrees) plus a gentle re-read nudge.
  It is never torn down, interrupted, or forced.
