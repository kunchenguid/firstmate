#!/usr/bin/env bash
# fm-zalo-folder-qa.sh - Dormant fail-closed bridge for one Zalo group.
#
# The bridge accepts messages only from the configured Zalo group.
# Until a workbook schema, isolated data handler, allowed-query policy,
# freshness threshold, and per-file evidence contract are defined, every
# eligible message receives only the fixed unavailable response.
# No message content is sent to Microsoft Graph or to an executable handler.
#
# Usage:
#   fm-zalo-folder-qa.sh check
#   fm-zalo-folder-qa.sh source-status
#   fm-zalo-folder-qa.sh handle       # one Zalo event JSON on stdin; no reply
#   fm-zalo-folder-qa.sh run          # foreground long poll and fixed replies
#
# Configuration is a mode-600 data file selected by FM_ZALO_FOLDER_QA_CONFIG,
# defaulting to $FM_HOME/config/zalo-folder-qa.env.
# It accepts exactly these KEY=value records:
#
#   ZALO_BOT_TOKEN=<private Bot Mac Louis token>
#   ZALO_BOT_ID=<exact bot ID returned by getMe>
#   ZALO_GROUP_ID=<exact private chat.id of TỒN KHO ÂM-DƯƠNG>
#   GRAPH_DRIVE_ID=<exact private Graph drive ID>
#   GRAPH_FOLDER_ID=<exact private Graph item ID for Check tồn kho âm>
#   GRAPH_REFRESH_TOKEN_FILE=<absolute mode-600 Files.Read refresh-token file>
#
# source-status verifies only the configured drive/folder identity.
# It always reports unavailable because no freshness or evidence policy exists.
set -euo pipefail

umask 077

SELF_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(CDPATH='' cd -- "$SELF_DIR/.." && pwd -P)
FM_HOME=${FM_HOME:-$ROOT}
CONFIG_FILE=${FM_ZALO_FOLDER_QA_CONFIG:-$FM_HOME/config/zalo-folder-qa.env}
STATE_ROOT=${FM_STATE_OVERRIDE:-$FM_HOME/state}
STATE_DIR=$STATE_ROOT/zalo-folder-qa
SEEN_DIR=$STATE_DIR/seen

ZALO_API_ORIGIN=https://bot-api.zaloplatforms.com
GRAPH_API_ORIGIN=https://graph.microsoft.com/v1.0
GRAPH_TOKEN_URL=https://login.microsoftonline.com/organizations/oauth2/v2.0/token
GRAPH_CLIENT_ID=14d82eec-204b-4c2f-b7e8-296a70dab67e
EXPECTED_FOLDER_NAME='Check tồn kho âm'

ZALO_BOT_TOKEN=
ZALO_BOT_ID=
ZALO_GROUP_ID=
GRAPH_DRIVE_ID=
GRAPH_FOLDER_ID=
GRAPH_REFRESH_TOKEN_FILE=
GRAPH_ACCESS_TOKEN=
SOURCE_STATUS_JSON=

UNAVAILABLE_TEXT='Nguồn dữ liệu Check tồn kho âm hiện chưa khả dụng; tôi chưa thể trả lời từ dữ liệu đã xác minh.'

die() {
  printf 'fm-zalo-folder-qa: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'fm-zalo-folder-qa: %s\n' "$*" >&2
}

