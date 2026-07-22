#!/usr/bin/env bash
# Complete one durable portal response transaction.
#
# Usage:
#   fm-portal-reply.sh <captain-message-id> --text-file <path>
#   fm-portal-reply.sh <captain-message-id> -
#   fm-portal-reply.sh --resume <captain-message-id>
#
# A new response is normalized and atomically stored with one random stable
# Idempotency-Key before network I/O. Every retry reuses that exact record.
# HTTP 201 (new) and 200 (same-key replay) must return the same valid stored
# message identity. Only after that result is durably recorded does the helper
# POST /api/integration/ack; an ambiguous post or ack is retried safely.
# Success prints only the originating numeric id. Errors never print credentials
# or either message body.
#
# Deterministic test crash seams (never used by production callers):
# FM_PORTAL_TEST_CRASH_AFTER_OUTBOX, _AFTER_POST, _AFTER_POST_RECORD, _AFTER_ACK.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-portal-lib.sh
. "$SCRIPT_DIR/fm-portal-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

resume=0
text_file=
if [ "${1:-}" = --resume ]; then
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  resume=1
  id=$2
else
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  id=$1
  shift
  case "${1:-}" in
    --text-file)
      [ "$#" -eq 2 ] || { usage >&2; exit 2; }
      text_file=$2
      ;;
    -)
      [ "$#" -eq 1 ] || { usage >&2; exit 2; }
      text_file=-
      ;;
    *) usage >&2; exit 2 ;;
  esac
fi
fmp_id_valid "$id" || { echo 'fm-portal-reply: invalid captain message id' >&2; exit 2; }
fmp_load_config || { echo 'fm-portal-reply: connector configuration is unavailable' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'fm-portal-reply: curl not found' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'fm-portal-reply: jq not found' >&2; exit 1; }
fmp_portal_prepare || { echo 'fm-portal-reply: private portal state is unavailable' >&2; exit 1; }

raw=$(umask 077; mktemp "$FMP_PORTAL_DIR/.reply-raw.XXXXXX") || exit 1
normalized=$(umask 077; mktemp "$FMP_PORTAL_DIR/.reply-normalized.XXXXXX") || { rm -f "$raw"; exit 1; }
payload=$(umask 077; mktemp "$FMP_PORTAL_DIR/.reply-payload.XXXXXX") || { rm -f "$raw" "$normalized"; exit 1; }
response=$(umask 077; mktemp "$FMP_PORTAL_DIR/.reply-response.XXXXXX") || { rm -f "$raw" "$normalized" "$payload"; exit 1; }
cleanup() {
  rm -f -- "$raw" "$normalized" "$payload" "$response"
  fm_lock_release "$FMP_LOCK" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

if [ "$resume" -eq 0 ]; then
  if [ "$text_file" = - ]; then
    cat > "$raw" || { echo 'fm-portal-reply: could not read reply from stdin' >&2; exit 1; }
  else
    [ -f "$text_file" ] && [ ! -L "$text_file" ] || {
      echo 'fm-portal-reply: reply text file is unavailable' >&2
      exit 1
    }
    cat -- "$text_file" > "$raw" || { echo 'fm-portal-reply: could not read reply text file' >&2; exit 1; }
  fi
  if ! jq -jRs 'gsub("^[[:space:]]+|[[:space:]]+$"; "")' "$raw" > "$normalized"; then
    echo 'fm-portal-reply: could not normalize reply text' >&2
    exit 1
  fi
  if ! jq -Rs -e --argjson max "$FMP_MAX_MESSAGE_CHARS" \
    'length > 0 and length <= $max and (explode | all(. != 0))' "$normalized" >/dev/null; then
    echo "fm-portal-reply: reply must contain 1-$FMP_MAX_MESSAGE_CHARS characters" >&2
    exit 2
  fi
fi

# A durably complete request must not keep any task bound to it; a deferred
# acknowledgement (exit 5) skips fm-portal-followup.sh's cleanup, so every
# completion path here clears the matching link itself, under the held lock.
clear_completed_task_link() {
  fmp_task_links_clear_for_request "$id" || {
    echo 'fm-portal-reply: response completed but task link cleanup failed' >&2
    exit 1
  }
}

fm_lock_acquire_wait "$FMP_LOCK"
if ! fmp_record_load "$id" || ! fmp_inbox_validate_file "$FMP_INBOX/$id.json" "$id"; then
  echo 'fm-portal-reply: originating request is unavailable or invalid' >&2
  exit 1
fi
case "$FMP_RECORD_STATE" in complete) clear_completed_task_link; printf '%s\n' "$id"; exit 0 ;; conflict) echo 'fm-portal-reply: idempotency conflict requires operator recovery' >&2; exit 4 ;; esac

if [ "$resume" -eq 0 ]; then
  fmp_outbox_create_once "$id" "$normalized"
  create_rc=$?
  case "$create_rc" in
    0|1) ;;
    *) echo 'fm-portal-reply: a different durable reply already exists for this request' >&2; exit 3 ;;
  esac
fi
if ! fmp_outbox_load "$id"; then
  echo 'fm-portal-reply: durable reply record is unavailable or invalid' >&2
  exit 1
