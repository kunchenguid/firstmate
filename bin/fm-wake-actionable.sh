#!/usr/bin/env bash
# Capture and revalidate one watcher reason without consuming the durable queue.
#
# Usage:
#   fm-wake-actionable.sh capture <watcher-reason>
#   fm-wake-actionable.sh validate <receipt>
#   fm-wake-actionable.sh validate-batch < receipts
#
# `capture` binds every matching durable queue row to the identity of its current
# home-local source and prints one opaque numeric receipt.
# `validate` succeeds while at least one bound row remains unread in this home's
# queue with the same source identity, preserving coalesced signal batches when
# cleanup has made only some of their task rows obsolete.
# The bounded queue-lock read never executes a task check or trusts queue payload
# text as a path.
# Exit 0 means current, exit 1 means obsolete, and exit 2 means validation could
# not be completed safely within its bound.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

ACTION=${1:-}
VALUE=${2:-}
LOCK_ATTEMPTS=${FM_WAKE_ACTIONABLE_LOCK_ATTEMPTS:-200}
LOCK_SLEEP=${FM_WAKE_ACTIONABLE_LOCK_SLEEP:-0.01}
LOCK_HELD=false

case "$LOCK_ATTEMPTS" in ''|*[!0-9]*|0) LOCK_ATTEMPTS=200 ;; esac

usage() {
  echo "usage: $(basename "$0") <capture watcher-reason | validate receipt | validate-batch>" >&2
  exit 2
}

cleanup() {
  [ "$LOCK_HELD" = false ] || fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM

acquire_queue_lock() {
  local attempt=0
  while [ "$attempt" -lt "$LOCK_ATTEMPTS" ]; do
    if fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK"; then
      LOCK_HELD=true
      return 0
    fi
    sleep "$LOCK_SLEEP"
    attempt=$((attempt + 1))
  done
  return 1
}

path_identity() {  # <regular-nonsymlink-path>
  local path=$1 identity
  [ -e "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    identity=$(stat -f '%d:%i' "$path" 2>/dev/null) || {
      [ -e "$path" ] || return 1
      return 2
    }
  else
    identity=$(stat -c '%d:%i' "$path" 2>/dev/null) || {
      [ -e "$path" ] || return 1
      return 2
    }
  fi
  printf '%s\n' "$identity"
}

entry_identity() {  # <regular-or-symlink-path>
  local path=$1 identity
  { [ -f "$path" ] || [ -L "$path" ]; } || return 1
  if [ "$(uname)" = Darwin ]; then
    identity=$(stat -f '%d:%i' "$path" 2>/dev/null) || {
      { [ -f "$path" ] || [ -L "$path" ]; } || return 1
      return 2
    }
  else
    identity=$(stat -c '%d:%i' "$path" 2>/dev/null) || {
      { [ -f "$path" ] || [ -L "$path" ]; } || return 1
      return 2
    }
  fi
  printf '%s\n' "$identity"
}

status_identity() {  # <regular-nonsymlink-status>
  local path=$1 identity size digest checksum bytes status
  if identity=$(path_identity "$path"); then
    :
  else
    status=$?
    return "$status"
  fi
  if [ "$(uname)" = Darwin ]; then
    size=$(stat -f '%z' "$path" 2>/dev/null) || {
      [ -e "$path" ] || return 1
      return 2
    }
  else
    size=$(stat -c '%s' "$path" 2>/dev/null) || {
      [ -e "$path" ] || return 1
      return 2
    }
  fi
  digest=$(set -o pipefail; tail -c 65536 "$path" 2>/dev/null | cksum) || {
    [ -e "$path" ] || return 1
    return 2
  }
  read -r checksum bytes <<EOF
$digest
EOF
  case "$checksum:$bytes" in *[!0-9:]*) return 2 ;; esac
  [ -n "$checksum" ] && [ -n "$bytes" ] || return 2
  printf '%s:%s:%s:%s\n' "$identity" "$size" "$checksum" "$bytes"
}

valid_task_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

meta_has_endpoint() {  # <meta> <endpoint>
  local meta=$1 endpoint=$2 result
  result=$(LC_ALL=C awk -v endpoint="$endpoint" '
    NR > 256 { exit }
    $0 == "window=" endpoint || $0 == "terminal=" endpoint { print "found"; exit }
  ' "$meta" 2>/dev/null) || {
    [ -e "$meta" ] || return 1
    return 2
  }
  [ "$result" = found ]
}

