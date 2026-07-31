#!/usr/bin/env bash
# Run one bounded Telegram Bot API long poll for the private captain bridge.
#
# The poll is inert unless config/telegram/bridge.json is complete, enabled,
# owner-only mode 0600, regular, single-link, and exact for one user/chat.
# Every update with a usable update_id gets a minimal durable disposition before
# the local offset can advance.
# Accepted text is durably stored under state/telegram/inbox first, then queued
# into Firstmate's existing wake path under an exact correlation ID.
# Re-entry recovers persisted-but-not-queued requests idempotently.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if ! fmtg_load_config; then
  if [ "$FMTG_CONFIG_STATUS" = invalid ]; then
    fmtg_error_once config-invalid || true
  fi
  exit 0
fi

command -v curl >/dev/null 2>&1 || { fmtg_error_once missing-curl || true; exit 0; }
command -v jq >/dev/null 2>&1 || { fmtg_error_once missing-jq || true; exit 0; }
fmtg_prepare_state || { fmtg_error_once unsafe-state || true; exit 0; }
fmtg_prune || { fmtg_error_once retention-failed || true; exit 0; }

QUEUED=0
recover_pending_requests() {
  local file request_id rc
  for file in "$FMTG_STATE/inbox"/*.json; do
    [ -e "$file" ] || continue
    fm_private_file_valid "$file" 600 || { fmtg_error_once unsafe-inbox || true; continue; }
    request_id=$(basename "$file" .json)
    fmtg_queue_request "$request_id"
    rc=$?
    case "$rc" in
      0) QUEUED=$((QUEUED + 1)) ;;
      1) ;;
      *) fmtg_error_once wake-publication-failed || true ;;
    esac
  done
}
recover_pending_requests

OFFSET=$(fmtg_offset_read) || { fmtg_error_once offset-invalid || true; exit 0; }
PAYLOAD=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-poll.XXXXXX") || exit 0
BODY=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-poll-body.XXXXXX") || { rm -f -- "$PAYLOAD"; exit 0; }
UPDATE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-update.XXXXXX") || { rm -f -- "$PAYLOAD" "$BODY"; exit 0; }
chmod 0600 "$PAYLOAD" "$BODY" "$UPDATE" || { rm -f -- "$PAYLOAD" "$BODY" "$UPDATE"; exit 0; }
trap 'rm -f -- "$PAYLOAD" "$BODY" "$UPDATE"' EXIT

jq -n --argjson offset "$OFFSET" --argjson timeout "$FMTG_POLL_TIMEOUT" \
  '{offset:$offset,timeout:$timeout,limit:20,allowed_updates:["message","edited_message"]}' > "$PAYLOAD" \
  || exit 0

if ! fmtg_api_call getUpdates "$PAYLOAD" "$BODY" "$FMTG_CURL_TIMEOUT"; then
  fmtg_error_once poll-transport-uncertain || true
  exit 0
fi
case "$FMTG_API_HTTP" in
  200) ;;
  401|403) fmtg_error_once poll-authorization-rejected || true; exit 0 ;;
  409) fmtg_error_once webhook-or-competing-poller || true; exit 0 ;;
  429) fmtg_error_once poll-rate-limited || true; exit 0 ;;
  *) fmtg_error_once "poll-http-$FMTG_API_HTTP" || true; exit 0 ;;
esac

if ! jq -e '
  .ok == true
  and (.result | type == "array")
  and ([.result[].update_id] | all(type == "number" and floor == . and . >= 0 and . <= 9007199254740991))
  and ([.result[].update_id] as $ids | ($ids == ($ids | sort)) and (($ids | unique | length) == ($ids | length)))
' "$BODY" >/dev/null 2>&1; then
  fmtg_error_once response-order-or-shape-invalid || true
  exit 0
fi

write_journal() { # <update-id> <disposition> [request-id]
  local update_id=$1 disposition=$2 request_id=${3:-} now
  now=$(date +%s)
  jq -n --arg update_id "$update_id" --arg disposition "$disposition" \
    --arg request_id "$request_id" --argjson at "$now" '
      {schema:"firstmate.telegram-update.v1",update_id:$update_id,disposition:$disposition,persisted_at:$at}
      + (if $request_id == "" then {} else {request_id:$request_id} end)
    ' | fmtg_json_publish "$FMTG_STATE/updates" "$update_id.json"
}

process_update() {
  local update_id journal raw disposition request_id next user_id chat_id chat_type is_bot
  local message_id text_bytes text_chars reply_id approval_candidate approval_id approval_decision approval_intent
  local now inbox_json rc
  update_id=$(jq -r '.update_id | tostring' "$UPDATE") || return 1
  journal="$FMTG_STATE/updates/$update_id.json"

  if [ "$update_id" -lt "$OFFSET" ]; then
    if ! fm_private_file_valid "$journal" 600; then
      fmtg_error_once replay-without-receipt || true
    fi
    return 0
  fi

  if fm_private_file_valid "$journal" 600; then
    raw=$(fm_private_read_file "$journal" 600) || return 1
    disposition=$(printf '%s' "$raw" | jq -r '.disposition // empty')
    request_id=$(printf '%s' "$raw" | jq -r '.request_id // empty')
    next=$((update_id + 1))
    fmtg_offset_write "$next" || return 1
    OFFSET=$next
    if [ "$disposition" = accepted ] && [ -n "$request_id" ]; then
      fmtg_queue_request "$request_id"
      rc=$?
      [ "$rc" -ne 0 ] || QUEUED=$((QUEUED + 1))
      [ "$rc" -ne 2 ] || return 1
    fi
    return 0
  fi

  disposition=malformed
  request_id=
  if jq -e 'has("edited_message")' "$UPDATE" >/dev/null 2>&1; then
    disposition=edited-message
  elif ! jq -e '.message | type == "object"' "$UPDATE" >/dev/null 2>&1; then
    disposition=unsupported-update
  elif ! jq -e '
    (.message.message_id | type == "number" and floor == . and . > 0 and . <= 9007199254740991)
    and (.message.from.id | type == "number" and floor == . and . > 0 and . <= 9007199254740991)
    and (.message.from.is_bot | type == "boolean")
    and (.message.chat.id | type == "number" and floor == . and . > 0 and . <= 9007199254740991)
    and (.message.chat.type | type == "string")
  ' "$UPDATE" >/dev/null 2>&1; then
    disposition=malformed
  else
    user_id=$(jq -r '(.message.from.id? // empty) | tostring' "$UPDATE" 2>/dev/null)
    chat_id=$(jq -r '(.message.chat.id? // empty) | tostring' "$UPDATE" 2>/dev/null)
    chat_type=$(jq -r '.message.chat.type? // empty' "$UPDATE" 2>/dev/null)
    is_bot=$(jq -r '.message.from.is_bot? // false' "$UPDATE" 2>/dev/null)
    if [ "$user_id" != "$FMTG_ALLOWED_USER_ID" ] \
      || [ "$chat_id" != "$FMTG_ALLOWED_CHAT_ID" ] \
      || [ "$chat_type" != private ] \
      || [ "$is_bot" != false ]; then
      disposition=unauthorized
    elif jq -e '.message | has("photo") or has("document") or has("audio") or has("video") or has("voice") or has("video_note") or has("sticker") or has("animation") or has("contact") or has("location") or has("venue") or has("poll") or has("dice") or has("web_app_data")' "$UPDATE" >/dev/null 2>&1; then
      disposition=unsupported-media
    elif ! jq -e '.message.text | type == "string" and length > 0' "$UPDATE" >/dev/null 2>&1; then
      disposition=empty-or-nontext
    else
      text_bytes=$(jq -j '.message.text' "$UPDATE" | LC_ALL=C wc -c | tr -d ' ')
      text_chars=$(jq -r '.message.text | length' "$UPDATE")
      if [ "$text_bytes" -gt "$FMTG_MAX_INBOUND_BYTES" ] || [ "$text_chars" -gt 4096 ]; then
        disposition=oversized
      else
        message_id=$(jq -r '.message.message_id? | tostring // empty' "$UPDATE")
        case "$message_id" in ''|*[!0-9]*) disposition=malformed ;;
          *) disposition=accepted ;;
        esac
      fi
    fi
  fi

  if [ "$disposition" = accepted ]; then
    request_id="tg-$update_id-$message_id"
    fmtg_safe_slug "$request_id" 96 || return 1
    FMTG_INBOUND_TEXT=$(jq -j '.message.text' "$UPDATE")
    approval_id=
    approval_decision=
    approval_intent=false
    reply_id=$(jq -r '.message.reply_to_message.message_id? | tostring // empty' "$UPDATE")
    case "$FMTG_INBOUND_TEXT" in
      /approve\ *|/deny\ *)
        approval_intent=true
        approval_candidate=${FMTG_INBOUND_TEXT#* }
        if fmtg_approval_binding "$approval_candidate" "$reply_id" "$request_id"; then
          approval_id=$approval_candidate
          approval_decision=$FMTG_APPROVAL_DECISION
        fi
        ;;
    esac
    now=$(date +%s)
    inbox_json=$(jq \
      --arg request_id "$request_id" \
      --arg approval_id "$approval_id" \
      --arg approval_decision "$approval_decision" \
      --argjson approval_intent "$approval_intent" \
      --argjson received_at "$now" '
        {
          schema:"firstmate.telegram-request.v1",
          request_id:$request_id,
          update_id:(.update_id|tostring),
          telegram_message_id:.message.message_id,
          reply_to_message_id:(.message.reply_to_message.message_id // null),
          text:.message.text,
          approval_intent:$approval_intent,
          approval_id:(if $approval_id == "" then null else $approval_id end),
          approval_decision:(if $approval_decision == "" then null else $approval_decision end),
          received_at:$received_at,
          wake_queued:false,
          wake_state:"idle",
          wake_state_at:0,
          wake_offer_count:0
        }
      ' "$UPDATE") || return 1
    if [ -e "$FMTG_STATE/inbox/$request_id.json" ] || [ -L "$FMTG_STATE/inbox/$request_id.json" ]; then
      fm_private_file_valid "$FMTG_STATE/inbox/$request_id.json" 600 || return 1
    else
      printf '%s\n' "$inbox_json" | fmtg_json_publish "$FMTG_STATE/inbox" "$request_id.json" || return 1
    fi
    write_journal "$update_id" accepted "$request_id" || return 1
  else
    write_journal "$update_id" "$disposition" || return 1
  fi

  if [ "${FMTG_TEST_CRASH_AFTER_PERSIST:-0}" = 1 ]; then
    exit 91
  fi

  next=$((update_id + 1))
  fmtg_offset_write "$next" || return 1
  OFFSET=$next
  if [ "$disposition" = accepted ]; then
    fmtg_queue_request "$request_id"
    rc=$?
    case "$rc" in
      0) QUEUED=$((QUEUED + 1)) ;;
      1) ;;
      *) return 1 ;;
    esac
  fi
}

COUNT=$(jq -r '.result | length' "$BODY")
INDEX=0
while [ "$INDEX" -lt "$COUNT" ]; do
  jq ".result[$INDEX]" "$BODY" > "$UPDATE" || { fmtg_error_once response-read-failed || true; exit 0; }
  if ! process_update; then
    fmtg_error_once state-commit-failed || true
    exit 0
  fi
  INDEX=$((INDEX + 1))
done

fmtg_clear_error
if [ "$QUEUED" -gt 0 ]; then
  printf 'telegram-requests %s\n' "$QUEUED"
fi
