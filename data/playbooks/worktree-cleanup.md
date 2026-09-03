### Worktree and simulator cleanup

**You own the disk and the safety gate.** Prune merged or abandoned git worktrees and stale iOS simulators to reclaim space. Deletion is irreversible, so every step guards against deleting something in use or holding uncommitted work.

1. Snapshot and audit. Record `df -h /`, then audit with `git worktree list` (principle-build-the-lever). Read paths from its output, never hand-typed, since a hand-typed path misses worktrees that live elsewhere (principle-encode-lessons-in-structure). Classify each worktree by size, age, merge state, uncommitted work, PR state, and the newest session that touched it, then suggest a bucket.
2. The bucket is advice, not permission. The pinned and active sessions are the real artifact (principle-prove-it-works). Get that set from the supervisor and cross-check every candidate. The audit has marked `safe` a worktree the supervisor had pinned before, so the pinned set wins.
3. Verify usage before deleting. For every recently-active row, or anything you doubt, fan separate passes out to read the transcripts and report whether the session is pinned or ongoing and which worktrees it touches (principle-guard-the-context-window, transcripts are bulk). A pinned session may have spawned arena and repro trees into sibling worktrees via background workers, and those are in use even when their names never appear in the session list.
4. Pause on irreversible loss. `wip:N` is N tracked uncommitted edits. Show the diff and get a supervisor decision first, since removing a clean worktree is recoverable from its branch but uncommitted work is gone. `scratch:N` is untracked throwaway, safe to drop, but name the files. Clean, merged, and not-in-use proceeds; `wip` and in-use pause.
5. Prune the confirmed set. Per path, `git worktree remove --force <path>`; if the dir survives on ignored build artifacts, `rm -rf` it, then `git worktree prune`. Branch refs survive, so no commits are lost. Confirm with `df -h /` and re-list.
6. Simulators and other reclaimers. Simulators and SDK caches are usually the next-biggest win; clear only caches the supervisor has not said to keep, and treat every deletion as destructive until the supervisor confirms the exact target.

This is the one playbook that deletes local state with no code review to catch a slip, so the gates above are the review.

**Reply:** `df -h /` before and after with space reclaimed, the worktrees pruned, and a one-line reason for each held back (in-use by which session, or uncommitted work).


---
*Adapted for fleet use from pstack (MIT, upstream commit 7314f72): IDE and cloud-vendor references removed; autonomy is bounded by the brief; outward posting and agent-owned landing removed.*
