#!/usr/bin/env bash
# Consume one already-acked Socket Mode message event from stdin.
#
# Two event families are accepted, everything else is refused and recorded
# under state/slack-refused/ without acknowledgement or wake:
#
# message - the typed captain path: a human captain message with text on the
#   configured channel is published durably to the inbox and wakes firstmate
#   once with `slack-captain-message <ts><TAB><text>` before the courtesy
#   acknowledgement: the `received` reaction is best-effort, a failure leaves
#   a durable marker under state/slack-ack-pending/ for a later poll or
#   repeated event to retry, and an acknowledgement failure never suppresses
#   delivery of newer captain messages.
#
# reaction_added / reaction_removed - the captain's emoji answer path. A
#   reaction is accepted from the pinned captain id only, on a message
#   firstmate itself posted (item_user is the bot), and only when that message
#   carries a recorded decision binding (state/slack-decision-bindings/,
#   written by bin/fm-slack-post.sh decision). white_check_mark answers yes, x
#   answers no, and one/two/three select the matching numbered option; any
#   other reaction, an out-of-range number, a non-captain, another author's
#   message, or an unbound message is refused and recorded - an ambiguous or
#   missing reaction never answers. The answer is recorded once under
#   state/slack-decision-resolved/ and delivered through the same inbox and
#   `slack-captain-message <event_ts><TAB><key>: <answer>` wake a typed reply
#   takes, so nothing downstream needs to know it came from a reaction. A
#   removal after the answer, or a contradictory second answer, is reported
#   with a `slack-captain-reaction` conflict line and never reverses or reopens
#   the recorded answer; a removal before any answer stays silent.
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

event_type=$(jq -r '.type // empty' "$EVENT_FILE")
case "$event_type" in
  reaction_added|reaction_removed) ts=$(jq -r '.item.ts // empty' "$EVENT_FILE" 2>/dev/null) || ts= ;;
  *) ts=$(jq -r '.ts // empty' "$EVENT_FILE" 2>/dev/null) || ts= ;;
esac

refuse() {
  fms_refusal_publish "$STATE" "$ts" "$1" "$envelope_id" "$EVENT_FILE" || exit 2
  exit 0
}

# Stash the event as evidence and report a reaction conflict on its own wake
# line type; the recorded answer is never touched.
report_reaction_conflict() {
  fms_inbox_publish "$STATE" "$event_ts" "$EVENT_FILE" || exit 2
  fms_reaction_report_line "$event_ts" "$1" || exit 2
}

# The validation every reaction event shares: a message item on the configured
# channel, a valid item ts, the pinned captain as the reacting user, firstmate
# itself as the reacted message's author, a valid event ts, and a recorded
# decision binding. Sets the reaction, event_ts, key, and options globals.
reaction_common() {
  fms_message_ts_valid "$ts" || refuse malformed-event
  [ "$(jq -r '.item.type // empty' "$EVENT_FILE")" = message ] || refuse non-message-item
  [ "$(jq -r '.item.channel // empty' "$EVENT_FILE")" = "$FMS_CHANNEL_ID" ] || refuse wrong-channel
  event_user=$(jq -r '.user // empty' "$EVENT_FILE")
  [ "$event_user" = "$FMS_CAPTAIN_USER_ID" ] || refuse non-captain-user
  item_user=$(jq -r '.item_user // empty' "$EVENT_FILE")
  [ "$item_user" = "$FMS_BOT_USER_ID" ] || refuse non-firstmate-message
  event_ts=$(jq -r '.event_ts // empty' "$EVENT_FILE")
  fms_message_ts_valid "$event_ts" || refuse malformed-event
  reaction=$(jq -r '.reaction // empty' "$EVENT_FILE")
  binding=$(fms_decision_binding_read "$STATE" "$ts") || refuse unbound-message
  key=${binding%%"$tab"*}
  options=${binding#*"$tab"}
  case "$key" in ''|*"$tab"*) exit 2 ;; esac
  case "$options" in ''|*[!0-9]*|*"$tab"*) exit 2 ;; esac
}

handle_reaction_added() {
  local answer existing record
  answer=$(fms_reaction_answer_map "$reaction") || refuse unmapped-reaction
  case "$answer" in
    [0-9]*) [ "$answer" -le "$options" ] 2>/dev/null || refuse option-out-of-range ;;
  esac
  record="$STATE/slack-decision-resolved/${key}.json"
  case $(fms_decision_answer_record "$STATE" "$key" "$answer" "$reaction" "$ts" "$event_ts"; echo $?) in
    0) ;;
    1)
      existing=$(jq -r '.answer // empty' "$record" 2>/dev/null) || exit 2
      [ -n "$existing" ] || exit 2
      # A repeated delivery of the reaction that already answered is a
      # duplicate, not a contradiction: the answer stands silently.
      [ "$(jq -r '.reaction // empty' "$record" 2>/dev/null)" = "$reaction" ] && exit 0
      report_reaction_conflict "conflict: $key was already answered $existing; ignored $reaction"
      exit 0
      ;;
    *) exit 2 ;;
  esac

  fms_inbox_publish "$STATE" "$event_ts" "$EVENT_FILE" || exit 2
  fms_wake_line "$event_ts" "$key: $answer"
  fms_ack_message "$STATE" "$ts" "$ACK_FILE" || true
}

handle_reaction_removed() {
  local record recorded_reaction recorded_answer
  record="$STATE/slack-decision-resolved/${key}.json"
  if fmx_private_artifact_file_valid "$STATE/slack-decision-resolved" "${key}.json" 600 2>/dev/null; then
    recorded_reaction=$(jq -r '.reaction // empty' "$record" 2>/dev/null) || exit 2
    recorded_answer=$(jq -r '.answer // empty' "$record" 2>/dev/null) || exit 2
    if [ "$recorded_reaction" = "$reaction" ] && [ -n "$recorded_answer" ]; then
      report_reaction_conflict "conflict: $key was answered $recorded_answer by $reaction; removal does not reopen it"
    fi
  fi
  exit 0
}

handle_message() {
  local subtype event_user message_text
  fms_message_ts_valid "$ts" || refuse malformed-event

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

  if ! fmx_private_artifact_file_valid "$STATE/slack-inbox" "${ts}.json" 600 2>/dev/null; then
    fms_inbox_publish "$STATE" "$ts" "$EVENT_FILE" || exit 2
  fi
  fms_ack_pending_record "$STATE" "$ts" >/dev/null 2>&1
  case "$?" in 0|1) ;; *) exit 2 ;; esac
  case $(fms_offer_claim "$STATE" "$ts"; echo $?) in
    0) fms_wake_line "$ts" "$message_text" ;;
    1) ;;
    *) exit 2 ;;
  esac
  fms_ack_message "$STATE" "$ts" "$ACK_FILE" || true
}

tab=$(printf '\t')
case "$event_type" in
  message) handle_message ;;
  reaction_added)
    reaction_common
    handle_reaction_added
    ;;
  reaction_removed)
    reaction_common
    handle_reaction_removed
    ;;
  *)
    fms_message_ts_valid "$ts" || refuse malformed-event
    refuse non-captain-message
    ;;
esac
