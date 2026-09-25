#!/usr/bin/env bash
# fm-worktree-hooks-lib.sh - owns pointing one task worktree's git hooks at
# firstmate's hook directory (bin/git-hooks) and taking that pointer away again.
#
# bin/fm-spawn.sh installs it for every ship and scout worktree on every
# harness, so the commit-msg hook (bin/fm-worktree-git-hook.sh) refuses AI
# self-attribution whichever agent writes the commit. The pointer is the
# worktree's own core.hooksPath in its config.worktree, so the primary checkout
# and every sibling worktree keep their hooks; that file is only read once
# extensions.worktreeConfig is on, which is the one shared-config change made,
# and it is left in place at teardown because other worktrees may rely on it.
# bin/fm-teardown.sh clears the pointer with the rest of the per-task wiring.

fm_worktree_git_hooks_dir() {  # <fm-root>
  printf '%s\n' "$1/bin/git-hooks"
}

fm_worktree_git_hooks_install() {  # <worktree> <fm-root>
  local wt=$1 dir
  dir=$(fm_worktree_git_hooks_dir "$2")
  [ -x "$dir/commit-msg" ] || return 1
  if [ "$(git -C "$wt" config --local --bool extensions.worktreeConfig 2>/dev/null)" != true ]; then
    git -C "$wt" config --local extensions.worktreeConfig true || return 1
  fi
  git -C "$wt" config --worktree core.hooksPath "$dir" || return 1
  [ "$(git -C "$wt" config --get core.hooksPath 2>/dev/null)" = "$dir" ]
}

# Edits the worktree's own config.worktree file directly, so a worktree that
# never had the pointer can never have the shared config's core.hooksPath
# removed in its place.
fm_worktree_git_hooks_clear() {  # <worktree>
  local wt=$1 cfg
  cfg=$(git -C "$wt" rev-parse --git-path config.worktree 2>/dev/null) || return 0
  [ -n "$cfg" ] || return 0
  (cd "$wt" 2>/dev/null && [ -f "$cfg" ] && git config --file "$cfg" --unset-all core.hooksPath) >/dev/null 2>&1 || true
}
