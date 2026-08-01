#!/usr/bin/env bash
# Long-poll Telegram with the dedicated topic-board bot and durably queue approved messages before advancing the offset.
#
# Usage:
#   fm-topic-listener.sh
#   fm-topic-listener.sh --once
#   fm-topic-listener.sh --check-config
#
# The default credential file is data/fm-telegram-topics/config.env, with the
# prototype's test-bot-token.txt accepted as a migration fallback.
# The listener never reads or uses the direct-message firstmate bot token.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-topic-lib.sh
. "$SCRIPT_DIR/fm-topic-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MODE=loop
case "${1:-}" in
  '') ;;
  --once) MODE=once ;;
  --check-config) MODE=check ;;
  -h|--help)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) echo "error: unknown argument: $1" >&2; exit 2 ;;
esac

fm_topic_check_config || exit 1
[ "$MODE" = check ] && {
  printf 'ok: topic board config valid (credentials=%s map=%s)\n' "$FM_TOPIC_CONFIG_EFFECTIVE" "$FM_TOPIC_MAP"
  exit 0
}

fm_topic_prepare_storage || exit 1
LISTENER_LOCK="$FM_TOPIC_LOCKS/listener.lock"
if ! fm_lock_try_acquire "$LISTENER_LOCK"; then
  printf 'error: another topic-board listener already owns %s (pid %s)\n' "$LISTENER_LOCK" "${FM_LOCK_HELD_PID:-unknown}" >&2
  exit 75
fi

listener_cleanup() {
  fm_lock_release "$LISTENER_LOCK"
}
trap listener_cleanup EXIT
trap 'exit 0' HUP INT TERM

CURL_BIN=${FM_TOPIC_CURL_BIN:-curl}
POLL_TIMEOUT=${FM_TOPIC_POLL_TIMEOUT:-25}
REMIND_SECONDS=${FM_TOPIC_REMIND_SECONDS:-300}
CLAIMED_REMIND_SECONDS=${FM_TOPIC_CLAIMED_REMIND_SECONDS:-14400}
WATCHER_GRACE=${FM_TOPIC_WATCHER_GRACE:-300}
WATCH_PATH="$FM_ROOT/bin/fm-watch.sh"
API="https://api.telegram.org/bot${FM_TOPIC_BOT_TOKEN}"

case "$POLL_TIMEOUT" in ''|*[!0-9]*) echo 'error: FM_TOPIC_POLL_TIMEOUT must be a non-negative integer' >&2; exit 2 ;; esac
case "$REMIND_SECONDS" in ''|*[!0-9]*|0) echo 'error: FM_TOPIC_REMIND_SECONDS must be a positive integer' >&2; exit 2 ;; esac
case "$CLAIMED_REMIND_SECONDS" in ''|*[!0-9]*|0) echo 'error: FM_TOPIC_CLAIMED_REMIND_SECONDS must be a positive integer' >&2; exit 2 ;; esac

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

