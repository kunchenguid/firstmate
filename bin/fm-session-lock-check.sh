#!/usr/bin/env bash
# Verify that a process belongs to the live Pi session holding a home's session lock.
# Usage: fm-session-lock-check.sh <state-dir> <peer-pid>
set -u

if [ "$#" -ne 2 ]; then
  echo "usage: fm-session-lock-check.sh <state-dir> <peer-pid>" >&2
  exit 2
fi
case "$2" in
  ''|*[!0-9]*) exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
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
