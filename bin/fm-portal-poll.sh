#!/usr/bin/env bash
# One bounded poll of the authenticated AI Department portal message endpoint.
#
# Inert by default: if config/portal-connector.json is absent, exit 0 without
# output or writes. A valid poll validates a bounded batch, atomically stashes
# each captain message under state/portal/, advances an endpoint-bound monotonic
# cursor only after durable publication, and prints one body-free line:
#   portal-message <id> [<id> ...]
# Any incomplete idempotent reply transaction is resumed before fetching.
# Errors print one deduplicated body-free `portal-error <code>` line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/portal-connector.json"

# A truly absent configuration is a hard no-op, including no state directory.
[ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ] || exit 0

# shellcheck source=bin/fm-portal-lib.sh
. "$SCRIPT_DIR/fm-portal-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if ! fmp_load_config "$CONFIG_FILE"; then
  fmp_error_emit_once "config-$FMP_CONFIG_ERROR"
  exit 0
fi
command -v curl >/dev/null 2>&1 || { fmp_error_emit_once missing-curl; exit 0; }
command -v jq >/dev/null 2>&1 || { fmp_error_emit_once missing-jq; exit 0; }
fmp_portal_prepare || { fmp_error_emit_once state-unavailable; exit 0; }

batch=${FM_PORTAL_BATCH_SIZE:-$FMP_DEFAULT_BATCH}
case "$batch" in ''|*[!0-9]*|0) batch=$FMP_DEFAULT_BATCH ;; esac
[ "$batch" -le "$FMP_DEFAULT_BATCH" ] || batch=$FMP_DEFAULT_BATCH
lease=${FM_PORTAL_CLAIM_LEASE_SECS:-$FMP_DEFAULT_CLAIM_LEASE_SECS}
case "$lease" in ''|*[!0-9]*) lease=$FMP_DEFAULT_CLAIM_LEASE_SECS ;; esac
[ "$lease" -le 86400 ] || lease=86400

response=$(umask 077; mktemp "$FMP_PORTAL_DIR/.poll-response.XXXXXX") || {
  fmp_error_emit_once state-unavailable
  exit 0
}
message_tmp=$(umask 077; mktemp "$FMP_PORTAL_DIR/.poll-message.XXXXXX") || {
  rm -f "$response"
  fmp_error_emit_once state-unavailable
  exit 0
}
cleanup() { rm -f "$response" "$message_tmp"; }
trap cleanup EXIT HUP INT TERM

# Resume any crash-interrupted response/ack transaction using its already
# durable body and stable idempotency key. Do not hold the portal record lock
# while the reply helper performs bounded network I/O. The whole directory is
# validated in one pass; per-record work below runs only for the rare states.
resume_ids=
fm_lock_acquire_wait "$FMP_LOCK"
now=$(fmp_now) || now=0
records=$(fmp_records_scan) || {
  fm_lock_release "$FMP_LOCK"
  fmp_error_emit_once record-invalid
  exit 0
}
oldest_state=
while IFS=$'\t' read -r id state claimed_at record_task; do
  [ -n "$id" ] || continue
  effective=$state
  case "$state" in
    replying)
      if fmp_outbox_load "$id"; then
        case "$FMP_OUTBOX_STATE" in
          pending|posted) ;;
          complete) fmp_record_set_state "$id" complete "" 0 && effective=complete || true ;;
          conflict) fmp_record_set_state "$id" conflict "" 0 && effective=conflict || true ;;
        esac
      else
        fm_lock_release "$FMP_LOCK"
        fmp_error_emit_once outbox-invalid
        exit 0
      fi
      ;;
    queued)
      # A queued record is only a durable watcher notification that no agent
      # has picked up; re-offering it after the lease cannot duplicate work.
      case "$claimed_at" in ''|*[!0-9]*) claimed_at=0 ;; esac
      if [ "$now" -ge "$claimed_at" ] && [ $((now - claimed_at)) -ge "$lease" ]; then
        fmp_record_set_state "$id" pending "" 0 || {
          fm_lock_release "$FMP_LOCK"
          fmp_error_emit_once record-write-failed
          exit 0
        }
        effective=pending
      fi
      ;;
    claimed)
      # Claimed work is being actively handled; elapsed time alone is no proof
      # the handler died, and re-offering it would execute the request twice.
      # Only the locked session-start recover-unclaimed step may reclaim it.
      ;;
    linked)
      task=$(fmp_task_for_request "$id" 2>/dev/null) || task=
      if [ -z "$task" ] || [ "$task" != "$record_task" ]; then
        fmp_record_set_state "$id" pending "" 0 || {
          fm_lock_release "$FMP_LOCK"
          fmp_error_emit_once record-write-failed
          exit 0
        }
        effective=pending
      fi
      ;;
    conflict)
      fm_lock_release "$FMP_LOCK"
      fmp_error_emit_once "reply-conflict:$id"
      exit 0
      ;;
  esac
  if [ -z "$oldest_state" ] && [ "$effective" != complete ]; then
    oldest_state=$effective
    [ "$effective" = replying ] && resume_ids=$id
  fi
done <<< "$records"
fm_lock_release "$FMP_LOCK"

