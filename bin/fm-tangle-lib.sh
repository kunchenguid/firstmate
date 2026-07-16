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

# Prevention-side isolation check for the same tangle, used by fm-spawn's
# worktree-discovery poll. Accept <candidate> as a genuine ISOLATED worktree
# root only when its physical path (a) sits AT a git worktree top - not merely
# inside some repo or in a bare non-repo directory - and (b) differs from every
# <forbidden> physical path passed after it (the project's primary checkout,
# the firstmate home/root). treehouse get's subshell hops through intermediate
# cwds (the user's home, the firstmate home) before settling in the final
# worktree, and a mis-sample can itself be another VALID repo root, so the
# not-the-project check alone is insufficient. Echoes the candidate's physical
# path and returns 0 on acceptance; echoes nothing and returns 1 otherwise.
fm_isolated_worktree_root() {
  local cand=$1 cand_real top top_real f
  shift
  cand_real=$(cd "$cand" 2>/dev/null && pwd -P) || return 1
  top=$(git -C "$cand_real" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  [ "$cand_real" = "$top_real" ] || return 1
  for f in "$@"; do
    if [ -n "$f" ] && [ "$cand_real" = "$f" ]; then
      return 1
    fi
  done
  printf '%s\n' "$cand_real"
  return 0
}
