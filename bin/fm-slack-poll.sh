#!/usr/bin/env bash
# Poll the configured Slack captain channel for new captain messages.
#
# Inert unless FM_SLACK_BOT_TOKEN and config/slack-captain-channel are both set.
# The watcher invokes this trusted repository script only after
# state/slack-watch.check.sh matches the expected byte-static identity shim.
# Contract: output => wake firstmate, silence => keep sleeping.
#
# Reads exclusively the configured channel id via conversations.history and
# conversations.replies. Never calls conversations.list or any discovery API.
# Each newly offered captain message is stashed at state/slack-inbox/<ts>.json,
# acknowledged once in-thread with a fixed constant, then wakes firstmate once
# with: slack-captain-message <ts><TAB><text>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-slack-lib.sh
. "$SCRIPT_DIR/fm-slack-lib.sh"

fms_load_config
fms_configured || exit 0

ERROR_FILE="$STATE/slack-poll.error"

emit_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$STATE" "slack-poll.error" 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$STATE" "slack-poll.error" 600 2>/dev/null || true
  printf 'slack-captain-error %s\n' "$msg"
}

clear_error() {
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

fms_bot_user_id_load "$STATE" || { emit_error_once "auth.test failed"; exit 0; }
clear_error

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-poll.XXXXXX") || exit 0
MSG_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-poll-msg.XXXXXX") || exit 0
STORE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-poll-store.XXXXXX") || exit 0
ACK_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-poll-ack.XXXXXX") || exit 0
trap 'rm -f "$BODY_FILE" "$MSG_FILE" "$STORE_FILE" "$ACK_FILE"' EXIT

cursor=$(fms_poll_cursor_read "$STATE")
[ -n "$cursor" ] || cursor=0

collect_messages() {
  local parent_ts=${1:-} data
  fms_require_configured_channel "$FMS_CHANNEL_ID" || return 1
  data="channel=$(printf '%s' "$FMS_CHANNEL_ID" | jq -sRr @uri)&limit=50"
  if [ "$cursor" != 0 ]; then
    data="${data}&oldest=$(printf '%s' "$cursor" | jq -sRr @uri)"
  fi
  if [ -n "$parent_ts" ]; then
    fms_message_ts_valid "$parent_ts" || return 1
    data="${data}&ts=$(printf '%s' "$parent_ts" | jq -sRr @uri)"
    fms_api_post conversations.replies "$data" "$BODY_FILE" || return 1
  else
    fms_api_post conversations.history "$data" "$BODY_FILE" || return 1
  fi
  fms_api_json_ok "$BODY_FILE" || return 1
  jq -c '.messages[]?' "$BODY_FILE" 2>/dev/null | while IFS= read -r row; do
    [ -n "$row" ] || continue
    printf '%s\n' "$row" > "$MSG_FILE"
    fms_is_bot_message "$MSG_FILE" "$FMS_BOT_USER_ID" && continue
    fms_message_has_text "$MSG_FILE" || continue
    ts=$(jq -r '.ts // empty' "$MSG_FILE" 2>/dev/null) || continue
    fms_message_ts_valid "$ts" || continue
    printf '%s\t%s\n' "$ts" "$row" >> "$STORE_FILE"
  done
  return 0
}

if ! collect_messages; then
  emit_error_once "conversations.history failed"
  exit 0
fi

jq -r '.messages[]? | select((.reply_count? // 0) > 0) | .ts // empty' "$BODY_FILE" 2>/dev/null \
  | while IFS= read -r parent; do
      [ -n "$parent" ] || continue
      collect_messages "$parent" || true
    done

if [ ! -s "$STORE_FILE" ]; then
  clear_error
  exit 0
fi

selected=
selected_json=
while IFS=$'\t' read -r ts row; do
  [ -n "$ts" ] || continue
  [ -n "$row" ] || continue
  fms_message_ts_valid "$ts" || continue
  if fmx_private_artifact_file_valid "$STATE/slack-offered" "$ts" 600 2>/dev/null; then
    continue
  fi
  selected=$ts
  selected_json=$row
  break
done < <(sort -t $'\t' -k1,1n "$STORE_FILE")

if [ -z "$selected" ] || [ -z "$selected_json" ]; then
  clear_error
  exit 0
fi

printf '%s\n' "$selected_json" > "$MSG_FILE"
message_text=$(fms_message_text_oneline "$MSG_FILE") || message_text=
[ -n "$message_text" ] || { emit_error_once "empty captain message"; exit 0; }

if ! fmx_private_artifact_file_valid "$STATE/slack-acked" "$selected" 600 2>/dev/null; then
  if ! fms_post_ack "$selected" "$ACK_FILE"; then
    emit_error_once "ack post failed"
    exit 0
  fi
  case $(fms_ack_claim "$STATE" "$selected"; echo $?) in
    0) ;;
    1) ;;
    *)
      emit_error_once "cannot record message ack"
      exit 0
      ;;
  esac
fi

if ! fms_inbox_publish "$STATE" "$selected" "$MSG_FILE"; then
  emit_error_once "cannot write inbox"
  exit 0
fi

case $(fms_offer_claim "$STATE" "$selected"; echo $?) in
  0)
    clear_error
    fms_wake_line "$selected" "$message_text" || { emit_error_once "cannot format wake"; exit 0; }
  ;;
  1)
    clear_error
    exit 0
  ;;
  *)
    emit_error_once "cannot record message offer"
    exit 0
  ;;
esac

fms_poll_cursor_write "$STATE" "$selected" >/dev/null 2>&1 || true
