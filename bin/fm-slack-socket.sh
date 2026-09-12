#!/usr/bin/env bash
# Supervised bridge from Socket Mode frames to the existing Slack wake contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-slack-lib.sh
. "$SCRIPT_DIR/fm-slack-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

slack_unhandled_after() {
  local after=${FM_SLACK_UNHANDLED_AFTER:-300}
  case "$after" in ''|*[!0-9]*|0) after=300 ;; esac
  printf '%s\n' "$after"
}

slack_message_is_unhandled() {  # <message-ts>
  fm_wake_queued_keys check | grep -Fx "slack-socket:$1" >/dev/null 2>&1
}

slack_auto_reply_claim() {  # <message-ts>
  local ts=$1
  printf '%s\n' "$ts" \
    | fmx_private_artifact_publish_stdin_once "$STATE/slack-autoreplied" "$ts" 600
}

slack_unhandled_auto_reply() {  # <message-ts> <thread-ts>
  local ts=$1 thread_ts=$2 received after wait claim rearm post
  fms_message_ts_valid "$ts" || return 2
  fms_message_ts_valid "$thread_ts" || return 2
  received=${ts%%.*}
  after=$(slack_unhandled_after)
  wait=$((received + after - $(date +%s)))
  [ "$wait" -gt 0 ] || wait=0
  sleep "$wait"
  slack_message_is_unhandled "$ts" || return 0
  slack_auto_reply_claim "$ts"
  claim=$?
  case "$claim" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
  rearm=${FM_SLACK_UNHANDLED_REARM:-$SCRIPT_DIR/fm-secondmate-liveness.sh}
  post=${FM_SLACK_UNHANDLED_POST:-$SCRIPT_DIR/fm-slack-post.sh}
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$rearm" --recover >/dev/null 2>&1 || true
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$post" message \
    'MAIN has not picked this up in 5 min; watcher re-arm requested' "$thread_ts" >/dev/null 2>&1 || true
}

schedule_unhandled_auto_reply() {  # <message-ts> <thread-ts>
  local ts=$1 thread_ts=$2
  fms_message_ts_valid "$ts" || return 1
  fms_message_ts_valid "$thread_ts" || return 1
  slack_message_is_unhandled "$ts" || return 0
  if fmx_private_artifact_file_valid "$STATE/slack-autoreplied" "$ts" 600 2>/dev/null; then
    return 0
  fi
  nohup env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-slack-socket.sh" \
    --auto-reply "$ts" "$thread_ts" </dev/null >/dev/null 2>&1 &
}

schedule_queued_auto_replies() {
  local inbox ts thread_ts
  for inbox in "$STATE/slack-inbox"/*.json; do
    [ -e "$inbox" ] || continue
    ts=${inbox##*/}
    ts=${ts%.json}
    fms_message_ts_valid "$ts" || continue
    fmx_private_artifact_file_valid "$STATE/slack-inbox" "${ts}.json" 600 2>/dev/null || continue
    [ "$(jq -r '.type // empty' "$inbox" 2>/dev/null)" = message ] || continue
    thread_ts=$(jq -r '.thread_ts // .ts // empty' "$inbox" 2>/dev/null) || continue
    schedule_unhandled_auto_reply "$ts" "$thread_ts"
  done
}

fms_load_config
case "${1:-}" in
  --auto-reply)
    [ "$#" -eq 3 ] || exit 2
    fms_configured || exit 2
    slack_unhandled_auto_reply "$2" "$3"
    exit $?
    ;;
  '') ;;
  *) exit 2 ;;
esac
fms_socket_configured || exit 2
command -v node >/dev/null 2>&1 || exit 2
schedule_queued_auto_replies

FM_SLACK_APP_TOKEN="$FMS_APP_TOKEN" node "$SCRIPT_DIR/fm-slack-socket.mjs" | while IFS= read -r frame; do
  envelope_id=$(printf '%s\n' "$frame" | jq -r '.envelope_id // empty' 2>/dev/null) || exit 2
  event=$(printf '%s\n' "$frame" | jq -c '.event // empty' 2>/dev/null) || exit 2
  [ -n "$envelope_id" ] && [ -n "$event" ] || exit 2
  wake=$(printf '%s\n' "$event" \
    | FM_SLACK_APP_TOKEN="$FMS_APP_TOKEN" "$SCRIPT_DIR/fm-slack-socket-event.sh" "$envelope_id") || exit 2
  [ -n "$wake" ] || continue
  ts=$(printf '%s\n' "$event" | jq -r '.ts // .event_ts // empty' 2>/dev/null) || exit 2
  fm_wake_append check "slack-socket:$ts" "check: $SCRIPT_DIR/fm-slack-socket.sh: $wake" || exit 2
  if [ "$(printf '%s\n' "$event" | jq -r '.type // empty' 2>/dev/null)" = message ]; then
    thread_ts=$(printf '%s\n' "$event" | jq -r '.thread_ts // .ts // empty' 2>/dev/null) || exit 2
    schedule_unhandled_auto_reply "$ts" "$thread_ts" || exit 2
  fi
done
pipeline_status=("${PIPESTATUS[@]}")
[ "${pipeline_status[0]}" -eq 0 ] || exit "${pipeline_status[0]}"
exit "${pipeline_status[1]}"
