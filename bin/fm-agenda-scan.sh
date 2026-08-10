#!/usr/bin/env bash
# Scan the private business agenda and emit each item due in the current local period.
# Usage: fm-agenda-scan.sh [--help]
#
# Registry: data/business-agenda.md, one line per item in this shape:
# - <id> | <cadence> | <owner> | <action> | <delivery>
# Cadence is daily or weekly:mon through weekly:sun.
# Delivery is do, notify, or notify-on-problem.
# IDs are unique and may contain letters, digits, underscores, colons, and dashes.
# Blank lines and lines beginning with # are ignored; malformed or duplicate items
# are diagnosed and ignored.
# Each newly due item prints "agenda-due: <id> | <owner> | <action>".
# When no item is due, the scanner produces no stdout.
# Fire state is state/.agenda-fired with one private <id>|<cadence>|<date> line per item.
# FM_AGENDA_DATE is a YYYY-MM-DD test override; normal runs capture one local date.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="${FM_AGENDA_REGISTRY:-$DATA/business-agenda.md}"
FIRED="$STATE/.agenda-fired"
LOCK="$STATE/.agenda-fired.lock"
AGENDA_TMP=

agenda_error() {
  printf 'agenda-scan: %s\n' "$*" >&2
}

agenda_usage() {
  printf '%s\n' \
    'Usage: fm-agenda-scan.sh [--help]' \
    'Scans data/business-agenda.md and prints due agenda items.' \
    'Set FM_AGENDA_DATE=YYYY-MM-DD only to make tests deterministic.'
}

agenda_cleanup() {
  [ -z "$AGENDA_TMP" ] || rm -f -- "$AGENDA_TMP"
  rmdir "$LOCK" 2>/dev/null || true
}

case "${1:-}" in
  '') ;;
  --help|-h) agenda_usage; exit 0 ;;
  *) agenda_error "unexpected argument: $1"; exit 2 ;;
esac

if [ ! -e "$REGISTRY" ]; then
  exit 0
fi
[ -f "$REGISTRY" ] || { agenda_error "registry is not a regular file: $REGISTRY"; exit 1; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] \
  || { agenda_error "state directory is unavailable: $STATE"; exit 1; }

TODAY="${FM_AGENDA_DATE:-$(date +%F)}"
case "$TODAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) agenda_error "invalid agenda date: $TODAY"; exit 1 ;;
esac

WEEKDAY=$(date -d "$TODAY" +%u 2>/dev/null \
  || date -j -f '%Y-%m-%d' "$TODAY" +%u 2>/dev/null) \
  || { agenda_error "could not determine weekday for $TODAY"; exit 1; }

case "$WEEKDAY" in
  1|2|3|4|5|6|7) ;;
  *) agenda_error "invalid weekday: $WEEKDAY"; exit 1 ;;
esac

if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0
fi
trap agenda_cleanup EXIT HUP INT TERM

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

agenda_fired() {
  local wanted=$1 stored_id stored_cadence stored_date extra
  [ -f "$FIRED" ] || return 1
  while IFS='|' read -r stored_id stored_cadence stored_date extra || [ -n "${stored_id:-}${stored_cadence:-}${stored_date:-}${extra:-}" ]; do
    [ "${stored_id:-}|${stored_cadence:-}|${stored_date:-}" = "$wanted" ] \
      && [ -z "${extra:-}" ] && return 0
  done < "$FIRED"
  return 1
}

agenda_id_seen() {
  local candidate=$1 seen_id
  for seen_id in "${SEEN_IDS[@]}"; do
    [ "$candidate" = "$seen_id" ] && return 0
  done
  return 1
}

agenda_id_fired_this_scan() {
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
    *) agenda_error "ignoring malformed registry line"; continue ;;
  esac

  IFS='|' read -r raw_id raw_cadence raw_owner raw_action raw_delivery extra <<< "$record"
  id=$(trim "${raw_id:-}")
  cadence=$(trim "${raw_cadence:-}")
  owner=$(trim "${raw_owner:-}")
  action=$(trim "${raw_action:-}")
  delivery=$(trim "${raw_delivery:-}")
  if [ -n "${extra:-}" ] || [ -z "$id" ] || [ -z "$owner" ] || [ -z "$action" ]; then
    agenda_error "ignoring malformed registry line"
    continue
  fi
  case "$id" in
    *[!A-Za-z0-9_:-]*) agenda_error "ignoring registry item with invalid id: $id"; continue ;;
  esac
  case "$delivery" in
    do|notify|notify-on-problem) ;;
    *) agenda_error "ignoring registry item with invalid delivery: $id"; continue ;;
  esac
  is_due=1
  case "$cadence" in
    daily) ;;
    weekly:mon|weekly:tue|weekly:wed|weekly:thu|weekly:fri|weekly:sat|weekly:sun)
      [ "$(weekday_number "${cadence#weekly:}")" = "$WEEKDAY" ] || is_due=0
      ;;
    *) agenda_error "ignoring registry item with invalid cadence: $id"; continue ;;
  esac
  if agenda_id_seen "$id"; then
    agenda_error "ignoring duplicate registry id: $id"
    continue
  fi
  SEEN_IDS+=("$id")
  [ "$is_due" -eq 1 ] || continue

  fire_record="$id|$cadence|$TODAY"
  agenda_fired "$fire_record" && continue
  DUE_IDS+=("$id")
  DUE_RECORDS+=("$fire_record")
  DUE_LINES+=("agenda-due: $id | $owner | $action")
done < "$REGISTRY"

[ "${#DUE_LINES[@]}" -gt 0 ] || exit 0

umask 077
AGENDA_TMP=$(mktemp "$STATE/.agenda-fired.XXXXXX") \
  || { agenda_error 'could not create fire-state update'; exit 1; }
if [ -f "$FIRED" ]; then
  while IFS='|' read -r stored_id stored_cadence stored_date extra || [ -n "${stored_id:-}${stored_cadence:-}${stored_date:-}${extra:-}" ]; do
    [ -n "${stored_id:-}" ] && [ -n "${stored_cadence:-}" ] && [ -n "${stored_date:-}" ] \
      || continue
    [ -z "${extra:-}" ] || continue
    agenda_id_fired_this_scan "$stored_id" && continue
    printf '%s|%s|%s\n' "$stored_id" "$stored_cadence" "$stored_date" >> "$AGENDA_TMP" \
      || { agenda_error 'could not write fire-state update'; exit 1; }
  done < "$FIRED"
fi
for fire_record in "${DUE_RECORDS[@]}"; do
  printf '%s\n' "$fire_record" >> "$AGENDA_TMP" \
    || { agenda_error 'could not write fire-state update'; exit 1; }
done
chmod 0600 "$AGENDA_TMP" || { agenda_error 'could not protect fire-state update'; exit 1; }
mv -f -- "$AGENDA_TMP" "$FIRED" || { agenda_error 'could not publish fire-state update'; exit 1; }
AGENDA_TMP=

for due_line in "${DUE_LINES[@]}"; do
  printf '%s\n' "$due_line"
done
