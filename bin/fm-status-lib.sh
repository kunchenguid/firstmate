# shellcheck shell=bash

_FM_STATUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_STATUS_LIB_DIR="."
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_STATUS_LIB_DIR/fm-wake-lib.sh"

fm_status_lock_acquire() {  # <status-file>
  fm_lock_acquire_wait "$1.append.lock"
}

fm_status_lock_release() {  # <status-file>
  fm_lock_release "$1.append.lock"
}

fm_status_append_locked() {  # <status-file> <line>
  printf '%s\n' "$2" >> "$1"
}

fm_status_append() {  # <status-file> <line>
  local status=$1 line=$2 rc=0
  fm_status_lock_acquire "$status" || return 1
  fm_status_append_locked "$status" "$line" || rc=$?
  fm_status_lock_release "$status"
  return "$rc"
}
