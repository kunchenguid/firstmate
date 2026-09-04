#!/usr/bin/env bash
# Read-only session-lock answers for the Telegram integration, whose halves run
# outside bash (bin/fm-telegram.py and .pi/extensions/fm-telegram-mirror.ts) and
# must not restate the shared harness-identity rules of their own.
# Shared harness identity and session-lock ownership are decided by
# bin/fm-session-lock-lib.sh; peer authentication below additionally binds a Pi
# owner to the lock file's process generation.
#
# Usage: fm-session-lock-check.sh <state-dir> <peer-pid>
#          exit 0 when <peer-pid> belongs to the live Pi session holding the
#          home's lock, and that lock was recorded by this Pi generation.
#        fm-session-lock-check.sh --claimed <state-dir>
#          exit 0 when a live verified firstmate session holds the home's lock.
#          Absent, non-regular, symlinked, malformed, dead, and
#          reused-by-an-unrelated-process records all fail this claimed query.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  echo "usage: fm-session-lock-check.sh <state-dir> <peer-pid> | --claimed <state-dir>" >&2
  exit 2
}

if [ "${1:-}" = "--claimed" ]; then
  [ "$#" -eq 2 ] || usage
  fm_session_lock_claimed "$2" >/dev/null || exit 1
  exit 0
fi

if [ "$#" -ne 2 ]; then
  usage
fi
case "$2" in
  ''|*[!0-9]*) exit 1 ;;
esac

fm_session_lock_owned_by_pid "$1" "$2" || exit 1

lock_path=$1/.lock
lock_pid=$(cat "$lock_path" 2>/dev/null) || exit 1
lock_comm=$(ps -o comm= -p "$lock_pid" 2>/dev/null) || exit 1
case "$(basename -- "$lock_comm")" in
  pi|pi-signed) ;;
  *) exit 1 ;;
esac

# Linux exposes process starts in clock ticks from boot while lock mtimes have
# one-second portable precision. One second admits the precision boundary only.
LOCK_TIME_TOLERANCE_SECONDS=1
if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  process_start=$(LC_ALL=C ps -o lstart= -p "$lock_pid" 2>/dev/null) || exit 1
  process_start_epoch=$(LC_ALL=C date -j -f "%a %b %d %T %Y" "$process_start" +%s 2>/dev/null) || exit 1
  lock_time=$(stat -f %m "$lock_path" 2>/dev/null) || exit 1
  case "$process_start_epoch:$lock_time" in
    *[!0-9:]*) exit 1 ;;
  esac
  [ "$process_start_epoch" -le "$((lock_time + LOCK_TIME_TOLERANCE_SECONDS))" ] 2>/dev/null || exit 1
  exit 0
fi
PROC_ROOT=${FM_TELEGRAM_PROC_ROOT:-/proc}
proc_stat=$(cat "$PROC_ROOT/$lock_pid/stat" 2>/dev/null) || exit 1
proc_fields=${proc_stat##*) }
read -r -a proc_field_array <<< "$proc_fields"
[ "${#proc_field_array[@]}" -ge 20 ] || exit 1
start_ticks=${proc_field_array[19]}
boot_time=$(awk '$1 == "btime" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit } END { if (!found) exit 1 }' "$PROC_ROOT/stat" 2>/dev/null) || exit 1
clock_ticks=$(getconf CLK_TCK 2>/dev/null) || exit 1
lock_time=$(stat -c %Y -- "$lock_path" 2>/dev/null) || exit 1
case "$start_ticks:$boot_time:$clock_ticks:$lock_time" in
  *[!0-9:]*) exit 1 ;;
esac
[ "$clock_ticks" -gt 0 ] 2>/dev/null || exit 1
awk -v boot="$boot_time" -v ticks="$start_ticks" -v hz="$clock_ticks" \
  -v lock="$lock_time" -v tolerance="$LOCK_TIME_TOLERANCE_SECONDS" \
  'BEGIN { exit !((boot + (ticks / hz)) <= (lock + tolerance)) }'
