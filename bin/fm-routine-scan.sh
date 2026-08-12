#!/usr/bin/env bash
# Scan the private recurring routine and emit each item due in the current local period.
# Usage: fm-routine-scan.sh [--help]
#
# Registry: data/routines.md, one line per item in this shape:
# - <id> | <cadence> | <owner> | <action>
# Cadence is daily or weekly:mon through weekly:sun.
# IDs are unique and may contain letters, digits, underscores, colons, and dashes.
# Blank lines and lines beginning with # are ignored; malformed or duplicate items
# are diagnosed and ignored.
# Each due item prints "routine-due: <id> | <owner> | <action>".
# When no item is due, the scanner produces no stdout.
# With FM_ROUTINE_DEFER_FIRE=1, due records are retained in state/.routine-pending
# until --ack promotes them to fire state after successful wake publication.
# Fire state is state/.routine-fired with one private <id>|<cadence>|<date> line per acknowledged item.
# FM_ROUTINE_DATE is a YYYY-MM-DD test override; normal runs capture one local date.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="${FM_ROUTINE_REGISTRY:-$DATA/routines.md}"
FIRED="$STATE/.routine-fired"
PENDING="$STATE/.routine-pending"
GENERATION_FILE="$STATE/.routine-generation"
LOCK="$STATE/.routine-fired.lock"
ROUTINE_TMP=
PENDING_TMP=
GENERATION_TMP=
GENERATION_RECEIPT_TMP=
PENDING_ACK_TMP=
ROUTINE_DEFER_FIRE=${FM_ROUTINE_DEFER_FIRE:-0}
ROUTINE_ACK=0
ROUTINE_ACK_GENERATION=
GENERATION_RECEIPT=${FM_ROUTINE_GENERATION_RECEIPT:-}

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
  [ -z "$PENDING_TMP" ] || rm -f -- "$PENDING_TMP"
  [ -z "$GENERATION_TMP" ] || rm -f -- "$GENERATION_TMP"
  [ -z "$GENERATION_RECEIPT_TMP" ] || rm -f -- "$GENERATION_RECEIPT_TMP"
  [ -z "$PENDING_ACK_TMP" ] || rm -f -- "$PENDING_ACK_TMP"
  exec 8<&- 2>/dev/null || true
  fm_lock_release "$LOCK" 2>/dev/null || true
}

routine_interrupt() {
  exit 1
}

case "${1:-}" in
  '') ;;
  --help|-h) routine_usage; exit 0 ;;
  --ack)
    ROUTINE_ACK=1
    case "${2:-}" in
      '') routine_error 'routine acknowledgement requires a generation'; exit 2 ;;
      --generation)
        ROUTINE_ACK_GENERATION=${3:-}
        case "$ROUTINE_ACK_GENERATION" in
          ''|*[!0-9]*) routine_error 'invalid routine acknowledgement generation'; exit 2 ;;
        esac
        [ "$#" -eq 3 ] || { routine_error 'unexpected acknowledgement arguments'; exit 2; }
        ;;
      *) routine_error "unexpected argument: ${2:-}"; exit 2 ;;
    esac
    ;;
  *) routine_error "unexpected argument: $1"; exit 2 ;;
esac
case "$ROUTINE_DEFER_FIRE" in
  0|1) ;;
  *) routine_error 'invalid FM_ROUTINE_DEFER_FIRE'; exit 2 ;;
esac

[ ! -L "$PENDING" ] \
  || { routine_error "pending routine state is unavailable: $PENDING"; exit 1; }

if [ "$ROUTINE_ACK" -eq 0 ]; then
  [ ! -L "$REGISTRY" ] \
    || { routine_error "registry is a symlink: $REGISTRY"; exit 1; }
  if [ -e "$REGISTRY" ]; then
    [ -f "$REGISTRY" ] \
      || { routine_error "registry is not a regular file: $REGISTRY"; exit 1; }
  elif [ "$ROUTINE_DEFER_FIRE" -ne 1 ] || [ ! -e "$PENDING" ]; then
    exit 0
  fi
fi
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
  if [ "$ROUTINE_ACK" -eq 1 ]; then
    routine_error 'could not acquire routine state lock for acknowledgement'
    exit 1
  fi
  exit 0
fi
trap routine_cleanup EXIT
trap routine_interrupt HUP INT TERM

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