topic_wake_is_queued() {
  [ -s "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' '$3 == "check" && $4 == "topic-board" { found=1 } END { exit(found ? 0 : 1) }' "$FM_WAKE_QUEUE"
}

notify_firstmate() {
  local pending=$1 force_append=$2 reason pid
  reason="check: topic-board: topic-message ${pending} unanswered"
  if [ "$force_append" -eq 1 ] || ! topic_wake_is_queued; then
    fm_wake_append check topic-board "$reason" || return 1
  fi

  if fm_watcher_healthy "$STATE" "$WATCH_PATH" "$WATCHER_GRACE" "$FM_HOME"; then
    pid=$FM_WATCHER_HEALTHY_PID
    if kill -USR1 "$pid" 2>/dev/null; then
      fm_topic_atomic_text "$FM_TOPIC_LAST_WAKE" "$(date +%s)" || return 1
      fm_topic_log "queued ${pending} unanswered item(s) and signaled watcher pid ${pid}"
      return 0
    fi
  fi
  fm_topic_log "queued ${pending} unanswered item(s); no identity-verified watcher is ready yet"
  return 1
}

surface_unanswered_if_due() {
  local force_append=${1:-0} pending age
  pending=$(fm_topic_unanswered_count "$CLAIMED_REMIND_SECONDS") || return 1
  [ "$pending" -gt 0 ] || return 0
  if [ "$force_append" -eq 1 ]; then
    notify_firstmate "$pending" 1 || true
    return 0
  fi
  age=$(fm_topic_last_wake_age)
  if [ "$age" -ge "$REMIND_SECONDS" ]; then
    notify_firstmate "$pending" 0 || true
  fi
}

item_already_persisted() {
  local update_id=$1 name path
  name=$(fm_topic_item_filename "$update_id") || return 1
  for path in "$FM_TOPIC_INBOX/$name" "$FM_TOPIC_ANSWERED/$name"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
      fm_topic_log "refusing unsafe existing item path ${path}"
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

persist_approved_message() {
  local update_id=$1 message=$2 chat_id sender_id chat_record group thread_id message_id topic_record topic project route text content_type destination existing_rc
  chat_id=$(printf '%s' "$message" | jq -r '.chat.id | tostring') || return 1
  sender_id=$(printf '%s' "$message" | jq -r '.from.id | tostring') || return 1
  [ "$sender_id" != "$FM_TOPIC_ANONYMOUS_ADMIN_ID" ] || {
    fm_topic_log "ignored update ${update_id} from Telegram anonymous-admin sender ${sender_id}"
    return 2
  }
  chat_record=$(fm_topic_chat_record "$chat_id") || return 1
  [ -n "$chat_record" ] || {
    fm_topic_log "ignored update ${update_id} from unconfigured chat ${chat_id}"
    return 2
  }
  fm_topic_sender_is_approved "$sender_id" || {
    fm_topic_log "ignored update ${update_id} from unapproved sender ${sender_id} in chat ${chat_id}"
    return 2
  }
  fm_topic_sender_is_approved_for_record "$sender_id" "$chat_record" || {
    fm_topic_log "ignored update ${update_id} from sender ${sender_id} not approved for chat ${chat_id}"
    return 2
  }
  group=$(printf '%s' "$chat_record" | jq -r '.group') || return 1

  thread_id=$(printf '%s' "$message" | jq -r '.message_thread_id // "null"') || return 1
  case "$thread_id" in null|*[!0-9]*) [ "$thread_id" = null ] || return 1 ;; esac
  topic_record=$(printf '%s' "$chat_record" | jq -c --arg thread "$thread_id" '.topics[$thread] // empty') || return 1
  if [ -n "$topic_record" ]; then
    topic=$(printf '%s' "$topic_record" | jq -r '.name')
    project=$(printf '%s' "$topic_record" | jq -r '.project')
    route=$(printf '%s' "$topic_record" | jq -r '.route')
  else
    topic="Unmapped topic ${thread_id}"
    project=Unmapped
    route=main
    fm_topic_log "approved update ${update_id} in chat ${chat_id} uses an unmapped thread ${thread_id}; retained for main routing"
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
    --argjson version 2 \
    --argjson update_id "$update_id" \
    --argjson message_id "$message_id" \
    --arg chat_id "$chat_id" \
    --arg group "$group" \
    --arg thread_id "$thread_id" \
    --arg topic "$topic" \
    --arg project "$project" \
    --arg route "$route" \
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
      group: $group,
      thread_id: (if $thread_id == "null" then null else ($thread_id | tonumber) end),
      topic: $topic,
      project: $project,
      route: $route,
      from_id: $from_id,
      content_type: $content_type,
      text: $text,
      received_at: $received_at,
      status: "pending",
      telegram_message: $telegram_message
    }' | fm_topic_atomic_from_stdin "$destination"
}

