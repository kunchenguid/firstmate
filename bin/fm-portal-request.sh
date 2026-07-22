#!/usr/bin/env bash
# Safe local inbox transitions for authenticated portal messages.
#
# Usage:
#   fm-portal-request.sh list
#   fm-portal-request.sh read <message-id>
#   fm-portal-request.sh mark-queued <message-id>...
#   fm-portal-request.sh recover-unclaimed
#
# list prints only ids that still need an agent turn.
# read atomically claims one request and prints its bounded JSON message object.
# Portal text is printed only by read; it is never put in an argument or log.
# mark-queued is called by the watcher only after its durable queue append.
# recover-unclaimed is a locked session-start recovery step: queued/claimed work
# without an outbox or live task link becomes pending so a restarted watcher
# offers it again, and stale task links to completed requests are cleared.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-portal-lib.sh
. "$SCRIPT_DIR/fm-portal-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

command=${1:-}
[ -n "$command" ] || { usage >&2; exit 2; }
shift
case "$command" in
  list) [ "$#" -eq 0 ] || { usage >&2; exit 2; } ;;
  read) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  mark-queued) [ "$#" -gt 0 ] || { usage >&2; exit 2; } ;;
  recover-unclaimed) [ "$#" -eq 0 ] || { usage >&2; exit 2; } ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

fmp_load_config || {
  echo 'fm-portal-request: connector configuration is unavailable' >&2
  exit 1
}
fmp_portal_prepare || {
  echo 'fm-portal-request: private portal state is unavailable' >&2
  exit 1
}

case "$command" in
  list)
    fm_lock_acquire_wait "$FMP_LOCK"
    id=$(fmp_oldest_open_id 2>/dev/null) || id=
    if [ -n "$id" ] && fmp_record_load "$id"; then
      case "$FMP_RECORD_STATE" in pending|queued|claimed) printf '%s\n' "$id" ;; esac
    fi
    fm_lock_release "$FMP_LOCK"
    ;;
  read)
    id=$1
    fmp_id_valid "$id" || { echo 'fm-portal-request: invalid message id' >&2; exit 2; }
    fm_lock_acquire_wait "$FMP_LOCK"
    oldest=$(fmp_oldest_open_id 2>/dev/null) || oldest=
    if [ "$oldest" != "$id" ]; then
      fm_lock_release "$FMP_LOCK"
      echo 'fm-portal-request: an earlier request must complete first' >&2
      exit 1
    fi
    if ! fmp_record_load "$id" || ! fmp_inbox_validate_file "$FMP_INBOX/$id.json" "$id"; then
      fm_lock_release "$FMP_LOCK"
      echo 'fm-portal-request: request is unavailable or invalid' >&2
      exit 1
    fi
    case "$FMP_RECORD_STATE" in
      pending|queued|claimed)
        now=$(fmp_now) || { fm_lock_release "$FMP_LOCK"; exit 1; }
        fmp_record_set_state "$id" claimed "" "$now" || {
          fm_lock_release "$FMP_LOCK"
          echo 'fm-portal-request: could not claim request' >&2
          exit 1
        }
        ;;
      *)
        fm_lock_release "$FMP_LOCK"
        echo 'fm-portal-request: request no longer needs direct handling' >&2
        exit 1
        ;;
    esac
    cat "$FMP_INBOX/$id.json"
    printf '\n'
    fm_lock_release "$FMP_LOCK"
    ;;
  mark-queued)
    fm_lock_acquire_wait "$FMP_LOCK"
    now=$(fmp_now) || { fm_lock_release "$FMP_LOCK"; exit 1; }
    for id in "$@"; do
      fmp_id_valid "$id" || { fm_lock_release "$FMP_LOCK"; exit 2; }
      fmp_record_load "$id" || { fm_lock_release "$FMP_LOCK"; exit 1; }
      case "$FMP_RECORD_STATE" in
        pending) fmp_record_set_state "$id" queued "" "$now" || { fm_lock_release "$FMP_LOCK"; exit 1; } ;;
        queued|claimed|linked|replying|complete) ;;
        conflict) ;;
      esac
    done
    fm_lock_release "$FMP_LOCK"
    ;;
  recover-unclaimed)
    fm_lock_acquire_wait "$FMP_LOCK"
    for file in "$FMP_RECORDS"/*.json; do
      [ -e "$file" ] || continue
      id=${file##*/}; id=${id%.json}
      fmp_id_valid "$id" || continue
      fmp_record_load "$id" || continue
      case "$FMP_RECORD_STATE" in
        queued|claimed)
          if fmp_outbox_load "$id" 2>/dev/null; then
            fmp_record_set_state "$id" replying "" 0 || { fm_lock_release "$FMP_LOCK"; exit 1; }
          else
            fmp_record_set_state "$id" pending "" 0 || { fm_lock_release "$FMP_LOCK"; exit 1; }
          fi
          ;;
        linked)
          task=$(fmp_task_for_request "$id" 2>/dev/null) || task=
          if [ -z "$task" ] || [ "$task" != "$FMP_RECORD_TASK" ]; then
            fmp_record_set_state "$id" pending "" 0 || { fm_lock_release "$FMP_LOCK"; exit 1; }
          fi
          ;;
        complete)
          # Convergence for a crash between durable completion and link
          # cleanup: a completed request must not keep any task bound to it.
          fmp_task_links_clear_for_request "$id" || { fm_lock_release "$FMP_LOCK"; exit 1; }
          ;;
      esac
    done
    fm_lock_release "$FMP_LOCK"
    ;;
esac
