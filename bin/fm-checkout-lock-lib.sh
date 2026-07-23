#!/usr/bin/env bash
# Shared common-Git-directory lock identity and ownership for checkout mutation.
# Usage: source this file, call fm_checkout_lock_prepare <lock-root>, derive the
# lock with fm_checkout_lock_path <checkout> <lock-root>, then use fm_lock_*.
# Use fm_checkout_lock_run <checkout> <lock-root> <command> [args...] when the
# complete checkout mutation can execute inside one shared lock scope, including
# same-process nested calls for the same common Git directory.
# Use fm_checkout_treehouse_return <checkout> <lock-root> <project> for a
# process-tree-bounded `treehouse return --force` under that lock.

FM_CHECKOUT_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_CHECKOUT_LOCK_HELPERS_LOADED=0
FM_CHECKOUT_TREEHOUSE_RETURN_CONFIG_STATUS=64
FM_CHECKOUT_LOCK_FAILURE_STATUS=74
FM_CHECKOUT_LOCK_CONTENTION_STATUS=75
FM_CHECKOUT_TREEHOUSE_RETURN_TIMEOUT_STATUS=124
FM_CHECKOUT_TREEHOUSE_RETURN_UNAVAILABLE_STATUS=127
# shellcheck source=bin/fm-process-tree-lib.sh
. "$FM_CHECKOUT_LOCK_LIB_DIR/fm-process-tree-lib.sh"

fm_checkout_lock_root() {
  local state_base=$1
  if [ -n "${FM_CHECKOUT_REFRESH_LOCK_ROOT:-}" ]; then
    printf '%s\n' "$FM_CHECKOUT_REFRESH_LOCK_ROOT"
  elif [ -n "${FM_CHECKOUT_REFRESH_STATE_ROOT:-}" ]; then
    printf '%s/locks\n' "$FM_CHECKOUT_REFRESH_STATE_ROOT"
  else
    printf '%s/locks\n' "$state_base"
  fi
}

fm_checkout_canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

fm_checkout_git_common_dir() {
  local checkout=$1 common
  common=$(git -C "$checkout" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) fm_checkout_canonical_dir "$common" ;;
    *) fm_checkout_canonical_dir "$checkout/$common" ;;
  esac
}

fm_checkout_lock_key() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,24)}'
}

fm_checkout_lock_path() {
  local checkout=$1 lock_root=$2 common
  common=$(fm_checkout_git_common_dir "$checkout") || return 1
  printf '%s/%s.lock\n' "$lock_root" "$(fm_checkout_lock_key "$common")"
}

fm_checkout_lock_prepare() {
  local lock_root=$1 caller_root caller_home
  mkdir -p "$lock_root" || return 1
  [ -d "$lock_root" ] && [ ! -L "$lock_root" ] || return 1
  if [ "$FM_CHECKOUT_LOCK_HELPERS_LOADED" -eq 0 ]; then
    caller_root=${FM_ROOT:-$(cd "$FM_CHECKOUT_LOCK_LIB_DIR/.." && pwd)}
    caller_home=${FM_HOME:-$caller_root}
    # shellcheck disable=SC2034
    local FM_ROOT="$caller_root" FM_HOME="$caller_home"
    # shellcheck disable=SC2034
    local FM_STATE_OVERRIDE="$lock_root" STATE='' FM_WAKE_LIB_DIR='' FM_WAKE_DEFAULT_ROOT=''
    # shellcheck disable=SC2034
    local FM_WAKE_QUEUE='' FM_WAKE_QUEUE_LOCK=''
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_CHECKOUT_LOCK_LIB_DIR/fm-wake-lib.sh" || return 1
    FM_CHECKOUT_LOCK_HELPERS_LOADED=1
  fi
}

