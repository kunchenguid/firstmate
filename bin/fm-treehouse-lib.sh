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

fm_treehouse_common_dir() { # <directory> -> <absolute-git-common-dir>
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  ( CDPATH='' cd -- "$dir" && CDPATH='' cd -- "$common" && pwd -P )
}

fm_treehouse_proxy_path() { # <absolute-root> <project> -> <path>
  local root=$1 project=$2 key
  key=$(printf '%s' "$project" | git -C "$project" hash-object --stdin) || return 1
  printf '%s/proxy/%s\n' "$root" "$key"
}

fm_treehouse_prepare_proxy() { # <absolute-root> <project> -> <path>
  local root=$1 project=$2 proxy project_real proxy_real project_common proxy_common git_dir
  proxy=$(fm_treehouse_proxy_path "$root" "$project") || return 1
  project_real=$(CDPATH='' cd -- "$project" 2>/dev/null && pwd -P) || return 1
  mkdir -p "$(dirname "$proxy")" || return 1
  if [ ! -e "$proxy" ] && [ ! -L "$proxy" ]; then
    mkdir "$proxy" || return 1
    git_dir=$(git -C "$project_real" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    printf 'gitdir: %s\n' "$git_dir" > "$proxy/.git" || return 1
  fi
  [ -d "$proxy" ] && [ ! -L "$proxy" ] || return 1
  [ -f "$proxy/.git" ] && [ ! -L "$proxy/.git" ] || return 1
  [ ! -e "$proxy/treehouse.toml" ] && [ ! -L "$proxy/treehouse.toml" ] || return 1
  proxy_real=$(CDPATH='' cd -- "$proxy" 2>/dev/null && pwd -P) || return 1
  [ "$(git -C "$proxy_real" rev-parse --show-toplevel 2>/dev/null || true)" = "$proxy_real" ] || return 1
  project_common=$(fm_treehouse_common_dir "$project_real") || return 1
  proxy_common=$(fm_treehouse_common_dir "$proxy_real") || return 1
  [ "$project_common" = "$proxy_common" ] || return 1
  printf '%s\n' "$proxy_real"
}

fm_treehouse_get_command() { # <absolute-root> <project-proxy> -> shell command
  printf 'cd %q && HOME=%q treehouse get' "$2" "$1"
}

fm_treehouse_return() { # <absolute-root> <working-directory> <worktree>
  local root=$1 cd_dir=$2 worktree=$3
  ( CDPATH='' cd -- "$cd_dir" && HOME="$root" treehouse return --force "$worktree" )
}
