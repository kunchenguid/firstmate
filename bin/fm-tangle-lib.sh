# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate improving itself hands out `git worktree`s: a crewmate/scout task
# worktree is a proj-provisioned worktree of firstmate's own proj project
# (bin/fm-proj-lib.sh), a secondmate home is either that same proj-provisioned
# shape or a plain git clone, while the PRIMARY checkout (the repo root
# firstmate operates from) is a normal checkout on a real branch - normally the
# default branch, main. The "worktree tangle" failure mode is a crewmate
# spawned to work on firstmate ITSELF branching and committing in the primary
# checkout instead of its own disposable worktree, stranding the primary on a
# feature branch (e.g. fm/readme-restructure-d3).
#
# fm_primary_tangle_branch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the given root. It only ever inspects the
# one path already known to be the primary (FM_ROOT - see the callers), so it
# is unaffected by what a task worktree's own HEAD looks like (proj worktrees
# always check out a named branch, never detached). It is deliberately silent
# for every legitimate state the primary itself can be in - on its default
# branch, or detached HEAD; a feature branch in a primary checkout is the alarm.

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
