---
name: updatefirstmate
description: >-
  Self-update a running firstmate to the latest from origin.
  Use when the captain invokes /updatefirstmate (for example, "update firstmate" or "pull the latest firstmate").
  Updates this Firstmate checkout through its guarded fast-forward path and then re-reads AGENTS.md when the tracked instruction surface changed.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update Firstmate in place.
Firstmate is its own repository, behind the same intent-aware native review and forge-check path as any reviewed project, so new tracked material reaches `main` and then waits for each running Firstmate to pull it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running Firstmate instruction surface; public `skills/` is installer-facing and is not loaded by Firstmate.

The update is fast-forward only, like fleet sync.
It never forces, creates a merge commit, stashes, or touches anything under `projects/`.
A tracked-files update leaves the gitignored operational directories (`data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/`) untouched.

## Procedure

1. Run the updater:

   ```sh
   bin/fm-update.sh
   ```

   It prints the repository outcome and `reread-firstmate: yes|no`.
   A dirty checkout, wrong branch, unavailable origin, or non-fast-forward state is skipped and reported without changing the checkout.

2. When it prints `reread-firstmate: yes`, read `AGENTS.md` immediately before any further action.
   A running agent keeps the instructions it started with, so the explicit read is required to pick up changed operating rules.
   When it prints `no`, skip the read.

3. Report the outcome plainly under `AGENTS.md`'s communication rules.
   Name any skipped update and its actionable reason without exposing internal state that is not needed for the next action.

## Safety

- Never force, stash, or discard local work to make an update succeed.
- Never update project clones as part of this command.
- Treat a failed or skipped fast-forward as an unchanged checkout, not as partial success.
