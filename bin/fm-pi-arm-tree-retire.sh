#!/usr/bin/env bash
set -u

native_pid=${1:-}
token=${2:-}
state=${3:-}
watch_path=${4:-}
home=${5:-}
case "$native_pid" in ''|*[!0-9]*|0|1) exit 2 ;; esac
case "$token" in ''|*[!0-9a-f]*) exit 2 ;; esac
[ -n "$state" ] && [ -n "$watch_path" ] && [ -n "$home" ] || exit 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=$home
FM_STATE_OVERRIDE=$state
export FM_HOME FM_STATE_OVERRIDE
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
wrapper_pid_file="$state/.pi-arm-wrapper-$token.pid"
retirement_dir="$state/.pi-arm-retirement-$token"
FM_PI_ARM_WRAPPER_PID_FILE=$wrapper_pid_file
export FM_PI_ARM_WRAPPER_PID_FILE

read_single_pid() {
  awk '
    NR == 1 && /^[0-9]+$/ && $0 != "0" && $0 != "1" { pid = $0; next }
    { invalid = 1 }
    END {
      if (!invalid && pid != "") print pid
      else exit 1
    }
  ' "$1" 2>/dev/null
}

cleanup_snapshot() {
  rm -f \
    "$1/wrapper-msys-pid" \
    "$1/wrapper-native-pid" \
    "$1/watcher-recorded" \
    "$1/watcher-msys-pid" \
    "$1/watcher-native-pid" \
    "$1/watcher-native-pid.tmp" \
    "$1/watcher-identity" \
    "$1/watcher-recorded.tmp" 2>/dev/null || true
  rmdir "$1" 2>/dev/null || true
}

read_watcher_lock_snapshot() {
  local lock_home lock_path current_identity
  watcher_pid=$(read_single_pid "$state/.watch.lock/pid") || return 1
  lock_home=$(cat "$state/.watch.lock/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$state/.watch.lock/watcher-path" 2>/dev/null || true)
  watcher_identity=$(cat "$state/.watch.lock/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$watcher_identity" ] || return 1
  watcher_native_pid=
  current_identity=$(fm_pid_identity "$watcher_pid" 2>/dev/null || true)
  if [ "$current_identity" = "$watcher_identity" ]; then
    watcher_native_pid=$(read_single_pid "$proc_root/$watcher_pid/winpid") || return 1
  fi
  watcher_recorded=1
}

record_snapshot() {
  local i=0 tmp mapped_native_pid
  while [ "$i" -lt 20 ]; do
    msys_pid=$(read_single_pid "$wrapper_pid_file" 2>/dev/null || true)
    [ -n "$msys_pid" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ -n "${msys_pid:-}" ] || return 1
  mapped_native_pid=$(read_single_pid "$proc_root/$msys_pid/winpid") || return 1
  [ "$mapped_native_pid" = "$native_pid" ] || return 1
  tree_matches || return 1

  watcher_recorded=0
  watcher_pid=
  watcher_native_pid=
  watcher_identity=
  if [ -e "$state/.watch.lock" ]; then
    read_watcher_lock_snapshot || return 1
  fi

  tmp="$retirement_dir.${BASHPID:-$$}"
  mkdir "$tmp" 2>/dev/null || return 1
  if ! printf '%s\n' "$msys_pid" > "$tmp/wrapper-msys-pid" \
    || ! printf '%s\n' "$native_pid" > "$tmp/wrapper-native-pid" \
    || ! printf '%s\n' "$watcher_recorded" > "$tmp/watcher-recorded" \
    || ! printf '%s\n' "$watcher_pid" > "$tmp/watcher-msys-pid" \
    || ! printf '%s\n' "$watcher_native_pid" > "$tmp/watcher-native-pid" \
    || ! printf '%s\n' "$watcher_identity" > "$tmp/watcher-identity" \
    || ! mv "$tmp" "$retirement_dir"; then
    cleanup_snapshot "$tmp"
    return 1
  fi
}

tree_matches() {
  local current_native_pid
  current_native_pid=$(read_single_pid "$proc_root/$msys_pid/winpid") || return 1
  [ "$current_native_pid" = "$native_pid" ] \
    && [ -r "$proc_root/$msys_pid/environ" ] \
    && tr '\0' '\n' < "$proc_root/$msys_pid/environ" 2>/dev/null \
      | grep -F -x -- "FM_PI_ARM_TREE_TOKEN=$token" >/dev/null 2>&1
}

