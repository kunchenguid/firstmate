#!/usr/bin/env bash
# shellcheck shell=bash
# Shared Treehouse pool-root helpers.
#
# Treehouse v2.0.0's installed CLI has no --root flag and ignores
# TREEHOUSE_ROOT, but it uses HOME as the default root. Keep the override scoped
# to each Treehouse command so the worker itself retains the launching home's
# normal HOME and credentials.

fm_treehouse_pool_root() { # <home> -> <absolute-root>
  local home=$1 resolved
  resolved=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  printf '%s/state/treehouse\n' "$resolved"
}

fm_treehouse_require_config_free_project() { # <project> -> empty
  local project=$1 config="$1/treehouse.toml"
  if [ -e "$config" ] || [ -L "$config" ]; then
    echo "error: treehouse get refused for '$project': '$config' exists; per-home pools require a project without treehouse.toml" >&2
    return 1
  fi
}

fm_treehouse_root_for_worktree() { # <home> <worktree> -> <absolute-root>
  local home=$1 worktree=$2 root
  case "$worktree" in
    */.treehouse/*)
      root=${worktree%%/.treehouse/*}
      [ -n "$root" ] || root=/
      ;;
    *)
      root=$(fm_treehouse_pool_root "$home") || return 1
      ;;
  esac
  printf '%s\n' "$root"
}

fm_treehouse_get_command() { # <absolute-root> <project> -> shell command
  printf 'cd %q && HOME=%q treehouse get' "$2" "$1"
}

fm_treehouse_return() { # <home> <working-directory> <worktree>
  local home=$1 cd_dir=$2 worktree=$3 root
  root=$(fm_treehouse_root_for_worktree "$home" "$worktree") || return 1
  ( CDPATH='' cd -- "$cd_dir" && HOME="$root" treehouse return --force "$worktree" )
}