routine_begin_generation() {
  local current next
  [ ! -L "$GENERATION_FILE" ] \
    || { routine_error "routine generation state is unavailable: $GENERATION_FILE"; return 1; }
  if [ -e "$GENERATION_FILE" ]; then
    [ -f "$GENERATION_FILE" ] \
      || { routine_error "routine generation state is unavailable: $GENERATION_FILE"; return 1; }
    current=$(cat "$GENERATION_FILE") \
      || { routine_error "could not read routine generation state: $GENERATION_FILE"; return 1; }
  else
    current=0
  fi
  case "$current" in
    ''|*[!0-9]*) routine_error 'routine generation state is malformed'; return 1 ;;
  esac
  next=$((current + 1))
  umask 077
  GENERATION_TMP=$(mktemp "$STATE/.routine-generation.XXXXXX") \
    || { routine_error 'could not create routine generation state'; return 1; }
  printf '%s\n' "$next" > "$GENERATION_TMP" \
    || { routine_error 'could not write routine generation state'; return 1; }
  chmod 0600 "$GENERATION_TMP" \
    || { routine_error 'could not protect routine generation state'; return 1; }
  mv -f -- "$GENERATION_TMP" "$GENERATION_FILE" \
    || { routine_error 'could not publish routine generation state'; return 1; }
  GENERATION_TMP=
  ROUTINE_GENERATION=$next
  if [ -n "$GENERATION_RECEIPT" ]; then
    [ ! -L "$GENERATION_RECEIPT" ] \
      || { routine_error "routine generation receipt is unavailable: $GENERATION_RECEIPT"; return 1; }
    GENERATION_RECEIPT_TMP=$(mktemp "${GENERATION_RECEIPT}.XXXXXX") \
      || { routine_error 'could not create routine generation receipt'; return 1; }
    printf '%s\n' "$next" > "$GENERATION_RECEIPT_TMP" \
      || { routine_error 'could not write routine generation receipt'; return 1; }
    chmod 0600 "$GENERATION_RECEIPT_TMP" \
      || { routine_error 'could not protect routine generation receipt'; return 1; }
    mv -f -- "$GENERATION_RECEIPT_TMP" "$GENERATION_RECEIPT" \
      || { routine_error 'could not publish routine generation receipt'; return 1; }
    GENERATION_RECEIPT_TMP=
  fi
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

routine_ack_seen() {
  local candidate=$1 seen_record
  for seen_record in "${ACK_RECORDS[@]}"; do
    [ "$candidate" = "$seen_record" ] && return 0
  done
  return 1
}

routine_ack_publication_exists() {
  local wake_key=$STATE/routine-scan.check.sh:routine-generation:$ROUTINE_ACK_GENERATION
  local found=1 queue_lock_held=0
  [ ! -L "$FM_WAKE_QUEUE" ] \
    || { routine_error "wake queue is unavailable: $FM_WAKE_QUEUE"; return 1; }
  if [ -e "$FM_WAKE_QUEUE" ]; then
    [ -f "$FM_WAKE_QUEUE" ] \
      || { routine_error "wake queue is unavailable: $FM_WAKE_QUEUE"; return 1; }
  fi
  [ "${FM_ROUTINE_WAKE_QUEUE_LOCK_HELD:-0}" = 1 ] || {
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" \
      || { routine_error 'could not acquire wake queue lock for acknowledgement'; return 1; }
    queue_lock_held=1
  }
  if [ -f "$FM_WAKE_QUEUE" ] && awk -F '\t' -v key="$wake_key" \
    '$3 == "check" && $4 == key && index($5, "routine-due: ") > 0 { found = 0; exit } END { exit found }' \
    "$FM_WAKE_QUEUE"; then
    found=0
  fi
  [ "$queue_lock_held" -eq 0 ] || fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ "$found" -eq 0 ] \
    || { routine_error "routine acknowledgement has no durable wake: $ROUTINE_ACK_GENERATION"; return 1; }
}