if [ ! -e "$retirement_dir" ]; then
  record_snapshot || exit 3
fi

msys_pid=$(read_single_pid "$retirement_dir/wrapper-msys-pid") || exit 3
recorded_native_pid=$(read_single_pid "$retirement_dir/wrapper-native-pid") || exit 3
[ "$recorded_native_pid" = "$native_pid" ] || exit 3
watcher_recorded=$(cat "$retirement_dir/watcher-recorded" 2>/dev/null || true)
case "$watcher_recorded" in 0|1) ;; *) exit 3 ;; esac
watcher_pid=
watcher_native_pid=
watcher_identity=
if [ "$watcher_recorded" -eq 1 ]; then
  watcher_pid=$(read_single_pid "$retirement_dir/watcher-msys-pid") || exit 3
  watcher_native_pid=$(cat "$retirement_dir/watcher-native-pid" 2>/dev/null || true)
  case "$watcher_native_pid" in
    '') ;;
    *[!0-9]*|0|1) exit 3 ;;
  esac
  watcher_identity=$(cat "$retirement_dir/watcher-identity" 2>/dev/null || true)
  [ -n "$watcher_identity" ] || exit 3
fi
watcher_matches() {
  local current
  [ "$watcher_recorded" -eq 1 ] || return 1
  current=$(fm_pid_identity "$watcher_pid") || return 1
  [ "$current" = "$watcher_identity" ]
}

record_late_watcher() {
  [ "$watcher_recorded" -eq 0 ] || return 0
  [ -e "$state/.watch.lock" ] || return 0
  read_watcher_lock_snapshot || return 1
  if ! printf '%s\n' "$watcher_pid" > "$retirement_dir/watcher-msys-pid" \
    || ! printf '%s\n' "$watcher_native_pid" > "$retirement_dir/watcher-native-pid" \
    || ! printf '%s\n' "$watcher_identity" > "$retirement_dir/watcher-identity" \
    || ! printf '1\n' > "$retirement_dir/watcher-recorded.tmp" \
    || ! mv -f "$retirement_dir/watcher-recorded.tmp" "$retirement_dir/watcher-recorded"; then
    return 1
  fi
  watcher_recorded=1
}

bind_watcher_native_pid() {
  local current_native_pid
  current_native_pid=$(read_single_pid "$proc_root/$watcher_pid/winpid") || return 1
  if [ -n "$watcher_native_pid" ]; then
    [ "$current_native_pid" = "$watcher_native_pid" ]
    return
  fi
  if ! printf '%s\n' "$current_native_pid" > "$retirement_dir/watcher-native-pid.tmp" \
    || ! mv -f "$retirement_dir/watcher-native-pid.tmp" "$retirement_dir/watcher-native-pid"; then
    return 1
  fi
  watcher_native_pid=$current_native_pid
}

taskkill_status=0
if tree_matches; then
  MSYS2_ARG_CONV_EXCL='*' taskkill.exe /PID "$native_pid" /T /F >/dev/null 2>&1 || taskkill_status=$?
fi
i=0
while [ "$i" -lt 5 ] && tree_matches; do
  sleep 0.05
  i=$((i + 1))
done
i=0
while [ "$watcher_recorded" -eq 0 ] && [ "$i" -lt 5 ]; do
  record_late_watcher || exit 1
  [ "$watcher_recorded" -eq 1 ] && break
  sleep 0.05
  i=$((i + 1))
done
if watcher_matches; then
  bind_watcher_native_pid || exit 1
  MSYS2_ARG_CONV_EXCL='*' taskkill.exe /PID "$watcher_native_pid" /T /F >/dev/null 2>&1 || taskkill_status=$?
fi
i=0
while [ "$i" -lt 20 ]; do
  if ! tree_matches && ! watcher_matches; then
    if [ "$taskkill_status" -eq 0 ]; then
      cleanup_snapshot "$retirement_dir"
      rm -f "$wrapper_pid_file" 2>/dev/null || true
      exit 0
    fi
    exit 1
  fi
  sleep 0.05
  i=$((i + 1))
done
exit 1
