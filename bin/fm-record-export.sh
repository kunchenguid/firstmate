#!/usr/bin/env bash
# fm-record-export.sh - export a fixed, versioned set of private fleet records.
#
# Usage:
#   fm-record-export.sh sync
#   fm-record-export.sh archive-task <task-id>
#
# config/record-export-root contains exactly one absolute directory path.
# Without that local config file, both commands exit before loading the Python
# filesystem engine or lock library. A configured export requires Python 3.
# The Python engine owns the dedicated root, descriptor-safe traversal, exact
# live snapshots, durable archive transactions, strict manifests, and retention.
# Direct archive calls hold the task metadata lock through source enumeration and
# commit. Teardown already owns that lock and sets FM_RECORD_EXPORT_META_LOCK_HELD.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-$FM_ROOT}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG_FILE="$CONFIG/record-export-root"
ARCHIVE_META_LOCK=

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

record_export_configured() {
  if [ ! -e "$CONFIG" ] && [ ! -L "$CONFIG" ]; then
    return 1
  fi
  [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] \
    || die "record export config directory is unsafe: $CONFIG"
  [ -r "$CONFIG" ] && [ -x "$CONFIG" ] \
    || die "record export config directory is inaccessible: $CONFIG"
  if [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
    return 1
  fi
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] \
    || die "record export config is not a readable regular file: $CONFIG_FILE"
}

require_python() {
  command -v python3 >/dev/null 2>&1 || die "configured record export requires python3"
}

archive_lock_release() {
  [ -z "$ARCHIVE_META_LOCK" ] || fm_lock_release "$ARCHIVE_META_LOCK" || true
}

run_archive() {  # <task-id>
  local task=$1 rc=0
  record_export_configured || return 0
  require_python
  if [ "${FM_RECORD_EXPORT_META_LOCK_HELD:-0}" = 1 ]; then
    python3 "$SCRIPT_DIR/fm-record-export.py" archive-task "$task"
    return $?
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  ARCHIVE_META_LOCK=$(fm_meta_lock_path "$STATE/$task.meta") \
    || die "invalid task id for record export archive: $task"
  fm_lock_acquire_wait "$ARCHIVE_META_LOCK" \
    || die "cannot acquire task lock for record export archive: $task"
  trap 'archive_lock_release' EXIT HUP INT TERM
  python3 "$SCRIPT_DIR/fm-record-export.py" archive-task "$task" || rc=$?
  archive_lock_release
  ARCHIVE_META_LOCK=
  trap - EXIT HUP INT TERM
  return "$rc"
}

[ "$#" -ge 1 ] || usage
command=$1
shift
case "$command:$#" in
  sync:0)
    record_export_configured || exit 0
    require_python
    exec python3 "$SCRIPT_DIR/fm-record-export.py" sync
    ;;
  archive-task:1) run_archive "$1" ;;
  *) usage ;;
esac
