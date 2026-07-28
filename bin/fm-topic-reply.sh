#!/usr/bin/env bash
# Send an idempotently keyed reply into an item's originating Telegram topic and archive the item after its initial answer.
#
# Usage:
#   fm-topic-reply.sh <update-id> [--text-file <path>]
#   fm-topic-reply.sh <update-id> --follow-up <key> [--text-file <path>]
#   fm-topic-reply.sh <update-id> [--follow-up <key>] --confirm-sent
#   fm-topic-reply.sh <update-id> [--follow-up <key>] --retry-unknown [--text-file <path>]
#
# Text comes from --text-file or stdin.
# A crash after Telegram may have accepted a send leaves an ambiguous intent that
# will not be retried until --confirm-sent or --retry-unknown is chosen explicitly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-topic-lib.sh
. "$SCRIPT_DIR/fm-topic-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
item_id=$1
shift
reply_key=initial
text_file=
confirm_sent=0
retry_unknown=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file)
      [ "$#" -gt 1 ] || { echo 'error: --text-file requires a path' >&2; exit 2; }
      text_file=$2
      shift 2
      ;;
    --follow-up)
      [ "$#" -gt 1 ] || { echo 'error: --follow-up requires a stable key' >&2; exit 2; }
      reply_key=$2
      shift 2
      ;;
    --confirm-sent) confirm_sent=1; shift ;;
    --retry-unknown) retry_unknown=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$reply_key" in ''|*[!A-Za-z0-9._-]*) echo 'error: reply key must use letters, digits, dot, underscore, or dash' >&2; exit 2 ;; esac
[ "$confirm_sent" -eq 0 ] || [ "$retry_unknown" -eq 0 ] || { echo 'error: choose only one of --confirm-sent or --retry-unknown' >&2; exit 2; }

fm_topic_check_config
fm_topic_prepare_storage
item=$(fm_topic_any_item "$item_id") || { echo "error: topic item not found: $item_id" >&2; exit 1; }
fm_topic_validate_item_origin "$item" || {
  printf 'error: topic item has an invalid or unsafe origin: %s\n' "$item_id" >&2
  exit 1
}
update_id=$(jq -r '.update_id' "$item")
chat_id=$(jq -r '.chat_id' "$item")
thread_id=$(jq -r '.thread_id // "null"' "$item")
group=$(jq -r '.group // ""' "$item")
from_id=$(jq -r '.from_id // ""' "$item")
intent="$FM_TOPIC_OUTBOX/update-${update_id}-${reply_key}.json"
if [ -L "$intent" ] || { [ -e "$intent" ] && [ ! -f "$intent" ]; }; then
  printf 'error: reply intent path is not a regular non-symlink file: %s\n' "$intent" >&2
  exit 1
fi
if [ -f "$intent" ] && jq -e 'has("origin")' "$intent" >/dev/null 2>&1; then
  jq -e \
    --arg chat_id "$chat_id" \
    --arg thread_id "$thread_id" \
    --arg group "$group" \
    --arg from_id "$from_id" '
    .origin.chat_id == $chat_id
    and ((.origin.thread_id | if . == null then "null" else tostring end) == $thread_id)
    and ((.origin.group // "") == $group)
    and ((.origin.from_id // "") == $from_id)
  ' "$intent" >/dev/null 2>&1 || {
    printf 'error: reply intent origin does not match topic item %s\n' "$update_id" >&2
    exit 1
  }
fi
reply_lock="$FM_TOPIC_LOCKS/reply-${update_id}-${reply_key}.lock"
if ! fm_lock_try_acquire "$reply_lock"; then
  printf 'error: reply %s for update %s is already in progress\n' "$reply_key" "$update_id" >&2
  exit 75
fi
cleanup_reply_lock() {
  fm_lock_release "$reply_lock"
}
trap cleanup_reply_lock EXIT

finalize_initial_answer() {
  local pending answered
  [ "$reply_key" = initial ] || return 0
  pending=$(fm_topic_pending_item "$update_id" 2>/dev/null || true)
  [ -n "$pending" ] || return 0
  answered="$FM_TOPIC_ANSWERED/$(fm_topic_item_filename "$update_id")"
  if [ -L "$answered" ] || { [ -e "$answered" ] && [ ! -f "$answered" ]; }; then
    printf 'error: answered-item path is not a regular non-symlink file: %s\n' "$answered" >&2
    return 1
  fi
  jq --arg answered_at "$(fm_topic_now)" --arg intent_file "$(basename "$intent")" \
    '.status = "answered" | .answered_at = $answered_at | .initial_reply_intent = $intent_file' "$pending" \
    | fm_topic_atomic_from_stdin "$pending"
  mv -f "$pending" "$answered"
  fm_topic_sync_path "$FM_TOPIC_ANSWERED"
}

mark_intent() {
  local status=$1 note=${2:-}
  jq --arg status "$status" --arg changed_at "$(fm_topic_now)" --arg note "$note" '
    .status = $status
    | .changed_at = $changed_at
    | if $note == "" then del(.note) else .note = $note end
  ' "$intent" | fm_topic_atomic_from_stdin "$intent"
}

if [ "$confirm_sent" -eq 1 ]; then
  [ -f "$intent" ] || { echo 'error: no reply intent exists to confirm' >&2; exit 1; }
  intent_status=$(jq -r '.status' "$intent")
  case "$intent_status" in
    sending|delivery_unknown) ;;
    sent)
      finalize_initial_answer
      printf 'ok: reply %s for update %s was already recorded as sent\n' "$reply_key" "$update_id"
      exit 0
      ;;
    *) printf 'error: reply intent status %s is not ambiguous and cannot be manually confirmed\n' "$intent_status" >&2; exit 1 ;;
  esac
  jq --arg sent_at "$(fm_topic_now)" '
    .status = "sent"
    | .sent_at = $sent_at
    | .confirmed_manually = true
    | .changed_at = $sent_at
  ' "$intent" | fm_topic_atomic_from_stdin "$intent"
  finalize_initial_answer
  printf 'ok: reply %s for update %s marked sent after manual confirmation\n' "$reply_key" "$update_id"
  exit 0
