#!/usr/bin/env bash
# The one implementation of "which branch is this clone's base?", shared by
# every firstmate path that needs it (spawn's pooled-worktree base, fleet
# sync's comparison base, review diff's base, local merge's target, teardown's
# work-safety check, and the worktree-tangle guard).
#
# Resolution order:
#   1. firstmate.deployBranch, a per-clone git config key naming the project's
#      real deploy branch.
#   2. refs/remotes/origin/HEAD, the forge's advertised default.
#   3. a local main or master.
#
# The key exists because a repo may keep a stale or unmaintained forge default
# while all real work lands on another branch (e.g. "prod"); resolving the base
# from that stale default silently builds on months-old history. Set it once
# per affected clone with:
#   git -C <clone> config firstmate.deployBranch <branch>
# An unset key is the normal case and leaves resolution exactly as it was.
# When the key names a branch that does not resolve, callers refuse on their
# own existing unresolvable-base paths and name the key as the source, so a
# typo reads as a configuration error rather than a network failure. Nothing
# ever falls back from a set key to the forge default: that silent fallback is
# the exact defect this key exists to prevent.
# Usage: . bin/fm-deploy-branch-lib.sh

# fm_deploy_branch_configured <dir>
# Echoes the configured branch name and returns 0 when firstmate.deployBranch
# is set for <dir>; returns 1 with no output when it is unset.
fm_deploy_branch_configured() {
  local dir=$1 branch
  branch=$(git -C "$dir" config --get firstmate.deployBranch 2>/dev/null || true)
  [ -n "$branch" ] || return 1
  printf '%s\n' "$branch"
}

# fm_default_branch <dir>
# Echoes <dir>'s base branch name per the resolution order above, or returns 1
# when none of the three sources yields one.
fm_default_branch() {
  local dir=$1 ref branch
  if branch=$(fm_deploy_branch_configured "$dir"); then
    printf '%s\n' "$branch"
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
