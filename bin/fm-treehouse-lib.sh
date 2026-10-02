#!/usr/bin/env bash
# shellcheck shell=bash
# Shared Treehouse pool-root helpers.
#
# Treehouse v2.0.0's installed CLI has no --root flag and ignores
# TREEHOUSE_ROOT and TREEHOUSE_DIR, but it uses HOME as the default root. Keep
# the override scoped to each Treehouse command so the worker itself retains the
# launching home's normal HOME and credentials.
#
# The per-home root lives OUTSIDE the firstmate home, under the launching user's
# real HOME, keyed by the home's resolved path: a root inside the home would put
# every pooled worker checkout under the home's CLAUDE.md/AGENTS.md, and a
# harness that walks up from the checkout would import firstmate's own job
# description into a project worker.
#
# Because the Treehouse command runs with HOME pointed at the root, everything
# git and its credential helpers read from HOME must be reachable there too:
# fm_treehouse_prepare_root links the real ~/Library (macOS keychain for
# credential.helper=osxkeychain), ~/.gitconfig, ~/.git-credentials, ~/.netrc,
# ~/.ssh and ~/.config into the root, so a fresh pool can clone with the
# launching user's credentials.

fm_treehouse_pool_root() { # <home> -> <absolute-root>
  local home=$1 resolved key base
  resolved=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    key=$(printf '%s' "$resolved" | shasum | cut -c1-12) || return 1
  elif command -v sha1sum >/dev/null 2>&1; then
    key=$(printf '%s' "$resolved" | sha1sum | cut -c1-12) || return 1
  else
    echo "error: shasum or sha1sum is required to resolve the Treehouse pool root" >&2
    return 1
  fi
  [ "${#key}" -eq 12 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
  base=${FM_TREEHOUSE_POOL_BASE:-$HOME/.firstmate-treehouse}
  case "$base" in
    /*) ;;
    *)
      echo "error: Treehouse pool base must be absolute: $base" >&2
      return 1
      ;;
  esac
  printf '%s/%s\n' "${base%/}" "$key"
}

fm_treehouse_prepare_root() { # <home> <absolute-root> -> empty
  local home=$1 root=$2 entry
  mkdir -p -- "$root" || return 1
  printf '%s\n' "$home" > "$root/firstmate-home" || return 1
  for entry in Library .gitconfig .git-credentials .netrc .ssh .config; do
    [ -e "$HOME/$entry" ] || continue
    [ -e "$root/$entry" ] || [ -L "$root/$entry" ] || ln -s -- "$HOME/$entry" "$root/$entry" || return 1
  done
}

fm_treehouse_require_config_free_project() { # <project> -> empty
  local project=$1 config="$1/treehouse.toml"
  if [ -e "$config" ] || [ -L "$config" ]; then
    echo "error: treehouse get refused for '$project': '$config' exists; per-home pools require a project without treehouse.toml" >&2
    return 1
  fi
}

fm_treehouse_root_for_worktree() { # <home> <worktree> -> <absolute-root>
  local home=$1 worktree=${2%/} treehouse_dir root
  treehouse_dir=${worktree%/*}
  treehouse_dir=${treehouse_dir%/*}
  treehouse_dir=${treehouse_dir%/*}
  case "$treehouse_dir" in
    */.treehouse)
      root=${treehouse_dir%/.treehouse}
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
