#!/usr/bin/env bash
# Shared paths, validation, atomic persistence, and item lookup for the Telegram topic board.

FM_TOPIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_TOPIC_DEFAULT_ROOT="$(cd "$FM_TOPIC_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_TOPIC_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_TOPIC_DATA_DIR="${FM_TOPIC_DATA_DIR:-$FM_HOME/data/fm-telegram-topics}"
FM_TOPIC_MAP="${FM_TOPIC_MAP:-$FM_TOPIC_DATA_DIR/topic-map.json}"
FM_TOPIC_INBOX="$FM_TOPIC_DATA_DIR/inbox"
FM_TOPIC_ANSWERED="$FM_TOPIC_DATA_DIR/answered"
FM_TOPIC_OUTBOX="$FM_TOPIC_DATA_DIR/outbox"
FM_TOPIC_LOCKS="$FM_TOPIC_DATA_DIR/locks"
FM_TOPIC_OFFSET_FILE="${FM_TOPIC_OFFSET_FILE:-$FM_TOPIC_DATA_DIR/.poll-offset}"
# shellcheck disable=SC2034 # Shared with fm-topic-listener.sh after sourcing.
FM_TOPIC_LAST_WAKE="$FM_TOPIC_DATA_DIR/.last-wake"
FM_TOPIC_ANONYMOUS_ADMIN_ID=1087968824

fm_topic_log() {
  printf '%s fm-topic: %s\n' "$(date -Is)" "$*" >&2
}

fm_topic_prepare_storage() {
  local directory
  umask 077
  mkdir -p "$FM_TOPIC_DATA_DIR" "$FM_TOPIC_INBOX" "$FM_TOPIC_ANSWERED" "$FM_TOPIC_OUTBOX" "$FM_TOPIC_LOCKS" "$STATE"
  for directory in "$FM_TOPIC_DATA_DIR" "$FM_TOPIC_INBOX" "$FM_TOPIC_ANSWERED" "$FM_TOPIC_OUTBOX" "$FM_TOPIC_LOCKS" "$STATE"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || {
      printf 'error: topic-board storage path is not a real directory: %s\n' "$directory" >&2
      return 1
    }
  done
  chmod 700 "$FM_TOPIC_DATA_DIR" "$FM_TOPIC_INBOX" "$FM_TOPIC_ANSWERED" "$FM_TOPIC_OUTBOX" "$FM_TOPIC_LOCKS" 2>/dev/null || true
}

fm_topic_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_topic_require_private_file() {
  local file=$1 mode perm
  [ -f "$file" ] && [ ! -L "$file" ] || {
    printf 'error: required private file is missing, not regular, or a symlink: %s\n' "$file" >&2
    return 1
  }
  mode=$(fm_topic_file_mode "$file") || {
    printf 'error: cannot inspect private file permissions: %s\n' "$file" >&2
    return 1
  }
  case "$mode" in
    ''|*[!0-7]*)
      printf 'error: invalid permission mode for private file %s: %s\n' "$file" "$mode" >&2
      return 1
      ;;
  esac
  perm=$((8#$mode))
  if [ $((perm & 077)) -ne 0 ]; then
    printf 'error: private file must not be readable or writable by group/other: %s (mode %s)\n' "$file" "$mode" >&2
    return 1
  fi
}

fm_topic_select_config() {
  if [ -n "${FM_TOPIC_CONFIG:-}" ]; then
    printf '%s\n' "$FM_TOPIC_CONFIG"
  elif [ -f "$FM_TOPIC_DATA_DIR/config.env" ]; then
    printf '%s\n' "$FM_TOPIC_DATA_DIR/config.env"
  else
    printf '%s\n' "$FM_TOPIC_DATA_DIR/test-bot-token.txt"
  fi
}

fm_topic_load_credentials() {
  local config line key value token='' captain='' additional_senders='' approved sender
  local -a sender_ids=()
  config=$(fm_topic_select_config)
  fm_topic_require_private_file "$config" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *)
        printf 'error: malformed topic-board credential line in %s\n' "$config" >&2
        return 1
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      FM_TOPIC_BOT_TOKEN|TEST_BOT_TOKEN) token=$value ;;
      FM_TOPIC_CAPTAIN_ID|CAPTAIN_CHAT_ID) captain=$value ;;
      FM_TOPIC_APPROVED_SENDER_IDS) additional_senders=$value ;;
      *)
        printf 'error: unsupported key in topic-board credential file: %s\n' "$key" >&2
        return 1
        ;;
    esac
  done < "$config"

  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || {
    printf 'error: topic-board bot token is missing or malformed in %s\n' "$config" >&2
    return 1
  }
  [[ "$captain" =~ ^[0-9]+$ ]] || {
    printf 'error: captain Telegram user id is missing or malformed in %s\n' "$config" >&2
    return 1
  }
  [ "$captain" != "$FM_TOPIC_ANONYMOUS_ADMIN_ID" ] || {
    printf 'error: Telegram anonymous-admin sender id %s cannot be approved in %s\n' "$captain" "$config" >&2
    return 1
  }
  if [ -n "$additional_senders" ]; then
    [[ "$additional_senders" =~ ^[0-9]+(,[0-9]+)*$ ]] || {
      printf 'error: approved Telegram sender ids are malformed in %s\n' "$config" >&2
      return 1
    }
    IFS=',' read -r -a sender_ids <<< "$additional_senders"
  fi

  approved=$captain
  for sender in "${sender_ids[@]}"; do
    [[ "$sender" =~ ^[0-9]+$ ]] || {
      printf 'error: approved Telegram sender ids are malformed in %s\n' "$config" >&2
      return 1
    }
    [ "$sender" != "$FM_TOPIC_ANONYMOUS_ADMIN_ID" ] || {
      printf 'error: Telegram anonymous-admin sender id %s cannot be approved in %s\n' "$sender" "$config" >&2
      return 1
    }
    case ",$approved," in
      *",$sender,"*) ;;
      *) approved="${approved},${sender}" ;;
    esac
  done

  FM_TOPIC_BOT_TOKEN=$token
  FM_TOPIC_CAPTAIN_ID=$captain
  FM_TOPIC_APPROVED_SENDER_IDS=$approved
  FM_TOPIC_CONFIG_EFFECTIVE=$config
  export FM_TOPIC_BOT_TOKEN FM_TOPIC_CAPTAIN_ID FM_TOPIC_APPROVED_SENDER_IDS FM_TOPIC_CONFIG_EFFECTIVE
}

