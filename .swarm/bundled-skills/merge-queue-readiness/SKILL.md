---
name: merge-queue-readiness
audience: swarm-plugin
description: Pre-queue merge-group CI simulation. Triggered before adding a PR to a GitHub merge queue. Prevents merge-queue kick-outs from integration test failures.
---

# Merge Queue Readiness

## Trigger
Before adding the PR to the merge queue (or before the final push if the repo uses a merge queue).

## Protocol
1. **Fetch latest main:** `git fetch origin main`
2. **Run the simulation command (preferred):**
   ```
   /swarm ci-simulate [<pr-ref>]
   ```
   The optional positional `<pr-ref>` is the PR branch/ref to simulate (defaults to the current branch). It does NOT accept `--base`/`--head` flags. The command runs fixed local gates: `bun run typecheck`, `bun run lint`, `bun run build`, then a full-batch `bun test`. It creates a temporary detached worktree under `os.tmpdir()/swarm-ci-simulate` (a SIBLING of the project root, not project-relative), merges the PR ref, runs the gate sequence, removes the worktree, and prunes metadata. It does not accept arbitrary shell commands and does NOT replicate CI's quarantine/retry semantics — it is a fast pre-merge signal, not a CI parity check.
3. **Manual fallback:** If the command is unavailable, create a temporary simulation worktree (do NOT mutate the PR branch). The default worktree base is a SIBLING of the project root (`<parent>/.swarm-worktrees/`), overridable via the `worktree_dir` config; on Windows, very long paths may be shortened to `os.tmpdir()/swwt/...`. Place the worktree under that base. Do NOT hardcode `/tmp` — it does not exist on Windows.
   ```
   git worktree add ../.swarm-worktrees/merge-sim origin/main
   cd ../.swarm-worktrees/merge-sim
   git merge <pr-branch> --no-edit
   ```
4. **Run integration + unit tests against the merged result:**
   ```
   bun test tests/integration --timeout 120000
   bun test tests/unit --timeout 120000
   ```
   (Use per-file loops for hot modules per AGENTS.md invariant 6)
5. **If failures:** Fix on the PR branch, re-push, re-simulate. Always run the cleanup step (6) before re-simulating or on any exit path — do not leave the simulation worktree behind.
6. **Cleanup for manual fallback (run on EVERY exit path, including failure):** Prefer non-force `git worktree remove ../.swarm-worktrees/merge-sim`. If the removal is blocked or fails, surface the block to the user (the worktree guard fails closed for safety) and run `git worktree prune`.
7. **Only after simulation passes,** add PR to the merge queue.

## Why this matters
PR-branch CI and merge-group CI test DIFFERENT things:
- PR-branch: tests the PR head commit in isolation
- Merge-group: tests a temporary merge of PR head + latest main

Integration tests that pass on the PR branch may fail in merge-group context due to test interactions exposed by the merged result.

## Automation
`/swarm ci-simulate` automates the merge-result worktree, merge, command run,
worktree removal, and metadata prune. Use the manual protocol only when the
command is unavailable or the repo needs bespoke setup.
