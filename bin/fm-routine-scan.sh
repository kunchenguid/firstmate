#!/usr/bin/env bash
# Scan the private recurring routine and emit each item due in the current local period.
# Usage: fm-routine-scan.sh [--help]
#
# Registry: data/routines.md, one line per item in this shape:
# - <id> | <cadence> | <owner> | <action> | <delivery>
# Cadence is daily or weekly:mon through weekly:sun.
# Delivery is do, notify, or notify-on-problem.
# IDs are unique and may contain letters, digits, underscores, colons, and dashes.
# Blank lines and lines beginning with # are ignored; malformed or duplicate items
# are diagnosed and ignored.
# Each newly due item prints "routine-due: <id> | <owner> | <action>".
# When no item is due, the scanner produces no stdout.
# Fire state is state/.routine-fired with one private <id>|<cadence>|<date> line per item.
# FM_ROUTINE_DATE is a YYYY-MM-DD test override; normal runs capture one local date.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="${FM_ROUTINE_REGISTRY:-$DATA/routines.md}"
FIRED="$STATE/.routine-fired"
LOCK="$STATE/.routine-fired.lock"
ROUTINE_TMP=

routine_error() {
  printf 'routine-scan: %s\n' "$*" >&2
}

routine_usage() {
  printf '%s\n' \
    'Usage: fm-routine-scan.sh [--help]' \
    'Scans data/routines.md and prints due routine items.' \
    'Set FM_ROUTINE_DATE=YYYY-MM-DD only to make tests deterministic.'
}

routine_cleanup() {
  [ -z "$ROUTINE_TMP" ] || rm -f -- "$ROUTINE_TMP"
  fm_lock_release "$LOCK" 2>/dev/null || true
}

case "${1:-}" in
  '') ;;
  --help|-h) routine_usage; exit 0 ;;
  *) routine_error "unexpected argument: $1"; exit 2 ;;
esac

if [ ! -e "$REGISTRY" ]; then
  exit 0
fi
[ -f "$REGISTRY" ] || { routine_error "registry is not a regular file: $REGISTRY"; exit 1; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] \
  || { routine_error "state directory is unavailable: $STATE"; exit 1; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

TODAY="${FM_ROUTINE_DATE:-$(date +%F)}"
case "$TODAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) routine_error "invalid routine date: $TODAY"; exit 1 ;;
esac

WEEKDAY=$(date -d "$TODAY" +%u 2>/dev/null \
  || date -j -f '%Y-%m-%d' "$TODAY" +%u 2>/dev/null) \
  || { routine_error "could not determine weekday for $TODAY"; exit 1; }

case "$WEEKDAY" in
  1|2|3|4|5|6|7) ;;
  *) routine_error "invalid weekday: $WEEKDAY"; exit 1 ;;
esac

if ! fm_lock_try_acquire "$LOCK"; then
  exit 0
fi
trap routine_cleanup EXIT HUP INT TERM

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

weekday_number() {
  case "$1" in
    mon) printf '1' ;;
    tue) printf '2' ;;
    wed) printf '3' ;;
    thu) printf '4' ;;
    fri) printf '5' ;;
    sat) printf '6' ;;
    sun) printf '7' ;;
  esac
}

routine_fired() {
  local wanted=$1 stored_id stored_cadence stored_date extra
  [ -f "$FIRED" ] || return 1
  while IFS='|' read -r stored_id stored_cadence stored_date extra || [ -n "${stored_id:-}${stored_cadence:-}${stored_date:-}${extra:-}" ]; do
    [ "${stored_id:-}|${stored_cadence:-}|${stored_date:-}" = "$wanted" ] \
      && [ -z "${extra:-}" ] && return 0
  done < "$FIRED"
  return 1
}

routine_id_seen() {
  local candidate=$1 seen_id
  for seen_id in "${SEEN_IDS[@]}"; do
    [ "$candidate" = "$seen_id" ] && return 0
  done
  return 1
}

