# shellcheck shell=bash
# Shared committed-content proof for teardown and pooled-slot claim retirement.
# Callers separately prove a clean worktree and resolve its default branch.
# Fetch before the three-way merge proof; a conflict or failed read refuses.
# A matching merged tree proves HEAD adds nothing to the default branch, even
# after squash landing or unrelated advancement of that branch.
# CONTENT_LANDED_PROOF_ERROR names an option or execution failure, separately
# from a conflict or differing tree, for teardown to report to the operator.
fm_worktree_content_in_default() {  # <worktree> <default-branch>
  local worktree=$1 name=$2 ref default_tree merged_tree merge_status
  CONTENT_LANDED_PROOF_ERROR=
  if git -C "$worktree" remote get-url origin >/dev/null 2>&1; then
    git -C "$worktree" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$worktree" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$worktree" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$worktree" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || {
    merge_status=$?
    case "$merge_status" in
      1) ;; # Git completed the merge and found conflicts.
      129) CONTENT_LANDED_PROOF_ERROR='git merge-tree --write-tree was rejected (Git 2.38 or newer required)' ;;
      *) CONTENT_LANDED_PROOF_ERROR="git merge-tree --write-tree failed (Git exit $merge_status)" ;;
    esac
    return 1
  }
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}