fi
case "$FMP_OUTBOX_STATE" in
  complete)
    fmp_record_set_state "$id" complete "" 0 || exit 1
    clear_completed_task_link
    printf '%s\n' "$id"
    exit 0
    ;;
  conflict)
    fmp_record_set_state "$id" conflict "" 0 || true
    echo 'fm-portal-reply: idempotency conflict requires operator recovery' >&2
    exit 4
    ;;
esac
fmp_record_set_state "$id" replying "" 0 || {
  echo 'fm-portal-reply: could not record response progress' >&2
  exit 1
}

if [ "${FM_PORTAL_TEST_CRASH_AFTER_OUTBOX:-0}" = 1 ]; then exit 99; fi

outbox="$FMP_OUTBOX/$id.json"
if [ "$FMP_OUTBOX_STATE" = pending ]; then
  jq -c '{body:.body}' "$outbox" > "$payload" || {
    echo 'fm-portal-reply: could not build response payload' >&2
    exit 1
  }
  key=$(jq -r '.idempotency_key' "$outbox") || exit 1
  : > "$response"
  if ! fmp_http_request POST "$FMP_BASE_URL/api/integration/messages" "$response" "$payload" "$key"; then
    echo "fm-portal-reply: response request failed ($FMP_HTTP_ERROR)" >&2
    exit 1
  fi
  if [ "$FMP_HTTP_CODE" = 409 ]; then
    fmp_outbox_set_state "$id" conflict null || true
    fmp_record_set_state "$id" conflict "" 0 || true
    echo 'fm-portal-reply: portal rejected the stable idempotency key as conflicting' >&2
    exit 4
  fi
  case "$FMP_HTTP_CODE" in
    200|201) ;;
    400|401|403|404|503) echo "fm-portal-reply: portal returned HTTP $FMP_HTTP_CODE" >&2; exit 1 ;;
    *) echo 'fm-portal-reply: portal returned an unexpected HTTP status' >&2; exit 1 ;;
  esac
  if ! jq -e --slurpfile outbox "$outbox" --argjson max "$FMP_MAX_ID" '
    type == "object" and (keys | sort) == ["message"]
    and (.message | type == "object")
    and ((.message | keys) - ["id","created_at","body","direction","read_at","delivered_at"] | length == 0)
    and (.message.id | type == "number" and floor == . and . > 0 and . <= $max)
    and (.message.created_at | type == "string" and length > 0 and length <= 128)
    and ((.message.body == null) or (.message.body == $outbox[0].body))
    and ((.message.direction == null) or (.message.direction == "inbound"))
  ' "$response" >/dev/null 2>&1; then
    echo 'fm-portal-reply: portal returned an invalid response object' >&2
    exit 1
  fi
  portal_message_id=$(jq -r '.message.id' "$response") || exit 1
  if [ "${FM_PORTAL_TEST_CRASH_AFTER_POST:-0}" = 1 ]; then exit 99; fi
  fmp_outbox_set_state "$id" posted "$portal_message_id" || {
    echo 'fm-portal-reply: could not durably confirm the posted response' >&2
    exit 1
  }
  if [ "${FM_PORTAL_TEST_CRASH_AFTER_POST_RECORD:-0}" = 1 ]; then exit 99; fi
else
  portal_message_id=$FMP_OUTBOX_MESSAGE_ID
  fmp_id_valid "$portal_message_id" || {
    echo 'fm-portal-reply: posted response identity is invalid' >&2
    exit 1
  }
fi

# The acknowledgement endpoint is cumulative, so a later request may not ack
# past an earlier unfinished one. Keep this durable post in `posted` and let the
# poller's oldest-first recovery resume it after the prior request completes.
if fmp_prior_request_incomplete "$id"; then
  echo 'fm-portal-reply: response posted; waiting for an earlier portal request before acknowledgement' >&2
  exit 5
fi

# The portal acknowledgement is intentionally last. It is itself idempotent;
# an acknowledged:0 response is valid after a lost prior success response.
jq -cn --argjson id "$id" '{last_id:$id}' > "$payload" || exit 1
: > "$response"
if ! fmp_http_request POST "$FMP_BASE_URL/api/integration/ack" "$response" "$payload"; then
  echo "fm-portal-reply: acknowledgement request failed ($FMP_HTTP_ERROR)" >&2
  exit 1
fi
[ "$FMP_HTTP_CODE" = 200 ] || {
  echo "fm-portal-reply: acknowledgement returned HTTP $FMP_HTTP_CODE" >&2
  exit 1
}
if ! jq -e 'type == "object" and (keys | sort) == ["acknowledged"] and (.acknowledged | type == "number" and floor == . and . >= 0)' \
  "$response" >/dev/null 2>&1; then
  echo 'fm-portal-reply: portal returned an invalid acknowledgement' >&2
  exit 1
fi
if [ "${FM_PORTAL_TEST_CRASH_AFTER_ACK:-0}" = 1 ]; then exit 99; fi
fmp_outbox_set_state "$id" complete "$portal_message_id" || {
  echo 'fm-portal-reply: could not record completed acknowledgement' >&2
  exit 1
}
fmp_record_set_state "$id" complete "" 0 || {
  echo 'fm-portal-reply: could not complete the local request record' >&2
  exit 1
}
clear_completed_task_link
printf '%s\n' "$id"