fm_topic_assert_lifeline_separate() {
  local lifeline_file=${FM_TOPIC_LIFELINE_CONFIG:-$HOME/.claude/channels/telegram/.env} line key value lifeline_token=${TELEGRAM_BOT_TOKEN:-}
  if [ -z "$lifeline_token" ] && [ -f "$lifeline_file" ] && [ ! -L "$lifeline_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      case "$line" in
        TELEGRAM_BOT_TOKEN=*)
          key=${line%%=*}
          value=${line#*=}
          case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
          esac
          [ "$key" = TELEGRAM_BOT_TOKEN ] && lifeline_token=$value
          ;;
      esac
    done < "$lifeline_file"
  fi
  if [ -n "$lifeline_token" ] && [ "$lifeline_token" = "$FM_TOPIC_BOT_TOKEN" ]; then
    printf 'error: topic-board credentials match the direct-message bot; refusing to risk the captain lifeline\n' >&2
    return 1
  fi
}

fm_topic_validate_map() {
  [ -f "$FM_TOPIC_MAP" ] && [ ! -L "$FM_TOPIC_MAP" ] || {
    printf 'error: topic map is missing, not regular, or a symlink: %s\n' "$FM_TOPIC_MAP" >&2
    return 1
  }
  jq -e \
    --arg approved ",${FM_TOPIC_APPROVED_SENDER_IDS}," \
    --arg anonymous "$FM_TOPIC_ANONYMOUS_ADMIN_ID" '
    def valid_topics:
      type == "object"
      and all(.[];
        (.name | type == "string" and length > 0)
        and (.project | type == "string" and length > 0)
        and (.route | type == "string" and length > 0)
      );
    def valid_sender:
      . as $sender
      | type == "string"
        and test("^[0-9]+$")
        and . != $anonymous
        and ($approved | contains("," + $sender + ","));
    if has("chats") then
      (has("chat_id") | not)
      and (has("group") | not)
      and (has("topics") | not)
      and (.chats | type == "object" and length > 0)
      and all(.chats | to_entries[];
        (.key | test("^-?[0-9]+$"))
        and (.value.group | type == "string" and length > 0)
        and (.value.approved_sender_ids | type == "array" and length > 0)
        and all(.value.approved_sender_ids[]; valid_sender)
        and (.value.topics | valid_topics)
      )
    else
      (.chat_id | (type == "string" or type == "number") and (tostring | test("^-?[0-9]+$")))
      and ((has("group") | not) or (.group | type == "string" and length > 0))
      and (.topics | valid_topics)
    end
  ' "$FM_TOPIC_MAP" >/dev/null 2>&1 || {
    printf 'error: topic map has an invalid schema: %s\n' "$FM_TOPIC_MAP" >&2
    return 1
  }
}