source_manifest() {  # <kind> <key>
  local kind=$1 key=$2 task source meta identity count=0 base encoded candidate candidate_encoded status
  case "$kind" in
    signal)
      fm_wake_status_key_map "$key" || return 1
      source="$STATE/$key"
      task=${FM_WAKE_STATUS_KEY%.status}
      valid_task_id "$task" || return 1
      meta="$STATE/$task.meta"
      if identity=$(path_identity "$source"); then :; else status=$?; return "$status"; fi
      printf 'source\t%s\t%s\n' "$key" "$identity"
      if identity=$(path_identity "$meta"); then :; else status=$?; return "$status"; fi
      printf 'meta\t%s.meta\t%s\n' "$task" "$identity"
      ;;
    stale)
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] && [ ! -L "$meta" ] || continue
        if meta_has_endpoint "$meta" "$key"; then
          :
        else
          status=$?
          [ "$status" -ne 2 ] || return 2
          continue
        fi
        task=$(basename "$meta" .meta)
        valid_task_id "$task" || return 1
        if identity=$(path_identity "$meta"); then :; else status=$?; return "$status"; fi
        printf 'meta\t%s.meta\t%s\n' "$task" "$identity"
        count=$((count + 1))
      done
      [ "$count" -eq 1 ] || return 1
      ;;
    check)
      if [ "$key" = unauthenticated-state-checks ]; then
        printf 'queue-only\tunauthenticated-state-checks\n'
        return 0
      fi
      case "$key" in
        unauthenticated-state-checks:*)
          base=${key#unauthenticated-state-checks:}
          case "$base" in
            hex:*)
              encoded=${base#hex:}
              case "$encoded" in ''|*[!0-9a-f]*) return 1 ;; esac
              [ $(( ${#encoded} % 2 )) -eq 0 ] || return 1
              [ "${#encoded}" -le 510 ] || return 1
              source=
              for candidate in "$STATE"/*.check.sh; do
                { [ -f "$candidate" ] || [ -L "$candidate" ]; } || continue
                candidate_encoded=$(fm_wake_hex_encode "${candidate##*/}") || return 2
                [ "$candidate_encoded" = "$encoded" ] || continue
                source=$candidate
                break
              done
              ;;
            ''|.*|*[!A-Za-z0-9._-]*|*/*) return 1 ;;
            *.check.sh)
              [ "${#base}" -le 255 ] || return 1
              source="$STATE/$base"
              ;;
            *) return 1 ;;
          esac
          [ -n "$source" ] || return 1
          if identity=$(entry_identity "$source"); then :; else status=$?; return "$status"; fi
          printf 'rejected-check\t%s\t%s\n' "$base" "$identity"
          return 0
          ;;
      esac
      base=${key#"$STATE"/}
      [ "$key" = "$STATE/$base" ] || return 1
      case "$base" in
        *.check.sh) ;;
        *) return 1 ;;
      esac
      task=${base%.check.sh}
      valid_task_id "$task" || [ "$task" = x-watch ] || return 1
      if identity=$(path_identity "$key"); then :; else status=$?; return "$status"; fi
      printf 'check\t%s\t%s\n' "$base" "$identity"
      ;;
    heartbeat)
      if [ "$key" = heartbeat ]; then
        printf 'queue-only\theartbeat\n'
        return 0
      fi
      case "$key" in heartbeat:*.status) ;; *) return 1 ;; esac
      base=${key#heartbeat:}
      fm_wake_status_key_map "$base" || return 1
      source="$STATE/$base"
      task=${FM_WAKE_STATUS_KEY%.status}
      valid_task_id "$task" || return 1
      meta="$STATE/$task.meta"
      if identity=$(status_identity "$source"); then :; else status=$?; return "$status"; fi
      printf 'status\t%s\t%s\n' "$base" "$identity"
      if identity=$(path_identity "$meta"); then :; else status=$?; return "$status"; fi
      printf 'meta\t%s.meta\t%s\n' "$task" "$identity"
      ;;
    *) return 1 ;;
  esac
}

row_receipt() {  # <queue-row>
  local row=$1 epoch seq kind key _payload manifest digest checksum bytes status
  IFS=$(printf '\t') read -r epoch seq kind key _payload <<EOF
$row
EOF
  case "$epoch:$seq" in *[!0-9:]*) return 1 ;; esac
  [ -n "$epoch" ] && [ -n "$seq" ] || return 1
  if manifest=$(source_manifest "$kind" "$key"); then :; else status=$?; return "$status"; fi
  digest=$(set -o pipefail; printf '%s\n%s\n' "$row" "$manifest" | cksum) || return 2
  read -r checksum bytes <<EOF
$digest
EOF
  case "$checksum:$bytes" in *[!0-9:]*) return 2 ;; esac
  [ -n "$checksum" ] && [ -n "$bytes" ] || return 2
  printf '%s:%s:%s\n' "$seq" "$checksum" "$bytes"
}

capture() {
  local reason=$1 rows row item receipt='' status saw_error=false
  [ -n "$reason" ] || return 1
  rows=$(FM_WAKE_CAPTURE_REASON="$reason" LC_ALL=C awk -F '\t' '
    NF >= 5 && $5 == ENVIRON["FM_WAKE_CAPTURE_REASON"] { print }
  ' "$FM_WAKE_QUEUE" 2>/dev/null) || return 2
  [ -n "$rows" ] || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if item=$(row_receipt "$row"); then
      if [ -n "$receipt" ]; then receipt="$receipt,$item"; else receipt=$item; fi
    else
      status=$?
      [ "$status" -ne 2 ] || saw_error=true
    fi
  done <<EOF
$rows
EOF
  if [ -n "$receipt" ]; then
    printf '%s\n' "$receipt"
    [ "$saw_error" = false ] || return 2
    return 0
  fi
  [ "$saw_error" = false ] || return 2
  return 1
}

validate_one() {  # <single-row-receipt>
  local item=$1 seq expected_checksum expected_bytes row actual status
  IFS=: read -r seq expected_checksum expected_bytes <<EOF
$item
EOF
  case "$seq:$expected_checksum:$expected_bytes" in *[!0-9:]*) return 1 ;; esac
  [ -n "$seq" ] && [ -n "$expected_checksum" ] && [ -n "$expected_bytes" ] || return 1
  row=$(LC_ALL=C awk -F '\t' -v seq="$seq" 'NF >= 5 && $2 == seq { print; exit }' "$FM_WAKE_QUEUE" 2>/dev/null) || return 2
  [ -n "$row" ] || return 1
  if actual=$(row_receipt "$row"); then :; else status=$?; return "$status"; fi
  [ "$actual" = "$item" ]
}

validate_state() {
  local receipt=$1 item status saw_current=false saw_error=false
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if validate_one "$item"; then
      saw_current=true
    else
      status=$?
      [ "$status" -ne 2 ] || saw_error=true
    fi
  done <<EOF
$(printf '%s' "$receipt" | tr ',' '\n')
EOF
  if [ "$saw_current" = true ] && [ "$saw_error" = true ]; then
    printf 'current-error\n'
  elif [ "$saw_current" = true ]; then
    printf 'current\n'
  elif [ "$saw_error" = true ]; then
    printf 'error\n'
  else
    printf 'obsolete\n'
  fi
}

validate() {
  case "$(validate_state "$1")" in
    current) return 0 ;;
    obsolete) return 1 ;;
    *) return 2 ;;
  esac
}

validate_batch() {
  local receipt state count=0 saw_error=false
  while IFS= read -r receipt; do
    [ -n "$receipt" ] || continue
    count=$((count + 1))
    state=$(validate_state "$receipt") || state=error
    printf '%s\n' "$state"
    case "$state" in error|current-error) saw_error=true ;; esac
  done
  [ "$count" -gt 0 ] || return 1
  [ "$saw_error" = false ] || return 2
}

case "$ACTION" in
  capture|validate) [ -n "$VALUE" ] || usage ;;
  validate-batch) [ "$#" -eq 1 ] || usage ;;
  *) usage ;;
esac
acquire_queue_lock || {
  echo "fm-wake-actionable: queue lock remained busy beyond the validation bound" >&2
  exit 2
}
case "$ACTION" in
  validate-batch) validate_batch ;;
  *) "$ACTION" "$VALUE" ;;
esac
