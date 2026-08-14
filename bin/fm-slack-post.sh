#!/usr/bin/env bash
# Post and update messages in the configured Slack captain channel.
#
# Inert without FM_SLACK_BOT_TOKEN and config/slack-captain-channel.
# Every path refuses a channel id that does not match configuration.
#
# Usage:
#   fm-slack-post.sh message <text> [thread_ts]
#   fm-slack-post.sh update <message_ts> <text>
#   fm-slack-post.sh board <text>   # chat.update when state/slack-board.ts exists,
#                                   # otherwise chat.postMessage and record ts
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-slack-lib.sh
. "$SCRIPT_DIR/fm-slack-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

fms_load_config
fms_configured || die "Slack captain channel is not configured"

command -v curl >/dev/null 2>&1 || die "missing curl"
command -v jq   >/dev/null 2>&1 || die "missing jq"

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-post.XXXXXX") || exit 1
trap 'rm -f "$BODY_FILE"' EXIT

post_message() {
  local text=$1 thread_ts=${2:-} data ts
  fms_channel_configured || die "refusing channel mismatch on post"
  data="channel=$(printf '%s' "$FMS_CHANNEL_ID" | jq -sRr @uri)"
  data="${data}&text=$(printf '%s' "$text" | jq -sRr @uri)"
  if [ -n "$thread_ts" ]; then
    fms_message_ts_valid "$thread_ts" || die "invalid thread_ts"
    data="${data}&thread_ts=$(printf '%s' "$thread_ts" | jq -sRr @uri)"
  fi
  fms_api_post chat.postMessage "$data" "$BODY_FILE" || die "chat.postMessage transport failed"
  fms_api_json_ok "$BODY_FILE" || die "chat.postMessage rejected"
  fms_api_response_channel_ok "$BODY_FILE" || die "refusing response channel mismatch on post"
  ts=$(jq -r '.ts // empty' "$BODY_FILE" 2>/dev/null) || ts=
  [ -n "$ts" ] || die "chat.postMessage returned no ts"
  printf '%s\n' "$ts"
}

update_message() {
  local message_ts=$1 text=$2 data
  fms_message_ts_valid "$message_ts" || die "invalid message ts"
  fms_channel_configured || die "refusing channel mismatch on update"
  data="channel=$(printf '%s' "$FMS_CHANNEL_ID" | jq -sRr @uri)"
  data="${data}&ts=$(printf '%s' "$message_ts" | jq -sRr @uri)"
  data="${data}&text=$(printf '%s' "$text" | jq -sRr @uri)"
  fms_api_post chat.update "$data" "$BODY_FILE" || die "chat.update transport failed"
  fms_api_json_ok "$BODY_FILE" || die "chat.update rejected"
  fms_api_response_channel_ok "$BODY_FILE" || die "refusing response channel mismatch on update"
  printf '%s\n' "$message_ts"
}

board_meta_read() {
  local meta=$STATE/slack-board.meta
  fmx_private_artifact_file_valid "$STATE" "slack-board.meta" 600 2>/dev/null || return 1
  grep '^ts=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

board_meta_channel() {
  local meta=$STATE/slack-board.meta
  fmx_private_artifact_file_valid "$STATE" "slack-board.meta" 600 2>/dev/null || return 1
  grep '^channel=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

board_meta_write() {
  local ts=$1
  fms_message_ts_valid "$ts" || return 1
  printf 'channel=%s\nts=%s\n' "$FMS_CHANNEL_ID" "$ts" \
    | fmx_private_artifact_publish_stdin "$STATE" "slack-board.meta" 600 >/dev/null 2>&1
}

cmd=${1-}
shift || true
case "$cmd" in
  message)
    [ "$#" -ge 1 ] || die "usage: fm-slack-post.sh message <text> [thread_ts]"
    post_message "$@"
    ;;
  update)
    [ "$#" -eq 2 ] || die "usage: fm-slack-post.sh update <message_ts> <text>"
    update_message "$1" "$2"
    ;;
  board)
    [ "$#" -eq 1 ] || die "usage: fm-slack-post.sh board <text>"
    existing=$(board_meta_read 2>/dev/null || true)
    if [ -n "$existing" ]; then
      stored_channel=$(board_meta_channel 2>/dev/null || true)
      [ "$stored_channel" = "$FMS_CHANNEL_ID" ] || die "refusing board update for mismatched channel"
      update_message "$existing" "$1"
    else
      ts=$(post_message "$1")
      board_meta_write "$ts" || die "could not record board message"
      printf '%s\n' "$ts"
    fi
    ;;
  *)
    die "usage: fm-slack-post.sh message|update|board ..."
    ;;
esac
