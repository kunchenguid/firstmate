# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# fm_primary_tangle_branch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the given root. It is deliberately silent for
# every legitimate state - the primary on its default branch, and detached HEAD,
# which is how every linked worktree and secondmate home legitimately sits on the
# default branch. Detached HEAD on the default is fine; a feature branch in a
# primary checkout is the alarm.
# fm_checkout_lag detects a different unsafe checkout state: the scripts being
# executed come from a HEAD that is strictly behind the local default-branch tip.

# Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
# then fall back to a local main/master. Echoes the name, or returns 1.
fm_default_branch() {
  local dir=$1 ref branch
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

# If the git checkout at <root> is tangled - on a NAMED branch that is not its
# default branch - echo the offending branch name and return 0. For every healthy
# state (not a git work tree, detached HEAD, or already on the default branch)
# echo nothing and return 1. Detached HEAD is how linked worktrees and secondmate
# homes legitimately sit, so they never trip this; only a feature branch checked
# out in a primary checkout does.
fm_primary_tangle_branch() {
  local root=$1 cur default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] && return 1
  printf '%s\n' "$cur"
  return 0
}

# If the checkout at <root> is strictly behind its local default branch, print
# "<checkout-sha> <default-branch> <default-sha>" and return 0. Stay silent and
# return 1 when it is current, ahead, diverged, or cannot be classified.
fm_checkout_lag() {
  local root=$1 default checkout_sha default_sha
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  default=$(fm_default_branch "$root") || return 1
  checkout_sha=$(git -C "$root" rev-parse --verify "HEAD^{commit}" 2>/dev/null) || return 1
  default_sha=$(git -C "$root" rev-parse --verify "refs/heads/$default^{commit}" 2>/dev/null) || return 1
  [ "$checkout_sha" != "$default_sha" ] || return 1
  git -C "$root" merge-base --is-ancestor "$checkout_sha" "$default_sha" 2>/dev/null || return 1
  printf '%s %s %s\n' "$checkout_sha" "$default" "$default_sha"
}
