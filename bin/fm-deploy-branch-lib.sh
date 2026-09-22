#!/usr/bin/env bash
# Shared read of firstmate.deployBranch, the per-clone git config key that
# names a project's real deploy branch when it differs from the forge's
# advertised default (refs/remotes/origin/HEAD). Some repos keep a stale or
# unmaintained forge default while all real work lands on another branch
# (e.g. "prod"); resolving the base from that stale default silently builds
# on months-old history. Set the key once per affected clone with:
#   git -C <clone> config firstmate.deployBranch <branch>
# An unset key is the normal case: every caller falls back to its own
# existing origin/HEAD resolution unchanged. A key naming a branch absent
# from the clone's refs/remotes/origin/ (after the caller's own fetch) is a
# configuration error the caller must fail loudly on, naming the clone and
# the configured value - never fall back to the forge default silently, since
# that silent fallback is the exact defect this key exists to prevent.
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

# fm_deploy_branch_exists_on_origin <dir> <branch>
# True when refs/remotes/origin/<branch> exists in <dir>'s object store, i.e.
# <branch> is present after <dir>'s own most recent fetch of origin.
fm_deploy_branch_exists_on_origin() {
  git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$2"
}
