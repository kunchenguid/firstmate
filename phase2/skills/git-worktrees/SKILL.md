# git-worktrees
## Purpose
Isolated branch/worktree per worker (Treehouse or fm-phase2-worktree.sh).
## Mandatory documents
FILE-OWNERSHIP.md, state meta worktree=
## Rules
Never modify main directly; never force-push; never auto-delete dirty worktrees
## Prohibited
Working in primary project checkout
## Expected output
worktree path + branch name recorded on task
## Tests
tests/phase2/06-worktree.sh
## Stop conditions
Dirty unexpected tree; duplicate assignment
