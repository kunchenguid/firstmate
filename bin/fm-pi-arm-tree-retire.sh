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

msys_pid=$(read_single_pid "$wrapper_pid_file") || exit 3
mapped_native_pid=$(read_single_pid "$proc_root/$msys_pid/winpid") || exit 3
[ "$mapped_native_pid" = "$native_pid" ] || exit 3
tree_matches() {
  local current_native_pid
  current_native_pid=$(read_single_pid "$proc_root/$msys_pid/winpid") || return 1
  [ "$current_native_pid" = "$native_pid" ] \
    && [ -r "$proc_root/$msys_pid/environ" ] \
    && tr '\0' '\n' < "$proc_root/$msys_pid/environ" 2>/dev/null \
      | grep -F -x -- "FM_PI_ARM_TREE_TOKEN=$token" >/dev/null 2>&1
}

tree_matches || exit 3
watcher_recorded=0
watcher_pid=
watcher_identity=
if [ -e "$state/.watch.lock" ]; then
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$watcher_pid" "$home" || exit 4
  watcher_identity=$FM_WATCHER_MATCHED_IDENTITY
  watcher_recorded=1
fi
watcher_matches() {
  local current
  [ "$watcher_recorded" -eq 1 ] || return 1
  current=$(fm_pid_identity "$watcher_pid") || return 1
  [ "$current" = "$watcher_identity" ]
}

taskkill_status=0
MSYS2_ARG_CONV_EXCL='*' taskkill.exe /PID "$native_pid" /T /F >/dev/null 2>&1 || taskkill_status=$?
i=0
while [ "$i" -lt 20 ]; do
  if ! tree_matches && ! watcher_matches; then
    [ "$taskkill_status" -eq 0 ] && exit 0
    exit 1
  fi
  sleep 0.05
  i=$((i + 1))
done
exit 1
