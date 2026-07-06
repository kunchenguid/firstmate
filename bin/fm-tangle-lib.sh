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

# Canonical absolute git common dir of the repo at <dir>, or return 1 if <dir>
# is not a git work tree. The common dir is shared by a repo and all its linked
# worktrees, so two checkouts of one repo resolve to the same value.
fm__common_dir_abs() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) : ;;
    *) common="$dir/$common" ;;
  esac
  (cd "$common" 2>/dev/null && pwd -P) || return 1
}

# True (return 0) if the git checkout at <dir> belongs to the SAME repository as
# the firstmate repo <root> (default FM_ROOT) - i.e. <dir> is the firstmate repo
# itself or one of its linked worktrees, sharing one object store. Used to
# recognize firstmate-on-itself ship tasks (fm-downstream.sh, fm-project-mode.sh,
# fm-spawn.sh, the PR seams) so a downstream instance defaults its own changes to
# local-only. Returns 1 if <dir> is not a git work tree or the repos differ.
fm_is_firstmate_repo() {
  local dir=$1 root=${2:-${FM_ROOT:-}} a b
  [ -n "$dir" ] || return 1
  [ -n "$root" ] || return 1
  a=$(fm__common_dir_abs "$dir") || return 1
  b=$(fm__common_dir_abs "$root") || return 1
  [ "$a" = "$b" ]
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
