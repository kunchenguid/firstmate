#!/usr/bin/env bash
# Shared task-workspace scope and Treehouse lifecycle helpers.
#
# Task Treehouse pools are scoped by the canonical owning Firstmate home, not by
# Treehouse's user-global default.  The default base is
# ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/task-workspaces; tests and
# specialized installations may set FM_WORKSPACE_ROOT_BASE to another absolute
# directory.  The home path is represented only by its git object hash, so two
# homes using the same project cannot collide and moving a home deliberately
# starts a new scope instead of adopting an unrelated pool.
#
# Retention is zero idle task worktrees.  A completed task or a PR task whose
# exact head is recoverable from the forge is returned and then destroyed by
# bin/fm-workspace.sh or bin/fm-teardown.sh.  A failed exact destroy remains a
# visible retryable refusal; callers never broaden it to --include-unlanded.

fm_workspace_canonical_home() {  # [home]
  local home=${1:-${FM_HOME:-}}
  [ -n "$home" ] && [ -d "$home" ] || return 1
  (CDPATH='' cd -- "$home" 2>/dev/null && pwd -P)
}

fm_workspace_root_for_home() {  # [home]
  local home base hash
  home=$(fm_workspace_canonical_home "${1:-${FM_HOME:-}}") || return 1
  base=${FM_WORKSPACE_ROOT_BASE:-${XDG_STATE_HOME:-${HOME:?HOME is required}/.local/state}/firstmate/task-workspaces}
  case "$base" in
    /*) ;;
    *)
      echo "error: FM_WORKSPACE_ROOT_BASE must be an absolute path: $base" >&2
      return 1
      ;;
  esac
  case "$base" in *[$'\n\r\t']*) return 1 ;; esac
  hash=$(printf '%s' "$home" | git hash-object --stdin 2>/dev/null) || return 1
  printf '%s/home-%s\n' "${base%/}" "$hash"
}

fm_workspace_prepare_root() {  # <root>
  local root=$1
  case "$root" in /*) ;; *) return 1 ;; esac
  (umask 077; mkdir -p -- "$root") || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
}

fm_workspace_root_from_worktree() {  # <worktree>
  local wt slot pool root
  wt=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 1
  slot=$(dirname "$wt")
  pool=$(dirname "$slot")
  [ -f "$pool/treehouse-state.json" ] && [ ! -L "$pool/treehouse-state.json" ] || return 1
  root=$(dirname "$pool")
  # Treehouse stores pools below <configured-root>/.treehouse/. The compact
  # test fixture and older installations may place pools directly below the
  # configured root, so normalize only the explicit hidden-directory shape.
  [ "${root##*/}" != .treehouse ] || root=$(dirname "$root")
  [ -d "$root" ] || return 1
  printf '%s\n' "$root"
}

fm_workspace_meta_root() {  # <meta> <worktree>
  local meta=$1 wt=$2 root
  root=$(awk -F= '$1 == "workspace_root" { value=substr($0,index($0,"=")+1) } END { print value }' "$meta" 2>/dev/null)
  if [ -n "$root" ]; then
    case "$root" in /*) printf '%s\n' "$root"; return 0 ;; esac
    return 1
  fi
  fm_workspace_root_from_worktree "$wt"
}

fm_workspace_lease_holder() {  # <task-id> [home]
  local id=$1 home hash
  home=$(fm_workspace_canonical_home "${2:-${FM_HOME:-}}") || return 1
  hash=$(printf '%s' "$home" | git hash-object --stdin 2>/dev/null) || return 1
  printf 'firstmate:%s:%s\n' "${hash:0:12}" "$id"
}

fm_workspace_treehouse_return() {  # <root> <project> <worktree> [lease-holder]
  local root=$1 project=$2 wt=$3 holder=${4:-}
  local -a args
  args=(--root "$root" return --force)
  [ -z "$holder" ] || args+=(--if-lease-holder "$holder")
  args+=("$wt")
  (CDPATH='' cd -- "$project" && treehouse "${args[@]}")
}

fm_workspace_treehouse_destroy_idle() {  # <root> <worktree>
  local root=$1 wt=$2
  [ -e "$wt" ] || return 0
  treehouse --root "$root" destroy "$wt" --yes
}
