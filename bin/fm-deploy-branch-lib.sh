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
# Nothing ever falls back from a set key to the forge default: that silent
# fallback is the exact defect this key exists to prevent.
#
# This resolver does NOT validate the configured branch - it echoes the key's
# value as given, so a value naming a branch that does not resolve surfaces at
# each caller, and only three of the six attribute it to the key:
#   - fm-spawn.sh, fm-fleet-sync.sh and fm-review-diff.sh refuse and name both
#     firstmate.deployBranch and its value, so a typo reads as the
#     configuration error it is rather than as a network failure.
#   - fm-merge-local.sh refuses with "expected default branch '<value>'" and
#     fm-teardown.sh refuses fail-safe ("has work not on any remote and not
#     landed", or "cannot inspect ... for commits not on <value>"). Both quote
#     the value but neither names the key, and teardown's remedy line offers
#     --force, which discards work, for what may be only a typo.
#   - fm-tangle-lib.sh does not refuse at all: an unresolvable value makes a
#     healthy primary checkout read as a worktree tangle, reported against that
#     value as though it were the default branch.
# So verify the branch exists on the clone's origin before setting the key.
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