answer_callback_query() {
  local callback_id=$1 text=${2:-} response
  response=$("$CURL_BIN" --silent --show-error --connect-timeout 10 --max-time 20 \
    "$API/answerCallbackQuery" \
    --data-urlencode "callback_query_id=${callback_id}" \
    --data-urlencode "text=${text}" 2>&1) || {
      fm_topic_log "could not acknowledge callback query ${callback_id}: ${response}"
      return 1
    }
  if [ "$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    fm_topic_log "Telegram rejected callback acknowledgement ${callback_id}: $(printf '%s' "$response" | jq -r '.description // "unreadable response"' 2>/dev/null)"
    return 1
  fi
}

mark_decision_selected() {
  local intent=$1 choice_key=$2 label=$3
  jq --arg choice_key "$choice_key" --arg label "$label" --arg selected_at "$(fm_topic_now)" '
    .decision.status = "selected"
    | .decision.choice_key = $choice_key
    | .decision.label = $label
    | .decision.selected_at = $selected_at
  ' "$intent" | fm_topic_atomic_from_stdin "$intent"
}

show_decision_selection() {
  local intent=$1 chat_id=$2 message_id=$3 label=$4 text response
  text=$(jq -r '.text' "$intent") || return 1
  text="${text}"$'\n\n'"Selected: ${label}"
  response=$("$CURL_BIN" --silent --show-error --connect-timeout 10 --max-time 20 \
    "$API/editMessageText" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "message_id=${message_id}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "reply_markup={\"inline_keyboard\":[]}" 2>&1) || {
      fm_topic_log "could not show selected decision on message ${message_id}: ${response}"
      return 1
    }
  if [ "$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    fm_topic_log "Telegram rejected decision display edit for message ${message_id}: $(printf '%s' "$response" | jq -r '.description // "unreadable response"' 2>/dev/null)"
    return 1
  fi
}

persist_approved_callback() {
  local update_id=$1 callback=$2 callback_id sender_id data message chat_id thread_id message_id chat_record group topic_record topic project route token choice_key intent choice label destination existing_rc
  callback_id=$(printf '%s' "$callback" | jq -r '.id // empty') || return 1
  sender_id=$(printf '%s' "$callback" | jq -r '.from.id | tostring') || return 1
  data=$(printf '%s' "$callback" | jq -r '.data // empty') || return 1
  message=$(printf '%s' "$callback" | jq -c '.message // empty') || return 1
  [ -n "$callback_id" ] && [ -n "$data" ] && [ -n "$message" ] || {
    fm_topic_log "ignored malformed callback update ${update_id}"
    return 2
  }
  chat_id=$(printf '%s' "$message" | jq -r '.chat.id | tostring') || return 1
  message_id=$(printf '%s' "$message" | jq -r '.message_id') || return 1
  thread_id=$(printf '%s' "$message" | jq -r '.message_thread_id // "null"') || return 1
  case "$message_id" in ''|*[!0-9]*) fm_topic_log "ignored callback ${update_id} with malformed message id"; return 2 ;; esac
  case "$thread_id" in null|*[!0-9]*) [ "$thread_id" = null ] || return 1 ;; esac
  chat_record=$(fm_topic_chat_record "$chat_id") || return 1
  [ -n "$chat_record" ] || {
    fm_topic_log "ignored callback ${update_id} from unconfigured chat ${chat_id}"
    return 2
  }
  fm_topic_sender_is_approved "$sender_id" || {
    fm_topic_log "ignored callback ${update_id} from unapproved sender ${sender_id}"
    return 2
  }
  fm_topic_sender_is_approved_for_record "$sender_id" "$chat_record" || {
    fm_topic_log "ignored callback ${update_id} from sender ${sender_id} not approved for chat ${chat_id}"
    return 2
  }
  IFS=: read -r token choice_key <<< "$data"
  [ "$(fm_topic_callback_data "$token" "$choice_key" 2>/dev/null || true)" = "$data" ] || {
    fm_topic_log "ignored callback ${update_id} with an unknown callback token"
    return 2
  }
  intent=$(fm_topic_find_decision_intent "$token") || {
    fm_topic_log "ignored callback ${update_id} for an unknown decision token"
    return 2
  }
  choice=$(fm_topic_decision_choice "$intent" "$choice_key") || {
    fm_topic_log "ignored callback ${update_id} for an unknown decision choice"
    return 2
  }
  fm_topic_decision_already_recorded "$chat_id" "$message_id" "$token" && return 3
  jq -e \
    --arg chat_id "$chat_id" \
    --arg thread_id "$thread_id" \
    --argjson message_id "$message_id" '
      .status == "sent"
      and .decision.status == "open"
      and .decision.source_chat_id == $chat_id
      and .decision.source_message_id == $message_id
      and ((.decision.source_thread_id | if . == null then "null" else tostring end) == $thread_id)
    ' "$intent" >/dev/null 2>&1 || {
      fm_topic_log "ignored callback ${update_id} for a closed or mismatched decision"
      return 2
    }
  group=$(printf '%s' "$chat_record" | jq -r '.group') || return 1
  topic_record=$(printf '%s' "$chat_record" | jq -c --arg thread "$thread_id" '.topics[$thread] // empty') || return 1
  if [ -n "$topic_record" ]; then
    topic=$(printf '%s' "$topic_record" | jq -r '.name')
    project=$(printf '%s' "$topic_record" | jq -r '.project')
    route=$(printf '%s' "$topic_record" | jq -r '.route')
  else
    topic="Unmapped topic ${thread_id}"
    project=Unmapped
    route=main
  fi
  label=$(printf '%s' "$choice" | jq -r '.label') || return 1
  item_already_persisted "$update_id"
  existing_rc=$?
  case "$existing_rc" in
    0) return 3 ;;
    1) ;;
    *) return 1 ;;
  esac
  destination="$FM_TOPIC_INBOX/$(fm_topic_item_filename "$update_id")"
  jq -n \
    --argjson version 2 \
    --argjson update_id "$update_id" \
    --argjson message_id "$message_id" \
    --arg chat_id "$chat_id" \
    --arg group "$group" \
    --arg thread_id "$thread_id" \
    --arg topic "$topic" \
    --arg project "$project" \
    --arg route "$route" \
    --arg from_id "$sender_id" \
    --arg callback_id "$callback_id" \
    --arg callback_data "$data" \
    --arg token "$token" \
    --arg choice_key "$choice_key" \
    --arg label "$label" \
    --arg received_at "$(fm_topic_now)" \
    --argjson telegram_callback_query "$callback" '
      {
        version: $version,
        update_id: $update_id,
        message_id: $message_id,
        chat_id: $chat_id,
        group: $group,
        thread_id: (if $thread_id == "null" then null else ($thread_id | tonumber) end),
        topic: $topic,
        project: $project,
        route: $route,
        from_id: $from_id,
        content_type: "decision_tap",
        text: $label,
        received_at: $received_at,
        status: "pending",
        decision: {
          token: $token,
          choice_key: $choice_key,
          label: $label,
          callback_data: $callback_data,
          callback_query_id: $callback_id,
          source_chat_id: $chat_id,
          source_message_id: $message_id,
          source_thread_id: (if $thread_id == "null" then null else ($thread_id | tonumber) end)
        },
        telegram_callback_query: $telegram_callback_query
      }' | fm_topic_atomic_from_stdin "$destination" || return 1
  FM_TOPIC_CALLBACK_INTENT=$intent
  FM_TOPIC_CALLBACK_CHOICE_KEY=$choice_key
  FM_TOPIC_CALLBACK_LABEL=$label
  FM_TOPIC_CALLBACK_CHAT_ID=$chat_id
  FM_TOPIC_CALLBACK_MESSAGE_ID=$message_id
}