routine_ack_pending() {
  local pending_id pending_cadence pending_date pending_owner pending_action pending_generation pending_extra
  local stored_id stored_cadence stored_date stored_extra fire_record
  [ ! -L "$PENDING" ] \
    || { routine_error "pending routine state is unavailable: $PENDING"; return 1; }
  [ -e "$PENDING" ] || return 0
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] \
    || { routine_error "pending routine state is unavailable: $PENDING"; return 1; }

  ACK_RECORDS=()
  umask 077
  ROUTINE_TMP=$(mktemp "$STATE/.routine-fired.XXXXXX") \
    || { routine_error 'could not create fire-state acknowledgement'; return 1; }
  if [ -n "$ROUTINE_ACK_GENERATION" ]; then
    PENDING_ACK_TMP=$(mktemp "$STATE/.routine-pending.ack.XXXXXX") \
      || { routine_error 'could not create pending routine acknowledgement'; return 1; }
  fi
  if [ -f "$FIRED" ]; then
    while IFS='|' read -r stored_id stored_cadence stored_date stored_extra \
      || [ -n "${stored_id:-}${stored_cadence:-}${stored_date:-}${stored_extra:-}" ]; do
      [ -n "${stored_id:-}" ] && [ -n "${stored_cadence:-}" ] && [ -n "${stored_date:-}" ] \
        || continue
      [ -z "${stored_extra:-}" ] || continue
      fire_record="$stored_id|$stored_cadence|$stored_date"
      routine_ack_seen "$fire_record" && continue
      ACK_RECORDS+=("$fire_record")
      printf '%s\n' "$fire_record" >> "$ROUTINE_TMP" \
        || { routine_error 'could not write fire-state acknowledgement'; return 1; }
    done < "$FIRED"
  fi
  while IFS='|' read -r pending_id pending_cadence pending_date pending_owner pending_action pending_generation pending_extra \
    || [ -n "${pending_id:-}${pending_cadence:-}${pending_date:-}${pending_owner:-}${pending_action:-}${pending_generation:-}${pending_extra:-}" ]; do
    [ -n "${pending_id:-}" ] && [ -n "${pending_cadence:-}" ] \
      && [ -n "${pending_date:-}" ] && [ -n "${pending_owner:-}" ] \
      && [ -n "${pending_action:-}" ] && [ -n "${pending_generation:-}" ] \
      && [ -z "${pending_extra:-}" ] \
      || { routine_error 'pending routine state is malformed'; return 1; }
    case "$pending_id" in
      *[!A-Za-z0-9_:-]*) routine_error 'pending routine state has an invalid id'; return 1 ;;
    esac
    case "$pending_cadence" in
      daily|weekly:mon|weekly:tue|weekly:wed|weekly:thu|weekly:fri|weekly:sat|weekly:sun) ;;
      *) routine_error 'pending routine state has an invalid cadence'; return 1 ;;
    esac
    case "$pending_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) routine_error 'pending routine state has an invalid date'; return 1 ;;
    esac
    case "$pending_generation" in
      ''|*[!0-9]*) routine_error 'pending routine state has an invalid generation'; return 1 ;;
    esac
    if [ -n "$ROUTINE_ACK_GENERATION" ] && [ "$pending_generation" != "$ROUTINE_ACK_GENERATION" ]; then
      printf '%s|%s|%s|%s|%s|%s\n' \
        "$pending_id" "$pending_cadence" "$pending_date" "$pending_owner" \
        "$pending_action" "$pending_generation" >> "$PENDING_ACK_TMP" \
        || { routine_error 'could not retain pending routine state'; return 1; }
      continue
    fi
    fire_record="$pending_id|$pending_cadence|$pending_date"
    routine_ack_seen "$fire_record" && continue
    ACK_RECORDS+=("$fire_record")
    printf '%s\n' "$fire_record" >> "$ROUTINE_TMP" \
      || { routine_error 'could not write fire-state acknowledgement'; return 1; }
  done < "$PENDING"
  chmod 0600 "$ROUTINE_TMP" \
    || { routine_error 'could not protect fire-state acknowledgement'; return 1; }
  mv -f -- "$ROUTINE_TMP" "$FIRED" \
    || { routine_error 'could not publish fire-state acknowledgement'; return 1; }
  ROUTINE_TMP=
  if [ -n "$ROUTINE_ACK_GENERATION" ]; then
    if [ -s "$PENDING_ACK_TMP" ]; then
      chmod 0600 "$PENDING_ACK_TMP" \
        || { routine_error 'could not protect pending routine state'; return 1; }
      mv -f -- "$PENDING_ACK_TMP" "$PENDING" \
        || { routine_error 'could not publish retained pending routine state'; return 1; }
    else
      rm -f -- "$PENDING_ACK_TMP" "$PENDING" \
        || { routine_error 'could not clear pending routine state'; return 1; }
    fi
    PENDING_ACK_TMP=
  else
    rm -f -- "$PENDING" \
      || { routine_error 'could not clear pending routine state'; return 1; }
  fi
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

if [ "$ROUTINE_ACK" -eq 1 ]; then
  routine_ack_publication_exists || exit 1
  routine_ack_pending || exit 1
  exit 0
fi
if [ "$ROUTINE_DEFER_FIRE" -eq 1 ]; then
  routine_begin_generation || exit 1
fi

