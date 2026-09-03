### Opening a PR

Invoked at the end of every other playbook.

**Worktree.** Work from a git worktree off main; subagents inherit it. Multiple `Task` calls on the same branch each get their own worktree, or `git fetch && git reset --hard origin/<branch>` between them. Dirty branch with unrelated work: patch out, fresh worktree, apply. Snarled worktree: reset from main, redo minimally.

**Commits.** Commit liberally; rebase into small, ordered commits before opening PRs. Each commit is a future PR: landable, ordered to tell the story. Amend when the fix belongs in a just-made commit; new commit when separable.

**PRs.** `unslop` the diff before commit; `/no-comments` the diff before review; apply the **unslop** skill to the PR description and commit bodies. Small PRs, 5 narrow over 1 fat; stack follow-ups, branch off main only for genuinely independent work. For stacked PRs, use whatever stacking convention the repo uses; the principle is small, ordered slices with the stack visible to reviewers. `gh pr view <number>` before referencing PR status. Rebase on `main` before substantial stack work; never force-push without explicit supervisor authority. No `## Summary` / `## Test plan` boilerplate on small PRs; commit bodies don't restate the subject. After opening, run the babysit playbook; push back through the supervisor when feedback drifts from intent.

A subagent that opens a PR runs `interrogate`, `unslop`, and `/no-comments`, returns the URL, and does NOT babysit. Return to the parent.


---
*Adapted for fleet use from pstack (MIT, upstream commit 7314f72): IDE and cloud-vendor references removed; autonomy is bounded by the brief; outward posting and agent-owned landing removed.*
