---
name: resolving-merge-conflicts
metadata:
  internal: true
description: "Use when you need to resolve an in-progress git merge/rebase conflict."
---

1. **See the current state** of the merge/rebase.
   Check git history, and the conflicting files.

2. **Find the primary sources** for each conflict.
   Understand deeply why each change was made, and what the original intent was.
   Read the commit messages, check the PRs, check original issues/tickets.

3. **Resolve each hunk.**
   Preserve both intents where possible.
   Where incompatible, report the decision or blocker unless the accepted task already determines the choice.
   Do **not** invent new behaviour.
   Never abort, reset, stash, or discard unlanded work without explicit authority.

4. Discover the project's **automated checks** and run them - typically typecheck, then tests, then format.
   Fix anything the merge broke.

5. **Finish the merge/rebase.**
   Stage only the resolved, in-scope files.
   Continue or commit only when the task's delivery contract authorizes it.
