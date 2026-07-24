#!/usr/bin/env bash
# Long-poll Telegram with the captain direct-message bot and durably queue captain DMs before advancing the offset.
#
# Usage:
#   fm-dm-listener.sh
#   fm-dm-listener.sh --once
#   fm-dm-listener.sh --check-config
#
# Session-independent replacement for a chat-session-coupled direct-message
# plugin poller: runs as a systemd user service (bin/fm-dm-service.sh) and
# reuses the topic-board store conventions from fm-topic-lib.sh against
# $FM_HOME/data/fm-telegram-dm (see docs/dm-line.md).
# The credential file is data/fm-telegram-dm/config.env with the same
# FM_TOPIC_BOT_TOKEN / FM_TOPIC_CAPTAIN_ID keys as the topic board.
#
# Telegram allows exactly ONE getUpdates consumer per bot token.
# While a direct-message plugin poller pid file names a live process, this
# listener logs and waits; it never kills the other consumer.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_DM_LIB_DIR="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}/bin"
export FM_TOPIC_DATA_DIR="${FM_DM_DATA_DIR:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/data/fm-telegram-dm}"
# shellcheck source=bin/fm-topic-lib.sh
. "$FM_DM_LIB_DIR/fm-topic-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_DM_LIB_DIR/fm-wake-lib.sh"

PLUGIN_PID_FILE="${FM_DM_PLUGIN_PID_FILE:-$HOME/.claude/channels/telegram/bot.pid}"
BOARD_DIR="${FM_DM_BOARD_DIR:-$FM_HOME/data/fm-telegram-topics}"

dm_log() {
  printf '%s fm-dm: %s\n' "$(date -Is)" "$*" >&2
}

# Inverse of fm_topic_assert_lifeline_separate: this service intentionally owns
# the direct-message token, but must never consume the topic-board bot's token.
dm_assert_board_separate() {
  local file line value
  for file in "$BOARD_DIR/config.env" "$BOARD_DIR/test-bot-token.txt"; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      case "$line" in
        FM_TOPIC_BOT_TOKEN=*|TEST_BOT_TOKEN=*) value=${line#*=} ;;
        *) continue ;;
      esac
      if [ -n "$value" ] && [ "$value" = "$FM_TOPIC_BOT_TOKEN" ]; then
        printf 'error: direct-message credentials match the topic-board bot; refusing to steal the board token\n' >&2
        return 1
      fi
    done < "$file"
  done
  return 0
}

dm_check_config() {
  command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; return 1; }
  command -v curl >/dev/null 2>&1 || { echo 'error: curl is required' >&2; return 1; }
  fm_topic_load_credentials || return 1
  dm_assert_board_separate || return 1
}

# A direct chat has no forum topics, so the reply path's map validation only
# needs a syntactically valid empty map; create it once so operators never do.
dm_ensure_map() {
  [ -e "$FM_TOPIC_MAP" ] || fm_topic_atomic_text "$FM_TOPIC_MAP" \
    "{\"chat_id\":\"$FM_TOPIC_CAPTAIN_ID\",\"topics\":{}}"
}

plugin_poller_alive() {
  local pid
  pid=$(cat "$PLUGIN_PID_FILE" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

MODE=loop
case "${1:-}" in
  '') ;;
  --once) MODE=once ;;
  --check-config) MODE=check ;;
  -h|--help)
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) echo "error: unknown argument: $1" >&2; exit 2 ;;
esac

dm_check_config || exit 1
[ "$MODE" = check ] && {
  printf 'ok: direct-message line config valid (credentials=%s)\n' "$FM_TOPIC_CONFIG_EFFECTIVE"
  exit 0
}

fm_topic_prepare_storage || exit 1
dm_ensure_map || exit 1
LISTENER_LOCK="$FM_TOPIC_LOCKS/listener.lock"
if ! fm_lock_try_acquire "$LISTENER_LOCK"; then
  printf 'error: another direct-message listener already owns %s (pid %s)\n' "$LISTENER_LOCK" "${FM_LOCK_HELD_PID:-unknown}" >&2
  exit 75
fi

listener_cleanup() {
  fm_lock_release "$LISTENER_LOCK"
}
trap listener_cleanup EXIT
trap 'exit 0' HUP INT TERM

POLL_TIMEOUT=${FM_DM_POLL_TIMEOUT:-25}
REMIND_SECONDS=${FM_DM_REMIND_SECONDS:-300}
WATCHER_GRACE=${FM_DM_WATCHER_GRACE:-300}
CONFLICT_WAIT=${FM_DM_CONFLICT_WAIT:-30}
WATCH_PATH="$FM_ROOT/bin/fm-watch.sh"
API="https://api.telegram.org/bot${FM_TOPIC_BOT_TOKEN}"

