#!/usr/bin/env bash
# Shared "is this branch provably safe to delete?" decision procedure.
#
# ONE owner for the merged-branch proof that fm-fleet-sync.sh's periodic
# fm/<task-id> sweep relies on (fm-teardown.sh's own inline branch-drop stays
# on its existing, stronger, GitHub-aware landedness proof - see that
# script's header - and is not re-derived here). A branch is provably safe to
# delete iff ALL of the following hold:
#   1. it exists as a local branch in the repo;
#   2. it is not currently checked out in ANY worktree of that repo, linked or
#      main - deleting a checked-out branch would fail anyway, but checking
#      first keeps this a pure decision procedure with no destructive side
#      effect on the caller's own probing;
#   3. its tip is an ancestor of the given "merged into" ref (a clean
#      fast-forward, or any non-squash merge, already contains it - git's own
#      `branch -d` can verify this itself).
# Upstream "[gone]" is deliberately excluded: deletion of a remote ref does
# not prove that its work landed. The separately-owned prune_gone_branches
# flow covers squash-merged PR cleanup, while fm-teardown.sh uses its existing
# GitHub-aware landedness check for inline cleanup.
# ANY uncertainty - the branch does not exist, a worktree still has it out, or
# neither proof holds - returns non-zero (NOT safe): fail safe, never force a
# delete this cannot prove. The caller decides what "not safe" means (leave it
# alone and move on, never an error worth failing over).

# fm_branch_worktree_branches <repo>: newline list of branch shortnames
# currently checked out in any worktree of <repo> (the main checkout included).
fm_branch_worktree_branches() {
  local repo=$1
  git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's#^branch refs/heads/##p'
}

# fm_branch_is_safely_merged <repo> <branch> <merged_into_ref>: the proof
# itself (see header). Never inspects or changes anything but refs. Refuses a
# <branch> that IS the "merged into" ref itself as a defensive guard against a
# caller accidentally naming the protected/default branch - every branch is
# trivially its own ancestor, so without this guard that self-comparison would
# otherwise look "safely merged".
fm_branch_is_safely_merged() {
  local repo=$1 branch=$2 merged_into=$3
  [ -n "$branch" ] || return 1
  [ "refs/heads/$branch" != "$merged_into" ] || return 1
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || return 1
  fm_branch_worktree_branches "$repo" | grep -Fxq -- "$branch" && return 1
  if [ -n "$merged_into" ] \
    && git -C "$repo" merge-base --is-ancestor "$branch" "$merged_into" 2>/dev/null; then
    return 0
  fi
  return 1
}

# fm_branch_delete_if_safely_merged <repo> <branch> <merged_into_ref>: delete
# <branch> in <repo> only when fm_branch_is_safely_merged proves it, printing
# nothing itself (callers report their own outcome). Uses plain safe `-d`,
# which independently double-checks the ancestor proof. Returns non-zero,
# unchanged, for anything the proof does not cover.
fm_branch_delete_if_safely_merged() {
  local repo=$1 branch=$2 merged_into=$3
  fm_branch_is_safely_merged "$repo" "$branch" "$merged_into" || return 1
  git -C "$repo" branch -d -- "$branch" >/dev/null 2>&1
}
