# shellcheck shell=bash
# Shared host-wide ownership for dependency mutations and Firstmate checkout updates.
# Usage: . bin/fm-dependency-lock-lib.sh

FM_DEPENDENCY_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FM_DEPENDENCY_LOCK_HELD=${_FM_DEPENDENCY_LOCK_HELD:-0}
FM_DEPENDENCY_LOCK_OUTCOME=
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_DEPENDENCY_LOCK_LIB_DIR/fm-timeout-lib.sh"

fm_dependency_positive_integer_is_valid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *[1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_dependency_lock_timeout_is_valid() {
  fm_dependency_positive_integer_is_valid "${FM_DEPS_LOCK_TIMEOUT:-5}"
}

fm_dependency_identity_timeout_is_valid() {
  fm_dependency_positive_integer_is_valid "${FM_DEPS_IDENTITY_TIMEOUT:-3}"
}

fm_dependency_run_identity_probe() {
  local raw=${FM_DEPS_IDENTITY_TIMEOUT:-3}
  fm_dependency_identity_timeout_is_valid || return 124
  fm_run_timed "$((10#$raw))" "$@"
}

fm_dependency_host_lock_basename() {
  printf 'firstmate-deps-%s\n' "$UID"
}

fm_dependency_runtime_dir_is_valid() {
  local dir=$1
  case "$dir" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$dir" in *$'\n'*|*$'\r'*) return 1 ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  [ "$(fm_dependency_path_mode "$dir")" = 700 ]
}

fm_dependency_private_parent_is_valid() {
  local dir=$1 mode numeric
  case "$dir" in /*) ;; *) return 1 ;; esac
  case "$dir" in *$'\n'*|*$'\r'*) return 1 ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  mode=$(fm_dependency_path_mode "$dir") || return 1
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  numeric=$((8#$mode))
  [ $((numeric & 0022)) -eq 0 ]
}

fm_dependency_prepare_private_runtime_dir() {
  local parent=$1 name=$2 dir
  fm_dependency_private_parent_is_valid "$parent" || return 1
  dir="$parent/$name"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    fm_dependency_runtime_dir_is_valid "$dir" || return 1
  elif ! (umask 077; mkdir "$dir") 2>/dev/null; then
    fm_dependency_runtime_dir_is_valid "$dir" || return 1
  fi
  fm_dependency_runtime_dir_is_valid "$dir" || return 1
  printf '%s\n' "$dir"
}

fm_dependency_passwd_home() {
  local uid=$1
  [ -r /etc/passwd ] || return 1
  awk -F: -v uid="$uid" '$3 == uid { print $6; exit }' /etc/passwd 2>/dev/null
}

fm_dependency_account_home() {
  local uid=$UID username entry candidate
  case "$uid" in ''|*[!0-9]*) return 1 ;; esac

  candidate=$(fm_dependency_passwd_home "$uid" 2>/dev/null || true)
  if [ -n "$candidate" ] && fm_dependency_private_parent_is_valid "$candidate"; then
    printf '%s\n' "$candidate"
    return
  fi
  if command -v getent >/dev/null 2>&1; then
    entry=$(fm_dependency_run_identity_probe getent passwd "$uid" 2>/dev/null || true)
    candidate=$(printf '%s\n' "$entry" | awk -F: -v uid="$uid" '$3 == uid { print $6; exit }')
    if [ -n "$candidate" ] && fm_dependency_private_parent_is_valid "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  fi
  if command -v dscl >/dev/null 2>&1; then
    username=$(fm_dependency_run_identity_probe id -un 2>/dev/null || true)
    case "$username" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    entry=$(fm_dependency_run_identity_probe dscl . -read "/Users/$username" \
      NFSHomeDirectory 2>/dev/null || true)
    candidate=$(printf '%s\n' "$entry" | awk '$1 == "NFSHomeDirectory:" { print $2; exit }')
    if [ -n "$candidate" ] && fm_dependency_private_parent_is_valid "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  fi
  return 1
}

fm_dependency_machine_identity() {
  local path identity output
  for path in /etc/machine-id /var/lib/dbus/machine-id; do
    [ -r "$path" ] || continue
    IFS= read -r identity < "$path" || continue
    case "$identity" in ''|*[!A-Fa-f0-9]*) continue ;; esac
    [ "${#identity}" -eq 32 ] || continue
    printf '%s\n' "$identity"
    return
  done
  command -v ioreg >/dev/null 2>&1 || return 1
  output=$(fm_dependency_run_identity_probe ioreg -rd1 -c IOPlatformExpertDevice \
    2>/dev/null) || return 1
  identity=$(printf '%s\n' "$output" \
    | awk -F'"' '/"IOPlatformUUID"/ { print $(NF - 1); exit }')
  case "$identity" in ''|*[!A-Fa-f0-9-]*) return 1 ;; esac
  [ "${#identity}" -eq 36 ] || return 1
  printf '%s\n' "$identity"
}

fm_dependency_host_key() {
  fm_dependency_machine_identity
}

fm_dependency_runtime_dir() {
  local account_home firstmate runtime hosts host
  account_home=$(fm_dependency_account_home) || return 1
  host=$(fm_dependency_host_key) || return 1
  firstmate=$(fm_dependency_prepare_private_runtime_dir "$account_home" .firstmate) || return 1
  runtime=$(fm_dependency_prepare_private_runtime_dir "$firstmate" runtime) || return 1
  hosts=$(fm_dependency_prepare_private_runtime_dir "$runtime" hosts) || return 1
  fm_dependency_prepare_private_runtime_dir "$hosts" "$host"
}

fm_dependency_host_lock_dir() {
  local runtime
  if [ -n "${FM_DEPS_HOST_LOCK_DIR:-}" ]; then
    printf '%s\n' "$FM_DEPS_HOST_LOCK_DIR"
  else
    runtime=$(fm_dependency_runtime_dir) || return 1
    printf '%s/%s\n' "$runtime" "$(fm_dependency_host_lock_basename)"
  fi
}

fm_dependency_host_lock_dir_is_valid() {
  local lock_dir=$1 expected
  expected=$(fm_dependency_host_lock_basename) || return 1
  case "$lock_dir" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$lock_dir" in *$'\n'*|*$'\r'*) return 1 ;; esac
  [ "${lock_dir##*/}" = "$expected" ] || return 1
  [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] && [ -O "$lock_dir" ] || return 1
  [ "$(fm_dependency_path_mode "$lock_dir")" = 700 ]
}