case "$POLL_TIMEOUT" in ''|*[!0-9]*) echo 'error: FM_DM_POLL_TIMEOUT must be a non-negative integer' >&2; exit 2 ;; esac
case "$REMIND_SECONDS" in ''|*[!0-9]*|0) echo 'error: FM_DM_REMIND_SECONDS must be a positive integer' >&2; exit 2 ;; esac
case "$CONFLICT_WAIT" in ''|*[!0-9]*|0) echo 'error: FM_DM_CONFLICT_WAIT must be a positive integer' >&2; exit 2 ;; esac

read_offset() {
  local offset
  if [ ! -e "$FM_TOPIC_OFFSET_FILE" ]; then
    printf '0\n'
    return 0
  fi
  offset=$(cat "$FM_TOPIC_OFFSET_FILE" 2>/dev/null) || return 1
  case "$offset" in
    ''|*[!0-9]*)
      printf 'error: durable Telegram offset is malformed: %s\n' "$FM_TOPIC_OFFSET_FILE" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$offset"
}

# Direct-message wakes ride the watcher's always-actionable topic-board queue
# key with a payload that names the direct-message inbox, so fm-watch.sh needs
# no new vocabulary (see docs/dm-line.md).
dm_wake_is_queued() {
  [ -s "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' '$3 == "check" && $4 == "topic-board" && $5 ~ /direct message/ { found=1 } END { exit(found ? 0 : 1) }' "$FM_WAKE_QUEUE"
}

last_wake_age() {
  local last now
  last=$(cat "$FM_TOPIC_LAST_WAKE" 2>/dev/null || true)
  case "$last" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  now=$(date +%s)
  printf '%s\n' "$((now - last))"
}

notify_firstmate() {
  local pending=$1 force_append=$2 reason pid
  reason="check: topic-board: ${pending} pending captain direct message(s) - run bin/fm-dm-inbox.sh list"
  if [ "$force_append" -eq 1 ] || ! dm_wake_is_queued; then
    fm_wake_append check topic-board "$reason" || return 1
  fi

  if fm_watcher_healthy "$STATE" "$WATCH_PATH" "$WATCHER_GRACE" "$FM_HOME"; then
    pid=$FM_WATCHER_HEALTHY_PID
    if kill -USR1 "$pid" 2>/dev/null; then
      fm_topic_atomic_text "$FM_TOPIC_LAST_WAKE" "$(date +%s)" || return 1
      dm_log "queued ${pending} pending direct message(s) and signaled watcher pid ${pid}"
      return 0
    fi
  fi
  dm_log "queued ${pending} pending direct message(s); no identity-verified watcher is ready yet"
  return 1
}

surface_pending_if_due() {
  local force_append=${1:-0} pending age
  pending=$(fm_topic_unanswered_count)
  [ "$pending" -gt 0 ] || return 0
  if [ "$force_append" -eq 1 ]; then
    notify_firstmate "$pending" 1 || true
    return 0
  fi
  age=$(last_wake_age)
  if [ "$age" -ge "$REMIND_SECONDS" ]; then
    notify_firstmate "$pending" 0 || true
  fi
}

item_already_persisted() {
  local update_id=$1 name path
  name=$(fm_topic_item_filename "$update_id") || return 1
  for path in "$FM_TOPIC_INBOX/$name" "$FM_TOPIC_ANSWERED/$name"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
      dm_log "refusing unsafe existing item path ${path}"
      return 2
    fi
    [ -f "$path" ] && return 0
  done
  return 1
}

message_content_type() {
  jq -r '
    if has("text") then "text"
    elif has("photo") then "photo"
    elif has("document") then "document"
    elif has("video") then "video"
    elif has("voice") then "voice"
    elif has("audio") then "audio"
    elif has("sticker") then "sticker"
    elif has("location") then "location"
    elif has("contact") then "contact"
    else "other"
    end
  '
}

persist_captain_dm() {
  local update_id=$1 message=$2 chat_id chat_type sender_id message_id text content_type destination existing_rc
  chat_id=$(printf '%s' "$message" | jq -r '.chat.id | tostring') || return 1
  chat_type=$(printf '%s' "$message" | jq -r '.chat.type // ""') || return 1
  sender_id=$(printf '%s' "$message" | jq -r '.from.id | tostring') || return 1
  if [ "$chat_type" != private ] || [ "$sender_id" != "$FM_TOPIC_CAPTAIN_ID" ] || [ "$chat_id" != "$FM_TOPIC_CAPTAIN_ID" ]; then
    dm_log "ignored update ${update_id} (chat ${chat_id} type ${chat_type:-none} sender ${sender_id}): not a captain direct message"
    return 2
  fi

  item_already_persisted "$update_id"
  existing_rc=$?
  case "$existing_rc" in
    0) return 3 ;;
    1) ;;
    *) return 1 ;;
  esac
  message_id=$(printf '%s' "$message" | jq -r '.message_id') || return 1
  text=$(printf '%s' "$message" | jq -r '.text // .caption // ""') || return 1
  content_type=$(printf '%s' "$message" | message_content_type) || return 1
  destination="$FM_TOPIC_INBOX/$(fm_topic_item_filename "$update_id")"

  jq -n \
    --argjson version 1 \
    --argjson update_id "$update_id" \
    --argjson message_id "$message_id" \
    --arg chat_id "$chat_id" \
    --arg from_id "$sender_id" \
    --arg content_type "$content_type" \
    --arg text "$text" \
    --arg received_at "$(fm_topic_now)" \
    --argjson telegram_message "$message" \
    '{
      version: $version,
      update_id: $update_id,
      message_id: $message_id,
      chat_id: $chat_id,
      thread_id: null,
      topic: "Direct message",
      project: "-",
      route: "main",
      from_id: $from_id,
      content_type: $content_type,
      text: $text,
      received_at: $received_at,
      status: "pending",
      telegram_message: $telegram_message
    }' | fm_topic_atomic_from_stdin "$destination"
}

