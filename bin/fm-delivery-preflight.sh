#!/usr/bin/env bash
# Bind one unread Pi wake snapshot to deterministic delivery-continuation results.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONTINUE_BIN="${FM_DELIVERY_PREFLIGHT_CONTINUE_BIN:-$SCRIPT_DIR/fm-delivery-continue.sh}"
ROWS_FILE=${FM_DELIVERY_PREFLIGHT_ROWS_FILE:-}
LOCK_HELD=${FM_DELIVERY_PREFLIGHT_LOCK_HELD:-0}
OWN_LOCK=0
TASKS_TMP=
WAKE_TASKS_TMP=
WAKE_ROWS_TMP=
SEQS_TMP=

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-delivery-continuation-lib.sh
. "$SCRIPT_DIR/fm-delivery-continuation-lib.sh"

# shellcheck disable=SC2329
cleanup() {
  local status=$?
  [ -z "$TASKS_TMP" ] || rm -f -- "$TASKS_TMP" 2>/dev/null || true
  [ -z "$WAKE_TASKS_TMP" ] || rm -f -- "$WAKE_TASKS_TMP" 2>/dev/null || true
  [ -z "$WAKE_ROWS_TMP" ] || rm -f -- "$WAKE_ROWS_TMP" 2>/dev/null || true
  [ -z "$SEQS_TMP" ] || rm -f -- "$SEQS_TMP" 2>/dev/null || true
  [ "$OWN_LOCK" = 0 ] || fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$LOCK_HELD" in 0|1) ;; *) exit 2 ;; esac
if [ -n "$ROWS_FILE" ]; then
  [ -f "$ROWS_FILE" ] && [ ! -L "$ROWS_FILE" ] \
    && awk 'BEGIN { ok=1 } !/^[0-9]+$/ || seen[$0]++ { ok=0 } END { exit !ok }' "$ROWS_FILE" \
    || exit 1
fi

if [ "$LOCK_HELD" = 0 ]; then
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  OWN_LOCK=1
fi

TASKS_TMP=$(mktemp "$STATE/.delivery-preflight.tasks.XXXXXX") || exit 1
WAKE_TASKS_TMP=$(mktemp "$STATE/.delivery-preflight.wake-tasks.XXXXXX") || exit 1
WAKE_ROWS_TMP=$(mktemp "$STATE/.delivery-preflight.wake-rows.XXXXXX") || exit 1
SEQS_TMP=$(mktemp "$STATE/.delivery-preflight.seqs.XXXXXX") || exit 1

task_for_stale_key() {
  local key=$1 candidate=${1#fm-} meta task window
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    window=$(sed -n 's/^window=//p' "$meta" | tail -1)
    if [ "$key" = "$task" ] || [ "$candidate" = "$task" ] \
      || { [ -n "$window" ] && { [ "$key" = "$window" ] || [ "$candidate" = "$window" ]; }; }; then
      printf '%s\n' "$task"
      return 0
    fi
  done
  return 1
}

while IFS=$(printf '\t') read -r epoch seq kind key payload extra || [ -n "${epoch}${seq}${kind}${key}${payload}${extra}" ]; do
  [ -n "${epoch}${seq}${kind}${key}${payload}${extra}" ] || continue
  case "$seq" in ''|*[!0-9]*) exit 1 ;; esac
  [ -n "$epoch" ] && [ -n "$kind" ] && [ -n "$key" ] && [ -n "$payload" ] || exit 1
  if [ -n "$ROWS_FILE" ] && ! grep -qxF "$seq" "$ROWS_FILE"; then
    continue
  fi
  printf '%s\n' "$seq" >> "$SEQS_TMP" || exit 1
  case "$kind" in
    signal)
      task=${key%.status}
      task=${task%.turn-ended}
      case "$task" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
      printf '%s\n' "$task" >> "$TASKS_TMP" || exit 1
      printf '%s\n' "$task" >> "$WAKE_TASKS_TMP" || exit 1
      printf '%s\t%s\n' "$seq" "$task" >> "$WAKE_ROWS_TMP" || exit 1
      ;;
    stale)
      task=$(task_for_stale_key "$key") || continue
      printf '%s\n' "$task" >> "$TASKS_TMP" || exit 1
      printf '%s\n' "$task" >> "$WAKE_TASKS_TMP" || exit 1
      printf '%s\t%s\n' "$seq" "$task" >> "$WAKE_ROWS_TMP" || exit 1
      ;;
    check|heartbeat) ;;
    *) exit 1 ;;
  esac
done < "$FM_WAKE_QUEUE"

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  task=${meta##*/}
  task=${task%.meta}
  case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  mode=$(sed -n 's/^mode=//p' "$meta" | tail -1)
  spawn_gen=$(sed -n 's/^spawn_gen=//p' "$meta" | tail -1)
  [ "$kind" = ship ] && [ "$mode" = no-mistakes ] || continue
  status="$STATE/$task.status"
  [ -f "$status" ] && [ ! -L "$status" ] || continue
  brief="${FM_DATA_OVERRIDE:-$FM_HOME/data}/$task/brief.md"
  [ -f "$brief" ] && [ ! -L "$brief" ] || continue
  receipt_kind=$(fm_delivery_receipt_contract_kind "$brief" 2>/dev/null || true)
  [ -n "$receipt_kind" ] || continue
  receipt_state=$(fm_delivery_receipt_state "$status" "$receipt_kind" "$spawn_gen" 2>/dev/null || true)
  case "$receipt_state" in
    committed$'\t'*|historical) printf '%s\n' "$task" >> "$TASKS_TMP" || exit 1 ;;
  esac
done

LC_ALL=C sort -nu "$SEQS_TMP" -o "$SEQS_TMP" || exit 1
LC_ALL=C sort -u "$TASKS_TMP" -o "$TASKS_TMP" || exit 1
LC_ALL=C sort -u "$WAKE_TASKS_TMP" -o "$WAKE_TASKS_TMP" || exit 1
while IFS= read -r seq; do
  [ -n "$seq" ] && printf 'sequence=%s\n' "$seq"
done < "$SEQS_TMP"

lock_pid=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -cd '0-9' || true)
while IFS= read -r task; do
  [ -n "$task" ] || continue
  out=$(FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID="$lock_pid" \
    "$CONTINUE_BIN" "$task" 2>&1) || {
      printf '%s\n' "$out" >&2
      exit 1
    }
  printf '%s\n' "$out" | grep -Eq '^result=(sent|already-delivered|already-active|retry|refused) task=[A-Za-z0-9._-]+( reason=[A-Za-z0-9._-]+)?$' \
    || { printf '%s\n' "$out" >&2; exit 1; }
  if ! grep -qxF "$task" "$WAKE_TASKS_TMP" \
    && printf '%s\n' "$out" | grep -Eq '^result=(already-delivered|already-active|refused) '; then
    case "$out" in
      'result=refused task='*' reason=unverifiable-status-producer') ;;
      *) continue ;;
    esac
  fi
  printf '%s\n' "$out"
  if [ "${FM_DELIVERY_PREFLIGHT_INCLUDE_RETRY_SEQUENCES:-0}" = 1 ] \
    && printf '%s\n' "$out" | grep -q '^result=retry '; then
    awk -F '\t' -v task="$task" '$2 == task { print "retry-sequence=" $1 }' "$WAKE_ROWS_TMP"
  fi
done < "$TASKS_TMP"