fi

if [ -n "$text_file" ]; then
  [ -f "$text_file" ] && [ ! -L "$text_file" ] || { echo "error: text file is missing, not regular, or a symlink: $text_file" >&2; exit 1; }
  text=$(cat "$text_file")
else
  text=$(cat)
fi
[ -n "$text" ] || { echo 'error: reply text is empty' >&2; exit 1; }
text_hash=$(printf '%s' "$text" | fm_topic_hash)

if [ -f "$intent" ]; then
  recorded_hash=$(jq -r '.text_sha256' "$intent")
  [ "$recorded_hash" = "$text_hash" ] || {
    printf 'error: reply key %s already belongs to different text for update %s\n' "$reply_key" "$update_id" >&2
    exit 1
  }
  intent_status=$(jq -r '.status' "$intent")
  case "$intent_status" in
    sent)
      finalize_initial_answer
      printf 'ok: reply %s for update %s was already sent; no duplicate was sent\n' "$reply_key" "$update_id"
      exit 0
      ;;
    sending|delivery_unknown)
      [ "$retry_unknown" -eq 1 ] || {
        printf 'error: reply %s for update %s may already have reached Telegram; inspect the topic, then use --confirm-sent or --retry-unknown\n' "$reply_key" "$update_id" >&2
        exit 1
      }
      mark_intent prepared 'explicit retry after ambiguous delivery'
      ;;
    prepared|failed) ;;
    *) printf 'error: unknown reply intent status: %s\n' "$intent_status" >&2; exit 1 ;;
  esac
else
  jq -n \
    --argjson version 2 \
    --argjson update_id "$update_id" \
    --arg reply_key "$reply_key" \
    --arg text "$text" \
    --arg text_sha256 "$text_hash" \
    --arg chat_id "$chat_id" \
    --arg thread_id "$thread_id" \
    --arg group "$group" \
    --arg from_id "$from_id" \
    --arg prepared_at "$(fm_topic_now)" \
    '{
      version: $version,
      update_id: $update_id,
      reply_key: $reply_key,
      text: $text,
      text_sha256: $text_sha256,
      origin: {
        chat_id: $chat_id,
        thread_id: (if $thread_id == "null" then null else ($thread_id | tonumber) end),
        group: (if $group == "" then null else $group end),
        from_id: (if $from_id == "" then null else $from_id end)
      },
      prepared_at: $prepared_at,
      changed_at: $prepared_at,
      status: "prepared"
    }' | fm_topic_atomic_from_stdin "$intent"
fi

mark_intent sending
CURL_BIN=${FM_TOPIC_CURL_BIN:-curl}
API="https://api.telegram.org/bot${FM_TOPIC_BOT_TOKEN}"
curl_args=(
  --silent
  --show-error
  --connect-timeout 10
  --max-time 35
  "$API/sendMessage"
  --data-urlencode "chat_id=${chat_id}"
  --data-urlencode "text=${text}"
)
[ "$thread_id" = null ] || curl_args+=(--data-urlencode "message_thread_id=${thread_id}")

set +e
response=$("$CURL_BIN" "${curl_args[@]}")
curl_rc=$?
set -e
if [ "$curl_rc" -ne 0 ]; then
  mark_intent delivery_unknown "curl exit ${curl_rc}"
  printf 'error: Telegram delivery result is unknown for update %s; automatic retry is disabled\n' "$update_id" >&2
  exit 1
fi
if ! printf '%s' "$response" | jq -e 'type == "object" and has("ok")' >/dev/null 2>&1; then
  mark_intent delivery_unknown 'Telegram returned an unreadable response'
  printf 'error: Telegram delivery result is unknown for update %s; automatic retry is disabled\n' "$update_id" >&2
  exit 1
fi
if [ "$(printf '%s' "$response" | jq -r '.ok')" != true ]; then
  description=$(printf '%s' "$response" | jq -r '.description // "Telegram rejected the request"')
  mark_intent failed "$description"
  printf 'error: Telegram did not accept reply for update %s: %s\n' "$update_id" "$description" >&2
  exit 1
fi

telegram_message_id=$(printf '%s' "$response" | jq -r '.result.message_id')
telegram_thread_id=$(printf '%s' "$response" | jq -r '.result.message_thread_id // "null"')
jq --arg sent_at "$(fm_topic_now)" \
  --arg message_id "$telegram_message_id" \
  --arg thread_id "$telegram_thread_id" '
  .status = "sent"
  | .sent_at = $sent_at
  | .changed_at = $sent_at
  | .telegram_message_id = ($message_id | tonumber)
  | .telegram_thread_id = (if $thread_id == "null" then null else ($thread_id | tonumber) end)
  | del(.note)
' "$intent" | fm_topic_atomic_from_stdin "$intent"
finalize_initial_answer
printf 'ok: reply %s for update %s sent into topic thread %s\n' "$reply_key" "$update_id" "$thread_id"