poll_once() {
  local offset response rc max_update=-1 update update_id message persist_rc new=0
  if plugin_poller_alive; then
    dm_log "direct-message plugin poller is alive (pid file ${PLUGIN_PID_FILE}); waiting - one getUpdates consumer per token"
    return 2
  fi
  offset=$(read_offset) || return 1
  response=$(
    curl --silent --show-error --connect-timeout 10 --max-time "$((POLL_TIMEOUT + 15))" \
      --get "$API/getUpdates" \
      --data-urlencode "timeout=${POLL_TIMEOUT}" \
      --data-urlencode "offset=${offset}" \
      --data-urlencode 'limit=100' \
      --data-urlencode 'allowed_updates=["message"]'
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    dm_log "getUpdates transport failure (curl exit ${rc}); offset remains ${offset}"
    return 1
  fi
  if [ "$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    dm_log "getUpdates API failure: $(printf '%s' "$response" | jq -r '.description // "invalid JSON response"' 2>/dev/null)"
    return 1
  fi

  while IFS= read -r update; do
    [ -n "$update" ] || continue
    update_id=$(printf '%s' "$update" | jq -r '.update_id') || return 1
    case "$update_id" in ''|*[!0-9]*) dm_log 'getUpdates returned a malformed update_id'; return 1 ;; esac
    [ "$update_id" -gt "$max_update" ] && max_update=$update_id
    message=$(printf '%s' "$update" | jq -c '.message // empty') || return 1
    if [ -z "$message" ]; then
      dm_log "ignored non-message update ${update_id}"
      continue
    fi
    persist_captain_dm "$update_id" "$message"
    persist_rc=$?
    case "$persist_rc" in
      0) new=$((new + 1)) ;;
      2|3) ;;
      *) dm_log "failed to persist update ${update_id}; offset remains ${offset}"; return 1 ;;
    esac
  done < <(printf '%s' "$response" | jq -c '.result[]?')

  if [ "$max_update" -ge 0 ]; then
    fm_topic_atomic_text "$FM_TOPIC_OFFSET_FILE" "$((max_update + 1))" || {
      dm_log "failed to persist offset after update ${max_update}"
      return 1
    }
  fi

  if [ "$new" -gt 0 ]; then
    surface_pending_if_due 1
  else
    surface_pending_if_due 0
  fi
  return 0
}

surface_pending_if_due 0

if [ "$MODE" = once ]; then
  poll_once
  exit $?
fi

backoff=1
while :; do
  poll_once
  rc=$?
  case "$rc" in
    0) backoff=1 ;;
    2) sleep "$CONFLICT_WAIT" ;;
    *)
      sleep "$backoff"
      backoff=$((backoff * 2))
      [ "$backoff" -gt 30 ] && backoff=30
      ;;
  esac
done
