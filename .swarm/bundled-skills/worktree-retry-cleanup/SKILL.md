---
name: worktree-retry-cleanup
audience: swarm-plugin
description: Protocol for cleaning parallel-coder worktree lanes before retry. Triggered before re-dispatching any task that already has a lane (completed, denied, cancelled, or failed).
---

# Worktree Retry Cleanup

## Trigger
Before re-dispatching a coder for a task that already has a lane (any prior dispatch status).

## Protocol
1. **Prefer built-in provisioning cleanup.** Re-dispatch normally through the standard coder/worktree path. Provisioning pre-cleans stale same-lane worktrees/branches when ownership is safe and the existing lane is clean.
2. **If provisioning blocks:** Treat the error as signal. Dirty lanes, lanes active in another worktree, and lanes owned by another active session must be surfaced to the user instead of deleted.
3. **If manual cleanup is explicitly required:** Do the ownership check FIRST. Confirm the lane is not owned by another ACTIVE session: read `.swarm/session/state.json` and verify no other session's `delegationChains` reference `<session>/<task>`. If another active session owns it, STOP.
4. **Remove only the specific lane.** Target `.swarm-worktrees/<session>/<task>`, never the session parent. Prefer `git worktree remove .swarm-worktrees/<session>/<task>` and then `git worktree prune`.
5. **Delete only confirmed stale branches.** `git branch -d swarm/lane/<session>/<task>` is allowed after confirming the branch is not checked out and contains no needed commits. Use force deletion only with explicit human approval.
6. **Verify:** `git branch --list "swarm/lane/<session>/<task>"` returns empty before retrying.

## Root cause
Stale same-lane worktrees and branches used to require manual cleanup before retry. Provisioning now handles the safe clean/stale cases automatically and fails closed for dirty, active, or cross-session-owned lanes.
