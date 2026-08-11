#!/usr/bin/env bash
# Shared detection for treehouse's transient `treehouse return --force` git
# index.lock race: a crew process killed mid-git-operation can leave a
# .git/worktrees/<wt>/index.lock (or, for a non-linked worktree, .git/index.lock)
# that makes the return fail with Unable to create '...index.lock': File exists,
# even though the lock is usually gone within seconds. ONE owner for recognizing
# that exact signature and resolving its lock path, so every durable-lease
# release path (bin/fm-teardown.sh's teardown_treehouse_return, bin/fm-spawn.sh's
# early-abort release) retries the same failure instead of drifting between
# separate reimplementations.

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      [ -d "$dir" ] || return 1
      abs_dir=$(cd "$dir" && pwd -P) || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}