SEEN_IDS=()
DUE_IDS=()
DUE_RECORDS=()
DUE_LINES=()
DUE_PENDING_LINES=()
if [ "$ROUTINE_DEFER_FIRE" -eq 1 ] && [ -e "$PENDING" ]; then
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] \
    || { routine_error "pending routine state is unavailable: $PENDING"; exit 1; }
  while IFS='|' read -r pending_id pending_cadence pending_date pending_owner pending_action pending_generation pending_extra \
    || [ -n "${pending_id:-}${pending_cadence:-}${pending_date:-}${pending_owner:-}${pending_action:-}${pending_generation:-}${pending_extra:-}" ]; do
    [ -n "${pending_id:-}" ] && [ -n "${pending_cadence:-}" ] \
      && [ -n "${pending_date:-}" ] && [ -n "${pending_owner:-}" ] \
      && [ -n "${pending_action:-}" ] && [ -n "${pending_generation:-}" ] \
      && [ -z "${pending_extra:-}" ] \
      || { routine_error 'pending routine state is malformed'; exit 1; }
    case "$pending_generation" in
      ''|*[!0-9]*) routine_error 'pending routine state has an invalid generation'; exit 1 ;;
    esac
    DUE_IDS+=("$pending_id")
    DUE_RECORDS+=("$pending_id|$pending_cadence|$pending_date")
    DUE_LINES+=("routine-due: $pending_id | $pending_owner | $pending_action")
    DUE_PENDING_LINES+=("$pending_id|$pending_cadence|$pending_date|$pending_owner|$pending_action|$pending_generation")
  done < "$PENDING"
fi
if [ -e "$REGISTRY" ]; then
  [ ! -L "$REGISTRY" ] \
    || { routine_error "registry became a symlink: $REGISTRY"; exit 1; }
  [ -f "$REGISTRY" ] \
    || { routine_error "registry is not a regular file: $REGISTRY"; exit 1; }
  exec 8< "$REGISTRY" \
    || { routine_error "could not open routine registry: $REGISTRY"; exit 1; }
  [ ! -L "$REGISTRY" ] \
    || { routine_error "registry became a symlink: $REGISTRY"; exit 1; }
else
  exec 8< /dev/null \
    || { routine_error 'could not open empty routine registry'; exit 1; }
fi
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
    '- '*) record=${line#- } ;;
    *) routine_error "ignoring malformed registry line"; continue ;;
  esac

  separators=${record//[^|]/}
  [ "${#separators}" -eq 3 ] \
    || { routine_error "ignoring malformed registry line"; continue; }
  IFS='|' read -r raw_id raw_cadence raw_owner raw_action <<< "$record"
  id=$(trim "${raw_id:-}")
  cadence=$(trim "${raw_cadence:-}")
  owner=$(trim "${raw_owner:-}")
  action=$(trim "${raw_action:-}")
  if [ -z "$id" ] || [ -z "$owner" ] || [ -z "$action" ]; then
    routine_error "ignoring malformed registry line"
    continue
  fi
  case "$id" in
    *[!A-Za-z0-9_:-]*) routine_error "ignoring registry item with invalid id: $id"; continue ;;
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
  routine_id_fired_this_scan "$id" && continue
  routine_fired "$fire_record" && continue
  DUE_IDS+=("$id")
  DUE_RECORDS+=("$fire_record")
  DUE_LINES+=("routine-due: $id | $owner | $action")
  if [ "$ROUTINE_DEFER_FIRE" -eq 1 ]; then
    DUE_PENDING_LINES+=("$id|$cadence|$TODAY|$owner|$action|$ROUTINE_GENERATION")
  fi
done <&8
[ ! -L "$REGISTRY" ] \
  || { routine_error "registry became a symlink: $REGISTRY"; exit 1; }

[ "${#DUE_LINES[@]}" -gt 0 ] || exit 0

if [ "$ROUTINE_DEFER_FIRE" -eq 1 ]; then
  umask 077
  PENDING_TMP=$(mktemp "$STATE/.routine-pending.XXXXXX") \
    || { routine_error 'could not create pending routine state'; exit 1; }
  for pending_line in "${DUE_PENDING_LINES[@]}"; do
    printf '%s\n' "$pending_line" >> "$PENDING_TMP" \
      || { routine_error 'could not write pending routine state'; exit 1; }
  done
  chmod 0600 "$PENDING_TMP" \
    || { routine_error 'could not protect pending routine state'; exit 1; }
  mv -f -- "$PENDING_TMP" "$PENDING" \
    || { routine_error 'could not publish pending routine state'; exit 1; }
  PENDING_TMP=
fi

for due_line in "${DUE_LINES[@]}"; do
  printf '%s\n' "$due_line" \
    || { routine_error 'could not emit due routine'; exit 1; }
done

[ "$ROUTINE_DEFER_FIRE" -eq 1 ] && exit 0

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
