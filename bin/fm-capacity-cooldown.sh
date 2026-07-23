#!/usr/bin/env bash
# Manage passive capacity cooldown records under state/capacity-cooldowns/.
# Usage:
#   fm-capacity-cooldown.sh mark --harness <h> --profile <p> [--account <a>] (--reset-epoch <n>|--ttl-secs <n>) [--class quota] [--reason <r>] [--source-task <id>]
#   fm-capacity-cooldown.sh mark-from-text --harness <h> --profile <p> [--account <a>] [--source-task <id>] [--file <path>]
#   fm-capacity-cooldown.sh active --harness <h> --profile <p> [--account <a>]
#
# The helper never fabricates TTLs.
# mark-from-text writes only when the classified text carries an observed reset
# epoch; otherwise it exits non-zero after printing the classification.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"

usage() {
  sed -n '2,10p' "$0" >&2
}

need_value() {
  [ "$#" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift || true

HARNESS=
PROFILE=
ACCOUNT=
RESET_EPOCH=
TTL_SECS=
CLASS=quota
REASON=manual
SOURCE_TASK=
FILE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness) need_value "$@"; HARNESS=$2; shift 2 ;;
    --harness=*) HARNESS=${1#--harness=}; shift ;;
    --profile) need_value "$@"; PROFILE=$2; shift 2 ;;
    --profile=*) PROFILE=${1#--profile=}; shift ;;
    --account) need_value "$@"; ACCOUNT=$2; shift 2 ;;
    --account=*) ACCOUNT=${1#--account=}; shift ;;
    --reset-epoch) need_value "$@"; RESET_EPOCH=$2; shift 2 ;;
    --reset-epoch=*) RESET_EPOCH=${1#--reset-epoch=}; shift ;;
    --ttl-secs) need_value "$@"; TTL_SECS=$2; shift 2 ;;
    --ttl-secs=*) TTL_SECS=${1#--ttl-secs=}; shift ;;
    --class) need_value "$@"; CLASS=$2; shift 2 ;;
    --class=*) CLASS=${1#--class=}; shift ;;
    --reason) need_value "$@"; REASON=$2; shift 2 ;;
    --reason=*) REASON=${1#--reason=}; shift ;;
    --source-task) need_value "$@"; SOURCE_TASK=$2; shift 2 ;;
    --source-task=*) SOURCE_TASK=${1#--source-task=}; shift ;;
    --file) need_value "$@"; FILE=$2; shift 2 ;;
    --file=*) FILE=${1#--file=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

case "$cmd" in
  mark|mark-from-text|active) ;;
  *) echo "error: unknown command '$cmd'" >&2; usage; exit 2 ;;
esac

[ -n "$HARNESS" ] || { echo "error: --harness is required" >&2; exit 2; }
[ -n "$PROFILE" ] || { echo "error: --profile is required" >&2; exit 2; }

case "$cmd" in
  active)
    fm_capacity_cooldown_active "$STATE" "$HARNESS" "$ACCOUNT" "$PROFILE"
    ;;
  mark)
    if [ -n "$TTL_SECS" ]; then
      case "$TTL_SECS" in ''|*[!0-9]*) echo "error: --ttl-secs must be numeric" >&2; exit 2 ;; esac
      RESET_EPOCH=$(( $(fm_capacity_now_epoch) + TTL_SECS ))
    fi
    [ -n "$RESET_EPOCH" ] || { echo "error: mark requires --reset-epoch or --ttl-secs" >&2; exit 2; }
    fm_capacity_mark_cooldown "$STATE" "$HARNESS" "$ACCOUNT" "$PROFILE" "$RESET_EPOCH" "$CLASS" "$REASON" "$SOURCE_TASK"
    ;;
  mark-from-text)
    if [ -n "$FILE" ]; then
      TEXT=$(cat "$FILE")
    else
      TEXT=$(cat)
    fi
    CLASSIFIED=$(fm_capacity_classify_text "$TEXT")
    printf '%s\n' "$CLASSIFIED"
    RESET_EPOCH=$(printf '%s\n' "$CLASSIFIED" | sed -n 's/^reset_epoch=//p' | tail -1)
    CLASS=$(printf '%s\n' "$CLASSIFIED" | sed -n 's/^class=//p' | tail -1)
    REASON=$(printf '%s\n' "$CLASSIFIED" | sed -n 's/^reason=//p' | tail -1)
    [ -n "$RESET_EPOCH" ] || { echo "error: classified wall has no observed reset epoch; not writing cooldown" >&2; exit 1; }
    fm_capacity_mark_cooldown "$STATE" "$HARNESS" "$ACCOUNT" "$PROFILE" "$RESET_EPOCH" "$CLASS" "$REASON" "$SOURCE_TASK"
    ;;
esac
