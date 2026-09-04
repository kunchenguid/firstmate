#!/usr/bin/env bash
# Shared Treehouse root selection for task worktree acquisition and return.
#
# The primary home deliberately leaves Treehouse's existing root precedence
# untouched.
# A non-primary Firstmate home gets a root under its own ignored config tree so
# identical project remotes cannot make its workers land in another home's pool.
#
# fm_treehouse_root_for_home <code-root> <active-home>
#   Echoes an empty string for the primary home or the root path for a
#   structurally identified secondmate home.
#
# A local secondmate is identified as a linked git worktree whose common dir is
# the code root's common dir and whose physical top level is the active home.
# A marked standalone Firstmate home is also accepted for remote secondmates.
# Plain directories and unrelated clones retain the primary default behavior.

_FM_TREEHOUSE_LIB_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_FM_TREEHOUSE_LIB_DIR/fm-primary-scope-lib.sh"

fm_treehouse_real_dir() {
  CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P
}

fm_treehouse_root_for_home() {
  local code_root=$1 active_home=$2 code_real home_real home_top home_top_real
  local code_common home_common home_git pool_root

  code_real=$(fm_treehouse_real_dir "$code_root") || return 1
  home_real=$(fm_treehouse_real_dir "$active_home") || return 1
  [ "$code_real" != "$home_real" ] || return 0

  home_top=$(git -C "$home_real" rev-parse --show-toplevel 2>/dev/null) || {
    fm_root_is_secondmate_home "$home_real" && return 1
    return 0
  }
  home_top_real=$(fm_treehouse_real_dir "$home_top") || {
    fm_root_is_secondmate_home "$home_real" && return 1
    return 0
  }
  [ "$home_top_real" = "$home_real" ] || {
    fm_root_is_secondmate_home "$home_real" && return 1
    return 0
  }

  home_common=$(git -C "$home_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  home_common=$(fm_treehouse_real_dir "$home_common") || return 1
  home_git=$(git -C "$home_real" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  home_git=$(fm_treehouse_real_dir "$home_git") || return 1
  code_common=$(git -C "$code_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  code_common=$(fm_treehouse_real_dir "$code_common") || return 1

  if [ "$home_git" != "$home_common" ] && [ "$home_common" = "$code_common" ]; then
    :
  elif ! fm_root_is_secondmate_home "$home_real"; then
    return 1
  fi

  pool_root="$home_real/config"
  printf '%s' "$pool_root"
}