fm_dependency_path_mode() {
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) stat -f '%Lp' "$1" 2>/dev/null ;;
    *) stat -c '%a' "$1" 2>/dev/null ;;
  esac
}

fm_dependency_ensure_host_lock_dir() {
  local lock_dir parent
  lock_dir=$(fm_dependency_host_lock_dir) || return 1
  if [ -e "$lock_dir" ] || [ -L "$lock_dir" ]; then
    fm_dependency_host_lock_dir_is_valid "$lock_dir"
    return
  fi
  case "$lock_dir" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$lock_dir" in *$'\n'*|*$'\r'*) return 1 ;; esac
  [ "${lock_dir##*/}" = "$(fm_dependency_host_lock_basename)" ] || return 1
  parent=${lock_dir%/*}
  [ "$parent" != "$lock_dir" ] || parent=.
  [ -d "$parent" ] || return 1
  if ! (umask 077; mkdir "$lock_dir") 2>/dev/null; then
    fm_dependency_host_lock_dir_is_valid "$lock_dir" || return 1
  fi
  fm_dependency_host_lock_dir_is_valid "$lock_dir"
}

fm_dependency_acquire_lock() {
  local lock=$1 raw timeout started
  raw=${FM_DEPS_LOCK_TIMEOUT:-5}
  fm_dependency_lock_timeout_is_valid || return 2
  timeout=$((10#$raw))
  started=$SECONDS
  while ! fm_lock_try_acquire "$lock"; do
    [ $((SECONDS - started)) -lt "$timeout" ] || return 75
    sleep 0.1
  done
}

fm_dependency_lock_is_owned_by_pid() {
  local lock=$1 expected_pid=$2 owner pid
  [ -L "$lock" ] || return 1
  owner=$(fm_lock_link_owner "$lock" 2>/dev/null) || return 1
  case "$owner" in "$lock".owner.*) ;; *) return 1 ;; esac
  [ -d "$owner" ] && [ ! -L "$owner" ] || return 1
  fm_lock_points_to_owner "$lock" "$owner" || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  [ "$pid" = "$expected_pid" ]
}

fm_dependency_parent_owns_host_lock() {
  local expected=${FM_DEPENDENCY_LOCK_PARENT_PID:-} lock_dir lock
  local context_root=${FM_ROOT:-$FM_DEPENDENCY_LOCK_LIB_DIR/..}
  local context_home=${FM_HOME:-$context_root}
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  [ "$expected" = "$PPID" ] || return 1
  fm_dependency_ensure_host_lock_dir || return 1
  lock_dir=$(fm_dependency_host_lock_dir) || return 1
  lock="$lock_dir/fm-deps.lock"
  local FM_ROOT_OVERRIDE FM_ROOT FM_HOME FM_STATE_OVERRIDE STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_ROOT_OVERRIDE=$context_root
  FM_ROOT=$context_root
  FM_HOME=$context_home
  FM_STATE_OVERRIDE=
  STATE=$lock_dir
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_DEPENDENCY_LOCK_LIB_DIR/fm-wake-lib.sh"
  fm_dependency_lock_is_owned_by_pid "$lock" "$expected"
}

fm_dependency_with_host_lock() {
  local callback=$1 lock_dir lock lock_status
  local context_root=${FM_ROOT:-$FM_DEPENDENCY_LOCK_LIB_DIR/..}
  local context_home=${FM_HOME:-$context_root} rc=0
  local context_root_override=${FM_ROOT_OVERRIDE:-}
  local context_state_override=${FM_STATE_OVERRIDE:-}
  local context_state=${STATE:-$context_home/state}
  local context_wake_queue=${FM_WAKE_QUEUE:-}
  local context_wake_queue_lock=${FM_WAKE_QUEUE_LOCK:-}
  shift
  FM_DEPENDENCY_LOCK_OUTCOME=
  if [ "$_FM_DEPENDENCY_LOCK_HELD" -eq 1 ]; then
    if "$callback" "$@"; then
      FM_DEPENDENCY_LOCK_OUTCOME=completed
      return 0
    else
      rc=$?
      FM_DEPENDENCY_LOCK_OUTCOME=callback-failed
      return "$rc"
    fi
  fi
  if fm_dependency_parent_owns_host_lock; then
    local _FM_DEPENDENCY_LOCK_HELD=1
    if "$callback" "$@"; then
      FM_DEPENDENCY_LOCK_OUTCOME=completed
      return 0
    else
      rc=$?
      FM_DEPENDENCY_LOCK_OUTCOME=callback-failed
      return "$rc"
    fi
  fi
  fm_dependency_ensure_host_lock_dir || {
    FM_DEPENDENCY_LOCK_OUTCOME=unavailable
    return 2
  }
  lock_dir=$(fm_dependency_host_lock_dir) || {
    FM_DEPENDENCY_LOCK_OUTCOME=unavailable
    return 2
  }
  lock="$lock_dir/fm-deps.lock"
  local FM_ROOT_OVERRIDE FM_ROOT FM_HOME FM_STATE_OVERRIDE STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_ROOT_OVERRIDE=$context_root
  FM_ROOT=$context_root
  FM_HOME=$context_home
  FM_STATE_OVERRIDE=
  STATE=$lock_dir
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_DEPENDENCY_LOCK_LIB_DIR/fm-wake-lib.sh"
  fm_dependency_acquire_lock "$lock"
  lock_status=$?
  if [ "$lock_status" -ne 0 ]; then
    if [ "$lock_status" -eq 75 ]; then
      FM_DEPENDENCY_LOCK_OUTCOME=busy
    else
      FM_DEPENDENCY_LOCK_OUTCOME=unavailable
    fi
    return "$lock_status"
  fi
  FM_ROOT_OVERRIDE=$context_root_override
  FM_ROOT=$context_root
  FM_HOME=$context_home
  FM_STATE_OVERRIDE=$context_state_override
  STATE=$context_state
  FM_WAKE_QUEUE=$context_wake_queue
  FM_WAKE_QUEUE_LOCK=$context_wake_queue_lock
  local _FM_DEPENDENCY_LOCK_HELD=1
  "$callback" "$@" || rc=$?
  fm_lock_release "$lock"
  if [ "$rc" -eq 0 ]; then
    FM_DEPENDENCY_LOCK_OUTCOME=completed
  else
    FM_DEPENDENCY_LOCK_OUTCOME=callback-failed
  fi
  return "$rc"
}

fm_dependency_resume_host_lock() {
  local callback=$1 lock_dir lock
  local context_root=${FM_ROOT:-$FM_DEPENDENCY_LOCK_LIB_DIR/..}
  local context_home=${FM_HOME:-$context_root} rc=0
  local context_root_override=${FM_ROOT_OVERRIDE:-}
  local context_state_override=${FM_STATE_OVERRIDE:-}
  local context_state=${STATE:-$context_home/state}
  local context_wake_queue=${FM_WAKE_QUEUE:-}
  local context_wake_queue_lock=${FM_WAKE_QUEUE_LOCK:-}
  shift
  FM_DEPENDENCY_LOCK_OUTCOME=
  fm_dependency_ensure_host_lock_dir || {
    FM_DEPENDENCY_LOCK_OUTCOME=unavailable
    return 2
  }
  lock_dir=$(fm_dependency_host_lock_dir) || {
    FM_DEPENDENCY_LOCK_OUTCOME=unavailable
    return 2
  }
  lock="$lock_dir/fm-deps.lock"
  local FM_ROOT_OVERRIDE FM_ROOT FM_HOME FM_STATE_OVERRIDE STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_ROOT_OVERRIDE=$context_root
  FM_ROOT=$context_root
  FM_HOME=$context_home
  FM_STATE_OVERRIDE=
  STATE=$lock_dir
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_DEPENDENCY_LOCK_LIB_DIR/fm-wake-lib.sh"
  fm_dependency_lock_is_owned_by_pid "$lock" "${BASHPID:-$$}" || {
    FM_DEPENDENCY_LOCK_OUTCOME=unavailable
    return 2
  }
  FM_ROOT_OVERRIDE=$context_root_override
  FM_ROOT=$context_root
  FM_HOME=$context_home
  FM_STATE_OVERRIDE=$context_state_override
  STATE=$context_state
  FM_WAKE_QUEUE=$context_wake_queue
  FM_WAKE_QUEUE_LOCK=$context_wake_queue_lock
  local _FM_DEPENDENCY_LOCK_HELD=1
  "$callback" "$@" || rc=$?
  fm_lock_release "$lock"
  if [ "$rc" -eq 0 ]; then
    FM_DEPENDENCY_LOCK_OUTCOME=completed
  else
    FM_DEPENDENCY_LOCK_OUTCOME=callback-failed
  fi
  return "$rc"
}
