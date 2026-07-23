#!/usr/bin/env bash
# Shared common-Git-directory lock identity and ownership for checkout mutation.
# Usage: source this file, call fm_checkout_lock_prepare <lock-root>, derive the
# lock with fm_checkout_lock_path <checkout> <lock-root>, then use fm_lock_*.
# Use fm_checkout_lock_run <checkout> <lock-root> <command> [args...] when the
# complete checkout mutation can execute inside one shared lock scope.

FM_CHECKOUT_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_CHECKOUT_LOCK_HELPERS_LOADED=0

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

fm_checkout_lock_run() {
  local checkout=$1 lock_root=$2
  shift 2
  (
    local checkout_lock
    fm_checkout_lock_prepare "$lock_root" || {
      echo "error: cannot prepare shared checkout mutation lock at $lock_root" >&2
      return 1
    }
    checkout_lock=$(fm_checkout_lock_path "$checkout" "$lock_root") || {
      echo "error: cannot resolve shared checkout mutation lock identity for $checkout" >&2
      return 1
    }
    if ! fm_lock_try_acquire "$checkout_lock"; then
      echo "error: checkout mutation already running for $checkout (pid ${FM_LOCK_HELD_PID:-unknown})" >&2
      return 1
    fi
    trap 'fm_lock_release "$checkout_lock"' EXIT
    "$@"
  )
}