usage() {
  sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

file_owner() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

file_links() {
  stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null
}

validate_private_file() { # <path> <label>
  local path=$1 label=$2
  [ -e "$path" ] || die "missing $label: $path"
  [ ! -L "$path" ] || die "$label must not be a symlink: $path"
  [ -f "$path" ] || die "$label is not a regular file: $path"
  [ "$(file_mode "$path")" = 600 ] || die "$label must have mode 600: $path"
  [ "$(file_owner "$path")" = "$(id -u)" ] || die "$label must be owned by the current user: $path"
  [ "$(file_links "$path")" = 1 ] || die "$label must have exactly one hard link: $path"
}

valid_private_id() {
  [ -n "${1:-}" ] && [ "${#1}" -le 256 ] || return 1
  case "${1:-}" in
    *[!A-Za-z0-9._:!-]*) return 1 ;;
  esac
  case "$1" in
    [A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

load_config() {
  local line key value seen=:
  validate_private_file "$CONFIG_FILE" 'private configuration'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) die "malformed configuration record in $CONFIG_FILE" ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$seen" in
      *":$key:"*) die "duplicate configuration key: $key" ;;
    esac
    seen="$seen$key:"
    case "$key" in
      ZALO_BOT_TOKEN) ZALO_BOT_TOKEN=$value ;;
      ZALO_BOT_ID) ZALO_BOT_ID=$value ;;
      ZALO_GROUP_ID) ZALO_GROUP_ID=$value ;;
      GRAPH_DRIVE_ID) GRAPH_DRIVE_ID=$value ;;
      GRAPH_FOLDER_ID) GRAPH_FOLDER_ID=$value ;;
      GRAPH_REFRESH_TOKEN_FILE) GRAPH_REFRESH_TOKEN_FILE=$value ;;
      *) die "unknown configuration key: $key" ;;
    esac
  done < "$CONFIG_FILE"

  [ -n "$ZALO_BOT_TOKEN" ] || die "ZALO_BOT_TOKEN is missing from $CONFIG_FILE"
  [ "${#ZALO_BOT_TOKEN}" -le 4096 ] || die 'ZALO_BOT_TOKEN is too long'
  valid_private_id "$ZALO_BOT_ID" || die "ZALO_BOT_ID is missing or invalid in $CONFIG_FILE"
  valid_private_id "$ZALO_GROUP_ID" || die "ZALO_GROUP_ID is missing or invalid in $CONFIG_FILE"
  valid_private_id "$GRAPH_DRIVE_ID" || die "GRAPH_DRIVE_ID is missing or invalid in $CONFIG_FILE"
  valid_private_id "$GRAPH_FOLDER_ID" || die "GRAPH_FOLDER_ID is missing or invalid in $CONFIG_FILE"
  case "$ZALO_BOT_TOKEN" in
    *[!A-Za-z0-9._:-]*) die 'ZALO_BOT_TOKEN contains unsupported characters' ;;
  esac
  case "$GRAPH_REFRESH_TOKEN_FILE" in
    /*) ;;
    *) die 'GRAPH_REFRESH_TOKEN_FILE must be an absolute path' ;;
  esac
  validate_private_file "$GRAPH_REFRESH_TOKEN_FILE" 'Graph refresh-token file'
}

init_state() {
  if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
    [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || die "unsafe state directory: $STATE_DIR"
    [ "$(file_owner "$STATE_DIR")" = "$(id -u)" ] || die "state directory is not owned by the current user: $STATE_DIR"
    chmod 700 "$STATE_DIR"
  else
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
  fi
  if [ -e "$SEEN_DIR" ] || [ -L "$SEEN_DIR" ]; then
    [ -d "$SEEN_DIR" ] && [ ! -L "$SEEN_DIR" ] || die "unsafe seen directory: $SEEN_DIR"
    [ "$(file_owner "$SEEN_DIR")" = "$(id -u)" ] || die "seen directory is not owned by the current user: $SEEN_DIR"
    chmod 700 "$SEEN_DIR"
  else
    mkdir -m 700 "$SEEN_DIR"
  fi
}

urlencode() {
  jq -sRr @uri
}

zalo_request() { # <method> <json-body> <max-seconds>
  local method=$1 body=$2 max_seconds=$3 url
  url=$ZALO_API_ORIGIN/bot$ZALO_BOT_TOKEN/$method
  printf '%s' "$body" | curl --silent --show-error --max-time "$max_seconds" \
    --request POST --header 'Content-Type: application/json' --data-binary @- \
    --config /dev/fd/3 3< <(printf 'url = "%s"\n' "$url")
}

refresh_graph_token() {
  local refresh encoded body raw scope
  refresh=$(tr -d '\r\n' < "$GRAPH_REFRESH_TOKEN_FILE")
  [ -n "$refresh" ] || return 1
  encoded=$(printf '%s' "$refresh" | urlencode)
  unset refresh
  body="grant_type=refresh_token&client_id=$GRAPH_CLIENT_ID&refresh_token=$encoded&scope=offline_access%20Files.Read"
  unset encoded
  raw=$(printf '%s' "$body" | curl --silent --show-error --max-time 30 \
    --request POST --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary @- "$GRAPH_TOKEN_URL") || return 1
  unset body
  GRAPH_ACCESS_TOKEN=$(printf '%s' "$raw" | jq -r '.access_token // empty')
  scope=$(printf '%s' "$raw" | jq -r '.scope // empty')
  unset raw
  [ -n "$GRAPH_ACCESS_TOKEN" ] || return 1
  case " $scope " in
    *' Files.Read '*) ;;
    *) GRAPH_ACCESS_TOKEN=; return 1 ;;
  esac
  case "$scope" in
    *Files.ReadWrite*|*Files.Read.All*|*Sites.ReadWrite*|*Sites.FullControl*)
      GRAPH_ACCESS_TOKEN=
      return 1
      ;;
  esac
}

graph_request() { # <url>
  local url=$1
  curl --silent --show-error --max-time 30 --config /dev/fd/3 \
    3< <(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\n' "$url" "$GRAPH_ACCESS_TOKEN")
}

source_status() {
  local encoded_drive encoded_folder folder_url folder
  GRAPH_ACCESS_TOKEN=
  if ! refresh_graph_token; then
    SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"graph-auth"}')
    return 0
  fi
  encoded_drive=$(printf '%s' "$GRAPH_DRIVE_ID" | urlencode)
  encoded_folder=$(printf '%s' "$GRAPH_FOLDER_ID" | urlencode)
  folder_url="$GRAPH_API_ORIGIN/drives/$encoded_drive/items/$encoded_folder?%24select=id,name,parentReference,folder"
  folder=$(graph_request "$folder_url" 2>/dev/null) || folder=
  GRAPH_ACCESS_TOKEN=
  if ! printf '%s' "$folder" | jq -e \
    --arg drive "$GRAPH_DRIVE_ID" \
    --arg folder "$GRAPH_FOLDER_ID" \
    --arg name "$EXPECTED_FOLDER_NAME" \
    '.error == null and .id == $folder and .name == $name and .folder != null and .parentReference.driveId == $drive' \
    >/dev/null 2>&1; then
    SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"folder-pin"}')
    return 0
  fi
  SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"freshness-policy-undefined"}')
}

parse_event() { # <json>; sets EVENT_* globals
  local event=$1 chat_type chat_id is_bot text_type text_length
  EVENT_ACTION=ignore
  EVENT_REASON=malformed-event
  EVENT_MESSAGE_ID=
  printf '%s' "$event" | jq -e 'type == "object"' >/dev/null 2>&1 || return 0
  [ "$(printf '%s' "$event" | jq -r '.event_name // empty')" = message.text.received ] || {
    EVENT_REASON=unsupported-event
    return 0
  }
  chat_type=$(printf '%s' "$event" | jq -r '.message.chat.chat_type // empty')
  [ "$chat_type" = GROUP ] || {
    EVENT_REASON=direct-message
    return 0
  }
  chat_id=$(printf '%s' "$event" | jq -r '.message.chat.id // empty')
  [ "$chat_id" = "$ZALO_GROUP_ID" ] || {
    EVENT_REASON=wrong-group
    return 0
  }
  is_bot=$(printf '%s' "$event" | jq -r '.message.from.is_bot // false')
  [ "$is_bot" != true ] || {
    EVENT_REASON=bot-message
    return 0
  }
  text_type=$(printf '%s' "$event" | jq -r '.message.text | type' 2>/dev/null || true)
  [ "$text_type" = string ] || {
    EVENT_REASON=unsupported-message
    return 0
  }
  text_length=$(printf '%s' "$event" | jq '.message.text | length' 2>/dev/null || true)
  EVENT_MESSAGE_ID=$(printf '%s' "$event" | jq -r '.message.message_id // empty')
  case "$text_length" in
    ''|*[!0-9]*) EVENT_REASON=invalid-message; return 0 ;;
  esac
  [ "$text_length" -gt 0 ] && [ "$text_length" -le 2000 ] && [ -n "$EVENT_MESSAGE_ID" ] || {
    EVENT_REASON=invalid-message
    return 0
  }
  EVENT_ACTION=query
  EVENT_REASON=
}

handle_event_json() { # <event-json>
  parse_event "$1"
  if [ "$EVENT_ACTION" = ignore ]; then
    jq -n --arg reason "$EVENT_REASON" '{action:"ignore", reason:$reason}'
    return 0
  fi
  jq -n --arg answer "$UNAVAILABLE_TEXT" '{action:"reply", reason:"source-unavailable", answer:$answer}'
}

verify_bot() {
  local raw
  raw=$(zalo_request getMe '{}' 20) || return 1
  printf '%s' "$raw" | jq -e --arg id "$ZALO_BOT_ID" \
    '.ok == true and ((.result.id // .result.bot_id // "") | tostring) == $id' >/dev/null 2>&1
}

send_unavailable_reply() {
  local payload raw
  payload=$(jq -n --arg chat "$ZALO_GROUP_ID" --arg text "$UNAVAILABLE_TEXT" '{chat_id:$chat, text:$text}')
  raw=$(zalo_request sendMessage "$payload" 30) || return 1
  printf '%s' "$raw" | jq -e '.ok == true and ((.result.message_id // "") | tostring | length > 0)' >/dev/null 2>&1
}

message_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

seen_or_reserve() { # <message-id>; 0=newly reserved, 1=already seen
  local digest receipt tmp
  digest=$(printf '%s' "$1" | message_digest) || die 'sha256 tool not found'
  receipt=$SEEN_DIR/$digest
  [ ! -e "$receipt" ] || return 1
  tmp=$(mktemp "$SEEN_DIR/.seen.XXXXXX")
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  if ln "$tmp" "$receipt" 2>/dev/null; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

cmd_check() {
  load_config
  printf 'configured: exact Zalo group and exact Graph drive/folder; answers unavailable\n'
}

cmd_source_status() {
  load_config
  need jq
  need curl
  source_status
  printf '%s' "$SOURCE_STATUS_JSON" | jq '{status, reason}'
  GRAPH_ACCESS_TOKEN=
}

cmd_handle() {
  local event
  load_config
  need jq
  event=$(cat)
  handle_event_json "$event"
}

cmd_run() {
  local raw event code
  load_config
  need jq
  need curl
  need flock
  init_state
  exec 9> "$STATE_DIR/run.lock"
  flock -n 9 || die 'another folder-Q&A bridge is already running'
  verify_bot || die 'bot identity check failed'
  log 'ready for the configured group; data answers remain unavailable'
  while :; do
    raw=$(zalo_request getUpdates '{"timeout":30}' 40) || die 'getUpdates transport failed'
    if ! printf '%s' "$raw" | jq -e '.ok == true and (.result | type == "object")' >/dev/null 2>&1; then
      code=$(printf '%s' "$raw" | jq -r '.error_code // empty' 2>/dev/null || true)
      [ "$code" = 408 ] && continue
      die 'getUpdates was refused'
    fi
    event=$(printf '%s' "$raw" | jq -c '.result')
    parse_event "$event"
    [ "$EVENT_ACTION" = query ] || continue
    seen_or_reserve "$EVENT_MESSAGE_ID" || continue
    if ! send_unavailable_reply; then
      die 'fixed unavailable reply failed or had an unknown outcome; duplicate replay is suppressed'
    fi
  done
}

case "${1:-}" in
  check)
    [ "$#" -eq 1 ] || die 'check accepts no arguments'
    cmd_check
    ;;
  source-status)
    [ "$#" -eq 1 ] || die 'source-status accepts no arguments'
    cmd_source_status
    ;;
  handle)
    [ "$#" -eq 1 ] || die 'handle accepts one event on stdin and no arguments'
    cmd_handle
    ;;
  run)
    [ "$#" -eq 1 ] || die 'run accepts no arguments'
    cmd_run
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
