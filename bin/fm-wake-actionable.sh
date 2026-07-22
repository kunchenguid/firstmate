#!/usr/bin/env bash
# Capture and revalidate one watcher reason without consuming the durable queue.
#
# Usage:
#   fm-wake-actionable.sh capture <watcher-reason>
#   fm-wake-actionable.sh validate <receipt>
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
  echo "usage: $(basename "$0") <capture watcher-reason | validate receipt>" >&2
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
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i' "$path" 2>/dev/null
  else
    stat -c '%d:%i' "$path" 2>/dev/null
  fi
}

valid_task_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

meta_has_endpoint() {  # <meta> <endpoint>
  local meta=$1 endpoint=$2
  LC_ALL=C awk -v endpoint="$endpoint" '
    NR > 256 { exit }
    $0 == "window=" endpoint || $0 == "terminal=" endpoint { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$meta" 2>/dev/null
}

source_manifest() {  # <kind> <key>
  local kind=$1 key=$2 task source meta identity count=0 base
  case "$kind" in
    signal)
      fm_wake_status_key_map "$key" || return 1
      source="$STATE/$key"
      task=${FM_WAKE_STATUS_KEY%.status}
      valid_task_id "$task" || return 1
      meta="$STATE/$task.meta"
      identity=$(path_identity "$source") || return 1
      printf 'source\t%s\t%s\n' "$key" "$identity"
      identity=$(path_identity "$meta") || return 1
      printf 'meta\t%s.meta\t%s\n' "$task" "$identity"
      ;;
    stale)
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] && [ ! -L "$meta" ] || continue
        meta_has_endpoint "$meta" "$key" || continue
        task=$(basename "$meta" .meta)
        valid_task_id "$task" || return 1
        identity=$(path_identity "$meta") || return 1
        printf 'meta\t%s.meta\t%s\n' "$task" "$identity"
        count=$((count + 1))
      done
      [ "$count" -eq 1 ] || return 1
      ;;
    check)
      if [ "$key" = unauthenticated-state-checks ]; then
        for source in "$STATE"/*.check.sh; do
          [ -f "$source" ] && [ ! -L "$source" ] || continue
          base=$(basename "$source")
          identity=$(path_identity "$source") || return 1
          printf 'check\t%s\t%s\n' "$base" "$identity"
          count=$((count + 1))
        done
        [ "$count" -gt 0 ] || return 1
        return 0
      fi
      base=${key#"$STATE"/}
      [ "$key" = "$STATE/$base" ] || return 1
      case "$base" in
        *.check.sh) ;;
        *) return 1 ;;
      esac
      task=${base%.check.sh}
      valid_task_id "$task" || [ "$task" = x-watch ] || return 1
      identity=$(path_identity "$key") || return 1
      printf 'check\t%s\t%s\n' "$base" "$identity"
      ;;
    heartbeat)
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] && [ ! -L "$meta" ] || continue
        task=$(basename "$meta" .meta)
        valid_task_id "$task" || continue
        identity=$(path_identity "$meta") || return 1
        printf 'meta\t%s.meta\t%s\n' "$task" "$identity"
        count=$((count + 1))
      done
      [ "$count" -gt 0 ] || return 1
      ;;
    *) return 1 ;;
  esac
}

row_receipt() {  # <queue-row>
  local row=$1 epoch seq kind key _payload manifest digest checksum bytes
  IFS=$(printf '\t') read -r epoch seq kind key _payload <<EOF
$row
EOF
  case "$epoch:$seq" in *[!0-9:]*) return 1 ;; esac
  [ -n "$epoch" ] && [ -n "$seq" ] || return 1
  manifest=$(source_manifest "$kind" "$key") || return 1
  digest=$(printf '%s\n%s\n' "$row" "$manifest" | cksum) || return 1
  read -r checksum bytes <<EOF
$digest
EOF
  case "$checksum:$bytes" in *[!0-9:]*) return 1 ;; esac
  printf '%s:%s:%s\n' "$seq" "$checksum" "$bytes"
}

capture() {
  local reason=$1 rows row item receipt=''
  [ -n "$reason" ] || return 1
  rows=$(LC_ALL=C awk -F '\t' -v reason="$reason" '
    NF >= 5 && $5 == reason { print }
  ' "$FM_WAKE_QUEUE" 2>/dev/null) || return 2
  [ -n "$rows" ] || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    item=$(row_receipt "$row") || continue
    if [ -n "$receipt" ]; then receipt="$receipt,$item"; else receipt=$item; fi
  done <<EOF
$rows
EOF
  [ -n "$receipt" ] || return 1
  printf '%s\n' "$receipt"
}

validate_one() {  # <single-row-receipt>
  local item=$1 seq expected_checksum expected_bytes row actual
  IFS=: read -r seq expected_checksum expected_bytes <<EOF
$item
EOF
  case "$seq:$expected_checksum:$expected_bytes" in *[!0-9:]*) return 1 ;; esac
  [ -n "$seq" ] && [ -n "$expected_checksum" ] && [ -n "$expected_bytes" ] || return 1
  row=$(LC_ALL=C awk -F '\t' -v seq="$seq" 'NF >= 5 && $2 == seq { print; exit }' "$FM_WAKE_QUEUE" 2>/dev/null) || return 2
  [ -n "$row" ] || return 1
  actual=$(row_receipt "$row") || return 1
  [ "$actual" = "$item" ]
}

validate() {
  local receipt=$1 item
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    validate_one "$item" && return 0
  done <<EOF
$(printf '%s' "$receipt" | tr ',' '\n')
EOF
  return 1
}

case "$ACTION" in
  capture|validate) ;;
  *) usage ;;
esac
[ -n "$VALUE" ] || usage
acquire_queue_lock || {
  echo "fm-wake-actionable: queue lock remained busy beyond the validation bound" >&2
  exit 2
}
"$ACTION" "$VALUE"