fm_topic_sender_is_approved() {
  local sender_id=$1
  [[ "$sender_id" =~ ^[0-9]+$ ]] || return 1
  [ "$sender_id" != "$FM_TOPIC_ANONYMOUS_ADMIN_ID" ] || return 1
  case ",${FM_TOPIC_APPROVED_SENDER_IDS}," in
    *",$sender_id,"*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_topic_chat_record() {
  local chat_id=$1
  jq -c --arg chat "$chat_id" '
    if has("chats") then
      .chats[$chat] // empty
    elif (.chat_id | tostring) == $chat then
      {
        group: (.group // ("Telegram chat " + $chat)),
        approved_sender_ids: null,
        topics: .topics
      }
    else
      empty
    end
  ' "$FM_TOPIC_MAP"
}

fm_topic_sender_is_approved_for_record() {
  local sender_id=$1 chat_record=$2
  printf '%s' "$chat_record" | jq -e --arg sender "$sender_id" '
    .approved_sender_ids == null or (.approved_sender_ids | index($sender) != null)
  ' >/dev/null 2>&1
}

fm_topic_validate_item_origin() {
  jq -e '
    (.chat_id | type == "string" and test("^-?[0-9]+$"))
    and (
      .thread_id == null
      or (
        (.thread_id | type == "number")
        and .thread_id >= 0
        and .thread_id == (.thread_id | floor)
      )
    )
    and (
      (has("from_id") | not)
      or (.from_id | type == "string" and test("^[0-9]+$"))
    )
    and (
      (has("group") | not)
      or (.group | type == "string" and length > 0)
    )
  ' "$1" >/dev/null 2>&1
}

fm_topic_check_config() {
  command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; return 1; }
  command -v "${FM_TOPIC_CURL_BIN:-curl}" >/dev/null 2>&1 || { echo 'error: curl is required' >&2; return 1; }
  fm_topic_load_credentials || return 1
  fm_topic_assert_lifeline_separate || return 1
  fm_topic_validate_map || return 1
}

fm_topic_sync_path() {
  if sync -f "$1" 2>/dev/null; then
    return 0
  fi
  sync
}

fm_topic_atomic_from_stdin() {
  local destination=$1 directory base tmp
  if [ -e "$destination" ] && { [ ! -f "$destination" ] || [ -L "$destination" ]; }; then
    printf 'error: atomic destination is not a regular non-symlink file: %s\n' "$destination" >&2
    return 1
  fi
  directory=$(dirname "$destination")
  base=$(basename "$destination")
  mkdir -p "$directory" || return 1
  tmp=$(mktemp "$directory/.${base}.tmp.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! fm_topic_sync_path "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
  fm_topic_sync_path "$directory"
}

fm_topic_atomic_text() {
  local destination=$1 value=$2
  printf '%s\n' "$value" | fm_topic_atomic_from_stdin "$destination"
}

fm_topic_item_filename() {
  local update_id=$1
  case "$update_id" in
    update-*.json) update_id=${update_id#update-}; update_id=${update_id%.json} ;;
    update-*) update_id=${update_id#update-} ;;
  esac
  case "$update_id" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf 'update-%s.json\n' "$update_id"
}

fm_topic_pending_item() {
  local name
  name=$(fm_topic_item_filename "$1") || return 1
  [ -f "$FM_TOPIC_INBOX/$name" ] && [ ! -L "$FM_TOPIC_INBOX/$name" ] || return 1
  printf '%s\n' "$FM_TOPIC_INBOX/$name"
}

fm_topic_any_item() {
  local name
  name=$(fm_topic_item_filename "$1") || return 1
  if [ -f "$FM_TOPIC_INBOX/$name" ] && [ ! -L "$FM_TOPIC_INBOX/$name" ]; then
    printf '%s\n' "$FM_TOPIC_INBOX/$name"
    return 0
  fi
  if [ -f "$FM_TOPIC_ANSWERED/$name" ] && [ ! -L "$FM_TOPIC_ANSWERED/$name" ]; then
    printf '%s\n' "$FM_TOPIC_ANSWERED/$name"
    return 0
  fi
  return 1
}

fm_topic_last_wake_age() {
  local last now
  last=$(cat "$FM_TOPIC_LAST_WAKE" 2>/dev/null || true)
  case "$last" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  now=$(date +%s)
  printf '%s\n' "$((now - last))"
}

fm_topic_unanswered_count() {
  local claimed_remind_seconds=${1:-14400} wake_age item status count=0
  case "$claimed_remind_seconds" in ''|*[!0-9]*|0) return 2 ;; esac

  wake_age=$(fm_topic_last_wake_age)
  # Pending items retain the normal cadence; claimed items reappear every four
  # hours by default, so active work stays quiet without being silenced forever.
  for item in "$FM_TOPIC_INBOX"/update-*.json; do
    [ -f "$item" ] && [ ! -L "$item" ] || continue
    status=$(jq -r '.status // empty' "$item" 2>/dev/null) || continue
    case "$status" in
      pending) count=$((count + 1)) ;;
      claimed)
        [ "$wake_age" -ge "$claimed_remind_seconds" ] && count=$((count + 1))
        ;;
    esac
  done
  printf '%s\n' "$count"
}

fm_topic_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

fm_topic_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}