poll_once() {
  local offset response rc max_update=-1 update update_id message callback persist_rc new=0 callback_id
  offset=$(read_offset) || return 1
  response=$(
    "$CURL_BIN" --silent --show-error --connect-timeout 10 --max-time "$((POLL_TIMEOUT + 15))" \
      --get "$API/getUpdates" \
      --data-urlencode "timeout=${POLL_TIMEOUT}" \
      --data-urlencode "offset=${offset}" \
      --data-urlencode 'limit=100' \
      --data-urlencode 'allowed_updates=["message","callback_query"]'
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_topic_log "getUpdates transport failure (curl exit ${rc}); offset remains ${offset}"
    return 1
  fi
  if [ "$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    fm_topic_log "getUpdates API failure: $(printf '%s' "$response" | jq -r '.description // "invalid JSON response"' 2>/dev/null)"
    return 1
  fi

  while IFS= read -r update; do
    [ -n "$update" ] || continue
    update_id=$(printf '%s' "$update" | jq -r '.update_id') || return 1
    case "$update_id" in ''|*[!0-9]*) fm_topic_log 'getUpdates returned a malformed update_id'; return 1 ;; esac
    [ "$update_id" -gt "$max_update" ] && max_update=$update_id
    callback=$(printf '%s' "$update" | jq -c '.callback_query // empty') || return 1
    if [ -n "$callback" ]; then
      persist_approved_callback "$update_id" "$callback"
      persist_rc=$?
      callback_id=$(printf '%s' "$callback" | jq -r '.id // empty') || return 1
      case "$persist_rc" in
        0)
          answer_callback_query "$callback_id" 'Decision recorded' || true
          mark_decision_selected "$FM_TOPIC_CALLBACK_INTENT" "$FM_TOPIC_CALLBACK_CHOICE_KEY" "$FM_TOPIC_CALLBACK_LABEL" || return 1
          show_decision_selection "$FM_TOPIC_CALLBACK_INTENT" "$FM_TOPIC_CALLBACK_CHAT_ID" "$FM_TOPIC_CALLBACK_MESSAGE_ID" "$FM_TOPIC_CALLBACK_LABEL" || true
          new=$((new + 1))
          ;;
        2) answer_callback_query "$callback_id" 'This decision is no longer available' || true ;;
        3) answer_callback_query "$callback_id" 'Decision already recorded' || true ;;
        *) fm_topic_log "failed to persist callback update ${update_id}; offset remains ${offset}"; return 1 ;;
      esac
      continue
    fi
    message=$(printf '%s' "$update" | jq -c '.message // empty') || return 1
    if [ -z "$message" ]; then
      fm_topic_log "ignored non-message update ${update_id}"
      continue
    fi
    persist_approved_message "$update_id" "$message"
    persist_rc=$?
    case "$persist_rc" in
      0) new=$((new + 1)) ;;
      2|3) ;;
      *) fm_topic_log "failed to persist update ${update_id}; offset remains ${offset}"; return 1 ;;
    esac
  done < <(printf '%s' "$response" | jq -c '.result[]?')

  if [ "$max_update" -ge 0 ]; then
    fm_topic_atomic_text "$FM_TOPIC_OFFSET_FILE" "$((max_update + 1))" || {
      fm_topic_log "failed to persist offset after update ${max_update}"
      return 1
    }
  fi

  if [ "$new" -gt 0 ]; then
    surface_unanswered_if_due 1
  else
    surface_unanswered_if_due 0
  fi
  return 0
}

surface_unanswered_if_due 0

if [ "$MODE" = once ]; then
  poll_once
  exit $?
fi

backoff=1
while :; do
  if poll_once; then
    backoff=1
  else
    sleep "$backoff"
    backoff=$((backoff * 2))
    [ "$backoff" -gt 30 ] && backoff=30
  fi
done
