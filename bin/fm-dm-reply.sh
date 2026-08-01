#!/usr/bin/env bash
# Reply to a captain direct message through the direct-message bot, with the
# topic-board reply semantics (idempotent keyed intents, answered/ archive).
#
# Usage:
#   fm-dm-reply.sh <update-id> [--text-file <path>] [--follow-up <key>] [--confirm-sent] [--retry-unknown]
#       Same flags as fm-topic-reply.sh, against the direct-message store.
#   fm-dm-reply.sh send [--text-file <path>] [--buttons <key=label,...>]
#       Standalone message to the captain chat (announcements, no inbox item).
#       Text from --text-file or stdin; records outbox/send-<epoch>-<id>.json.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_DM_LIB_DIR="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}/bin"
export FM_TOPIC_DATA_DIR="${FM_DM_DATA_DIR:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/data/fm-telegram-dm}"
# The direct-message bot IS the captain lifeline: neutralize the topic-board
# lib's lifeline-separation guard, which exists to keep the TOPIC bot off this
# token; the listener's board-separation guard covers the inverse risk.
export FM_TOPIC_LIFELINE_CONFIG=/dev/null
unset TELEGRAM_BOT_TOKEN

if [ "${1:-}" != send ]; then
  exec "$FM_DM_LIB_DIR/fm-topic-reply.sh" "$@"
fi
shift

# shellcheck source=bin/fm-topic-lib.sh
. "$FM_DM_LIB_DIR/fm-topic-lib.sh"

text_file=
buttons_spec=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file)
      [ "$#" -ge 2 ] || { echo 'error: --text-file requires a path' >&2; exit 2; }
      text_file=$2
      shift 2
      ;;
    --buttons)
      [ "$#" -ge 2 ] || { echo 'error: --buttons requires key=label entries' >&2; exit 2; }
      buttons_spec=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fm_topic_load_credentials
fm_topic_prepare_storage
if [ -n "$text_file" ]; then
  [ -f "$text_file" ] && [ ! -L "$text_file" ] || { echo "error: text file is missing, not regular, or a symlink: $text_file" >&2; exit 1; }
  text=$(cat "$text_file")
else
  text=$(cat)
fi
[ -n "$text" ] || { echo 'error: message text is empty' >&2; exit 1; }

decision_token=
buttons_json=null
reply_markup=
if [ -n "$buttons_spec" ]; then
  buttons_json=$(fm_topic_parse_buttons "$buttons_spec") || exit 2
  decision_token=$(fm_topic_decision_token "dm-send:$(date +%s):$$")
  reply_markup=$(jq -cn --arg token "$decision_token" --argjson buttons "$buttons_json" '
    {inline_keyboard: [$buttons | map({text: .label, callback_data: ($token + ":" + .key)})]}
  ') || exit 1
fi

if [ -z "$reply_markup" ]; then
  response=$(
    curl --silent --show-error --connect-timeout 10 --max-time 35 \
      "https://api.telegram.org/bot${FM_TOPIC_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${FM_TOPIC_CAPTAIN_ID}" \
      --data-urlencode "text=${text}"
  )
else
  response=$(
    curl --silent --show-error --connect-timeout 10 --max-time 35 \
      "https://api.telegram.org/bot${FM_TOPIC_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${FM_TOPIC_CAPTAIN_ID}" \
      --data-urlencode "text=${text}" \
      --data-urlencode "reply_markup=${reply_markup}"
  )
fi
if [ "$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
  printf 'error: Telegram did not accept the message: %s\n' \
    "$(printf '%s' "$response" | jq -r '.description // "unreadable response"' 2>/dev/null)" >&2
  exit 1
fi
message_id=$(printf '%s' "$response" | jq -r '.result.message_id')
jq -n \
  --argjson message_id "$message_id" \
  --arg text "$text" \
  --arg sent_at "$(fm_topic_now)" \
  --arg chat_id "$FM_TOPIC_CAPTAIN_ID" \
  --arg decision_token "$decision_token" \
  --argjson buttons "$buttons_json" \
  '{version: 1, kind: "standalone-send", message_id: $message_id, text: $text, sent_at: $sent_at, status: "sent"}
  | if $decision_token == "" then . else . + {decision: {
      token: $decision_token,
      buttons: $buttons,
      source_chat_id: $chat_id,
      source_message_id: $message_id,
      source_thread_id: null,
      status: "open"
    }} end' \
  | fm_topic_atomic_from_stdin "$FM_TOPIC_OUTBOX/send-$(date +%s)-${message_id}.json"
printf 'ok: message %s sent to captain chat\n' "$message_id"
