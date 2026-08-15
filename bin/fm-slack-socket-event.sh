#!/usr/bin/env bash
# Consume one already-acked Socket Mode message event from stdin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-slack-lib.sh
. "$SCRIPT_DIR/fm-slack-lib.sh"

envelope_id=${1-}
[ -n "$envelope_id" ] || exit 2
command -v jq >/dev/null 2>&1 || exit 2

fms_load_config
fms_socket_configured || exit 2
fms_bot_user_id_load "$STATE" || exit 2

EVENT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-socket-event.XXXXXX") || exit 2
ACK_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-socket-ack.XXXXXX") || exit 2
trap 'rm -f "$EVENT_FILE" "$ACK_FILE"' EXIT
jq '.' > "$EVENT_FILE" 2>/dev/null || exit 2

ts=$(jq -r '.ts // empty' "$EVENT_FILE" 2>/dev/null) || ts=

refuse() {
  fms_refusal_publish "$STATE" "$ts" "$1" "$envelope_id" "$EVENT_FILE" || exit 2
  exit 0
}

fms_message_ts_valid "$ts" || refuse malformed-event

[ "$(jq -r '.type // empty' "$EVENT_FILE")" = message ] || refuse non-captain-message
[ "$(jq -r '.channel // empty' "$EVENT_FILE")" = "$FMS_CHANNEL_ID" ] || refuse wrong-channel

if fms_is_non_captain_message "$EVENT_FILE" "$FMS_BOT_USER_ID"; then
  subtype=$(jq -r '.subtype // empty' "$EVENT_FILE")
  event_user=$(jq -r '.user // empty' "$EVENT_FILE")
  if [ -n "$subtype" ]; then
    refuse non-captain-subtype
  elif [ "$event_user" = "$FMS_BOT_USER_ID" ] || [ "$(jq -r '.bot_id // empty' "$EVENT_FILE")" != "" ]; then
    refuse bot-user
  else
    refuse non-captain-message
  fi
fi

event_user=$(jq -r '.user // empty' "$EVENT_FILE")
[ "$event_user" = "$FMS_CAPTAIN_USER_ID" ] || refuse non-captain-user
fms_message_has_text "$EVENT_FILE" || refuse empty-message
message_text=$(fms_message_text_oneline "$EVENT_FILE") || exit 2
[ -n "$message_text" ] || refuse empty-message

if fmx_private_artifact_file_valid "$STATE/slack-offered" "$ts" 600 2>/dev/null; then
  exit 0
fi

if ! fmx_private_artifact_file_valid "$STATE/slack-acked" "$ts" 600 2>/dev/null; then
  case $(fms_ack_claim "$STATE" "$ts"; echo $?) in
    0)
      if ! fms_post_ack "$ts" "$ACK_FILE"; then
        fms_ack_claim_release "$STATE" "$ts"
        exit 2
      fi
      ;;
    1) ;;
    *) exit 2 ;;
  esac
fi

fms_inbox_publish "$STATE" "$ts" "$EVENT_FILE" || exit 2
case $(fms_offer_claim "$STATE" "$ts"; echo $?) in
  0) fms_wake_line "$ts" "$message_text" ;;
  1) exit 0 ;;
  *) exit 2 ;;
esac