fm_checkout_lock_active_scope_owns() {
  local checkout_lock=$1 ownerdir owner_pid
  [ "${FM_CHECKOUT_LOCK_ACTIVE_PATH:-}" = "$checkout_lock" ] || return 1
  [ -n "${FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR:-}" ] || return 1
  [ -n "${FM_CHECKOUT_LOCK_ACTIVE_OWNER_PID:-}" ] || return 1
  [ -L "$checkout_lock" ] || return 1
  ownerdir=$(fm_lock_link_owner "$checkout_lock" 2>/dev/null) || return 1
  [ "$ownerdir" = "$FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR" ] || return 1
  owner_pid=$(cat "$ownerdir/pid" 2>/dev/null) || return 1
  [ "$owner_pid" = "$FM_CHECKOUT_LOCK_ACTIVE_OWNER_PID" ] || return 1
  fm_pid_alive "$owner_pid" || return 1
  fm_lock_points_to_owner "$checkout_lock" "$ownerdir"
}

fm_checkout_lock_run() {
  local checkout=$1 lock_root=$2 checkout_lock
  shift 2
  fm_checkout_lock_prepare "$lock_root" || {
    echo "error: cannot prepare shared checkout mutation lock at $lock_root" >&2
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  }
  checkout_lock=$(fm_checkout_lock_path "$checkout" "$lock_root") || {
    echo "error: cannot resolve shared checkout mutation lock identity for $checkout" >&2
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  }
  if fm_checkout_lock_active_scope_owns "$checkout_lock"; then
    "$@"
    return
  fi
  (
    if ! fm_lock_try_acquire "$checkout_lock"; then
      echo "error: checkout mutation already running for $checkout (pid ${FM_LOCK_HELD_PID:-unknown})" >&2
      return "$FM_CHECKOUT_LOCK_CONTENTION_STATUS"
    fi
    local FM_CHECKOUT_LOCK_ACTIVE_PATH="$checkout_lock"
    local FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR="${FM_LOCK_OWNER_DIR:-}"
    local FM_CHECKOUT_LOCK_ACTIVE_OWNER_PID="${BASHPID:-$$}"
    local FM_PROCESS_TREE_GUARD_FILE="$FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR/process-group"
    export FM_PROCESS_TREE_GUARD_FILE
    trap 'fm_lock_release "$checkout_lock"' EXIT
    "$@"
  )
}

fm_checkout_treehouse_return_locked() {
  local checkout=$1 lock_root=$2 project=$3 checkout_lock timeout status
  checkout_lock=$(fm_checkout_lock_path "$checkout" "$lock_root") || {
    echo "error: cannot resolve shared checkout mutation lock identity for $checkout" >&2
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  }
  if ! fm_checkout_lock_active_scope_owns "$checkout_lock"; then
    echo "error: refusing unlocked Treehouse return for $checkout" >&2
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  fi
  timeout=${FM_TREEHOUSE_RETURN_TIMEOUT:-60}
  case "$timeout" in
    ''|*[!0-9]*|0)
      echo "error: FM_TREEHOUSE_RETURN_TIMEOUT must be a positive integer" >&2
      return "$FM_CHECKOUT_TREEHOUSE_RETURN_CONFIG_STATUS"
      ;;
  esac
  if ( cd "$project" && fm_run_bounded "$timeout" treehouse return --force "$checkout" ); then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq "$FM_CHECKOUT_TREEHOUSE_RETURN_TIMEOUT_STATUS" ]; then
    echo "error: Treehouse return timed out after ${timeout}s for $checkout" >&2
  elif [ "$status" -eq "$FM_PROCESS_TREE_CLEANUP_FAILURE_STATUS" ]; then
    echo "error: Treehouse return process cleanup could not be verified for $checkout; retained for inspection" >&2
  fi
  return "$status"
}

fm_checkout_treehouse_return() {
  local checkout=$1 lock_root=$2 project=$3
  fm_checkout_lock_run "$checkout" "$lock_root" \
    fm_checkout_treehouse_return_locked "$checkout" "$lock_root" "$project"
}

fm_checkout_treehouse_return_requires_retention() {
  [ "$1" -eq "$FM_CHECKOUT_TREEHOUSE_RETURN_CONFIG_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_LOCK_FAILURE_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_LOCK_CONTENTION_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_TREEHOUSE_RETURN_TIMEOUT_STATUS" ] \
    || [ "$1" -eq "$FM_PROCESS_TREE_CLEANUP_FAILURE_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_TREEHOUSE_RETURN_UNAVAILABLE_STATUS" ]
}
