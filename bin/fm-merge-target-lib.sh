# shellcheck shell=bash
# Shared landing-branch resolver for the local merge and teardown guards.
# Usage: . bin/fm-merge-target-lib.sh
#
# bin/fm-merge-local.sh and bin/fm-teardown.sh both need the same answer to
# "which local branch counts as landed?": normally origin/HEAD (falling back to
# a local main/master), or an explicit FM_MERGE_TARGET_BRANCH when a home or
# project tracks a long-lived fork branch that is not the remote's default.
# One owner keeps the override and the origin/HEAD default from drifting apart.

# Resolve the landing branch name for the git repo at <dir>.
# Prefers FM_MERGE_TARGET_BRANCH when set (must already exist as a local branch),
# then refs/remotes/origin/HEAD, then a local main/master.
# Echoes the branch name, or returns 1 when none can be resolved.
fm_merge_target_branch() {
  local dir=$1 ref branch
  if [ -n "${FM_MERGE_TARGET_BRANCH:-}" ]; then
    git -C "$dir" show-ref --verify --quiet "refs/heads/$FM_MERGE_TARGET_BRANCH" || return 1
    printf '%s\n' "$FM_MERGE_TARGET_BRANCH"
    return 0
  fi
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}
