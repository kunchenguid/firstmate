#!/usr/bin/env bash
# fm-worktree-identity-lib.sh - canonical Git clone/worktree identity helpers.
#
# A linked worktree belongs to the selected project clone only when both resolve
# to the same physical git common directory.
# Remote URLs and repository names are not clone identity because two homes may
# intentionally clone the same remote into independent object stores.

fm_git_common_dir_canonical() {  # <path>
  local path=$1 common
  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -d "$common" ] || return 1
  (cd "$common" 2>/dev/null && pwd -P)
}

fm_git_worktree_root_canonical() {  # <path>
  local path=$1 top
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -d "$top" ] || return 1
  (cd "$top" 2>/dev/null && pwd -P)
}

fm_git_path_matches_worktree_identity() {  # <path> <expected-worktree-root> <expected-common-dir>
  local path=$1 expected_root=$2 expected_common=$3 actual_root actual_common
  actual_root=$(fm_git_worktree_root_canonical "$path") || return 1
  actual_common=$(fm_git_common_dir_canonical "$path") || return 1
  [ "$actual_root" = "$expected_root" ] && [ "$actual_common" = "$expected_common" ]
}