resume_failed=
for id in $resume_ids; do
  "$SCRIPT_DIR/fm-portal-reply.sh" --resume "$id" >/dev/null 2>/dev/null
  resume_rc=$?
  case "$resume_rc" in
    0|5) ;;
    *) resume_failed=$id; break ;;
  esac
done

fm_lock_acquire_wait "$FMP_LOCK"
fmp_prune_completed
if ! fmp_cursor_load "$FMP_BASE_URL"; then
  fm_lock_release "$FMP_LOCK"
  fmp_error_emit_once cursor-invalid
  exit 0
fi
cursor=$FMP_CURSOR_ID
fm_lock_release "$FMP_LOCK"

url="$FMP_BASE_URL/api/integration/messages?after_id=$cursor&limit=$batch"
: > "$response"
if ! fmp_http_request GET "$url" "$response"; then
  if [ -n "$resume_failed" ]; then
    fmp_error_emit_once "reply-retry:$resume_failed"
  else
    fmp_error_emit_once "poll-$FMP_HTTP_ERROR"
  fi
  exit 0
fi
case "$FMP_HTTP_CODE" in
  200) ;;
  400|401|403|404|409|503) fmp_error_emit_once "poll-http-$FMP_HTTP_CODE"; exit 0 ;;
  *) fmp_error_emit_once poll-http-unexpected; exit 0 ;;
esac

if ! jq -e --argjson cursor "$cursor" --argjson batch "$batch" \
  --argjson max_id "$FMP_MAX_ID" --argjson max_chars "$FMP_MAX_MESSAGE_CHARS" '
  type == "object" and (keys | sort) == ["last_id", "messages"]
  and (.messages | type == "array" and length <= $batch)
  and (.messages | all(
    type == "object" and (keys | sort) == ["body", "created_at", "id"]
    and (.id | type == "number" and floor == . and . > $cursor and . <= $max_id)
    and (.body | type == "string" and length > 0 and length <= $max_chars)
    and (.created_at | type == "string" and length > 0 and length <= 128)
  ))
  and ([.messages[].id] as $ids | all(range(1; $ids|length); $ids[.] > $ids[.-1]))
  and (.last_id | type == "number" and floor == . and . >= $cursor and . <= $max_id)
  and (.last_id == (if (.messages|length) > 0 then .messages[-1].id else $cursor end))
' "$response" >/dev/null 2>&1; then
  fmp_error_emit_once poll-invalid-response
  exit 0
fi

# Publish each validated message before advancing the cursor. Existing bytes for
# the same id must match exactly; a changed replay is corruption, never an update.
if ! (
  set -o pipefail
  jq -c '.messages[]' "$response" | while IFS= read -r object; do
    id=$(printf '%s' "$object" | jq -r '.id')
    printf '%s\n' "$object" > "$message_tmp" || exit 1
    hash=$(fmp_sha256_file "$message_tmp") || exit 1
    fm_lock_acquire_wait "$FMP_LOCK"
    publish_rc=0
    cat "$message_tmp" | fmp_publish_once "$FMP_INBOX" "$id.json" || publish_rc=$?
    case "$publish_rc" in
      0) ;;
      1) cmp -s "$message_tmp" "$FMP_INBOX/$id.json" || { fm_lock_release "$FMP_LOCK"; exit 1; } ;;
      *) fm_lock_release "$FMP_LOCK"; exit 1 ;;
    esac
    fmp_inbox_validate_file "$FMP_INBOX/$id.json" "$id" || { fm_lock_release "$FMP_LOCK"; exit 1; }
    fmp_record_create_once "$id" "$hash"
    record_rc=$?
    case "$record_rc" in 0|1) ;; *) fm_lock_release "$FMP_LOCK"; exit 1 ;; esac
    fm_lock_release "$FMP_LOCK"
  done
); then
  fmp_error_emit_once inbox-write-failed
  exit 0
fi

last_id=$(jq -r '.last_id' "$response")
fm_lock_acquire_wait "$FMP_LOCK"
if [ "$last_id" -gt "$cursor" ] && ! fmp_cursor_store "$FMP_BASE_URL" "$last_id"; then
  fm_lock_release "$FMP_LOCK"
  fmp_error_emit_once cursor-write-failed
  exit 0
fi

# Only pending records need an agent turn. queued has already produced a durable
# watcher notification, claimed is actively handled, linked belongs to a task,
# and replying is resumed automatically above.
pending=
oldest=$(fmp_oldest_open_id 2>/dev/null) || oldest=
if [ -n "$oldest" ]; then
  fmp_record_load "$oldest" || { fm_lock_release "$FMP_LOCK"; fmp_error_emit_once record-invalid; exit 0; }
  if [ "$FMP_RECORD_STATE" = pending ]; then
    pending=" $oldest"
  fi
fi
fm_lock_release "$FMP_LOCK"

if [ -n "$pending" ]; then
  fmp_error_clear
  # shellcheck disable=SC2086 # IDs are validated decimal tokens.
  printf 'portal-message%s\n' "$pending"
elif [ -n "$resume_failed" ]; then
  fmp_error_emit_once "reply-retry:$resume_failed"
else
  fmp_error_clear
fi