routine_id_fired_this_scan() {
  local candidate=$1 due_id
  for due_id in "${DUE_IDS[@]}"; do
    [ "$candidate" = "$due_id" ] && return 0
  done
  return 1
}

SEEN_IDS=()
DUE_IDS=()
DUE_RECORDS=()
DUE_LINES=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
    '- '*) record=${line#- } ;;
    *) routine_error "ignoring malformed registry line"; continue ;;
  esac

  IFS='|' read -r raw_id raw_cadence raw_owner raw_action raw_delivery extra <<< "$record"
  id=$(trim "${raw_id:-}")
  cadence=$(trim "${raw_cadence:-}")
  owner=$(trim "${raw_owner:-}")
  action=$(trim "${raw_action:-}")
  delivery=$(trim "${raw_delivery:-}")
  if [ -n "${extra:-}" ] || [ -z "$id" ] || [ -z "$owner" ] || [ -z "$action" ]; then
    routine_error "ignoring malformed registry line"
    continue
  fi
  case "$id" in
    *[!A-Za-z0-9_:-]*) routine_error "ignoring registry item with invalid id: $id"; continue ;;
  esac
  case "$delivery" in
    do|notify|notify-on-problem) ;;
    *) routine_error "ignoring registry item with invalid delivery: $id"; continue ;;
  esac
  is_due=1
  case "$cadence" in
    daily) ;;
    weekly:mon|weekly:tue|weekly:wed|weekly:thu|weekly:fri|weekly:sat|weekly:sun)
      [ "$(weekday_number "${cadence#weekly:}")" = "$WEEKDAY" ] || is_due=0
      ;;
    *) routine_error "ignoring registry item with invalid cadence: $id"; continue ;;
  esac
  if routine_id_seen "$id"; then
    routine_error "ignoring duplicate registry id: $id"
    continue
  fi
  SEEN_IDS+=("$id")
  [ "$is_due" -eq 1 ] || continue

  fire_record="$id|$cadence|$TODAY"
  routine_fired "$fire_record" && continue
  DUE_IDS+=("$id")
  DUE_RECORDS+=("$fire_record")
  DUE_LINES+=("routine-due: $id | $owner | $action")
done < "$REGISTRY"

[ "${#DUE_LINES[@]}" -gt 0 ] || exit 0

for due_line in "${DUE_LINES[@]}"; do
  printf '%s\n' "$due_line" \
    || { routine_error 'could not emit due routine'; exit 1; }
done

umask 077
ROUTINE_TMP=$(mktemp "$STATE/.routine-fired.XXXXXX") \
  || { routine_error 'could not create fire-state update'; exit 1; }
if [ -f "$FIRED" ]; then
  while IFS='|' read -r stored_id stored_cadence stored_date extra || [ -n "${stored_id:-}${stored_cadence:-}${stored_date:-}${extra:-}" ]; do
    [ -n "${stored_id:-}" ] && [ -n "${stored_cadence:-}" ] && [ -n "${stored_date:-}" ] \
      || continue
    [ -z "${extra:-}" ] || continue
    routine_id_fired_this_scan "$stored_id" && continue
    printf '%s|%s|%s\n' "$stored_id" "$stored_cadence" "$stored_date" >> "$ROUTINE_TMP" \
      || { routine_error 'could not write fire-state update'; exit 1; }
  done < "$FIRED"
fi
for fire_record in "${DUE_RECORDS[@]}"; do
  printf '%s\n' "$fire_record" >> "$ROUTINE_TMP" \
    || { routine_error 'could not write fire-state update'; exit 1; }
done
chmod 0600 "$ROUTINE_TMP" || { routine_error 'could not protect fire-state update'; exit 1; }
mv -f -- "$ROUTINE_TMP" "$FIRED" || { routine_error 'could not publish fire-state update'; exit 1; }
ROUTINE_TMP=
