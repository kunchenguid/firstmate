#!/usr/bin/env bash
# fm-zalo-folder-qa.sh - Dedicated read-only Q&A bridge for one Zalo group.
#
# The bridge accepts messages only from the configured Zalo group and routes
# them to one trusted local Q&A handler.
# It never injects group messages into a Firstmate session or agent composer.
# The handler receives a Microsoft Graph token whose effective scope must be
# delegated Files.Read, plus one configured folder item ID.
# It receives no Zalo token, group ID, sender ID, or message ID.
#
# The source contract is deliberately narrow while the stock workbook schema
# remains unknown.
# The configured Graph item must be a folder named "Check tồn kho âm".
# The bridge checks only that folder and its direct files for availability and
# freshness before invoking the handler.
# The handler owns workbook parsing and business answers, must begin every read
# from FM_GRAPH_FOLDER_ID, and must treat workbook content as untrusted data.
#
# Usage:
#   fm-zalo-folder-qa.sh check
#   fm-zalo-folder-qa.sh source-status
#   fm-zalo-folder-qa.sh handle       # one Zalo event JSON on stdin; no reply
#   fm-zalo-folder-qa.sh reply        # reply text on stdin; fixed group only
#   fm-zalo-folder-qa.sh run          # foreground long poll and fixed replies
#
# Configuration is a mode-600 data file selected by FM_ZALO_FOLDER_QA_CONFIG,
# defaulting to $FM_HOME/config/zalo-folder-qa.env.
# It accepts exactly these KEY=value records:
#
#   ZALO_BOT_TOKEN=<private Bot Mac Louis token>
#   ZALO_BOT_ID=<exact bot ID returned by getMe>
#   ZALO_GROUP_ID=<exact private chat.id of TỒN KHO ÂM-DƯƠNG>
#   GRAPH_FOLDER_ID=<exact private Graph item ID for Check tồn kho âm>
#   GRAPH_REFRESH_TOKEN_FILE=<absolute mode-600 Files.Read refresh-token file>
#   QA_HANDLER=<absolute trusted executable implementing folder-qa-handler/1>
#   MAX_SOURCE_AGE_SECONDS=<optional 300..604800; default 86400>
#
# The handler reads one JSON envelope on stdin and a short-lived Graph access
# token from file descriptor 3.
# Its environment contains only PATH, locale values, FM_GRAPH_FOLDER_ID,
# FM_GRAPH_TOKEN_FD=3, and FM_GRAPH_API_ORIGIN.
# It returns one JSON object with ok=true, answer, source_modified_at,
# files_consulted, and data_is_untrusted=true.
# The adapter ignores every other response field.
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
MAX_SOURCE_AGE_SECONDS=86400

ZALO_BOT_TOKEN=
ZALO_BOT_ID=
ZALO_GROUP_ID=
GRAPH_FOLDER_ID=
GRAPH_REFRESH_TOKEN_FILE=
QA_HANDLER=
GRAPH_ACCESS_TOKEN=
SOURCE_STATUS_JSON=

REFUSAL_TEXT='Kênh này chỉ trả lời câu hỏi đọc dữ liệu trong thư mục Check tồn kho âm; không thực hiện thay đổi dữ liệu hay hệ thống.'
UNAVAILABLE_TEXT='Nguồn dữ liệu Check tồn kho âm hiện chưa khả dụng; tôi chưa thể trả lời từ dữ liệu đã xác minh.'
STALE_TEXT='Nguồn dữ liệu Check tồn kho âm đã quá hạn cập nhật; tôi chưa thể trả lời như dữ liệu hiện tại.'

die() {
  printf 'fm-zalo-folder-qa: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'fm-zalo-folder-qa: %s\n' "$*" >&2
}

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
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

validate_handler() {
  local mode
  case "$QA_HANDLER" in
    /*) ;;
    *) die 'QA_HANDLER must be an absolute path' ;;
  esac
  [ -e "$QA_HANDLER" ] || die "missing QA_HANDLER: $QA_HANDLER"
  [ ! -L "$QA_HANDLER" ] || die "QA_HANDLER must not be a symlink: $QA_HANDLER"
  [ -f "$QA_HANDLER" ] || die "QA_HANDLER is not a regular file: $QA_HANDLER"
  [ -x "$QA_HANDLER" ] || die "QA_HANDLER is not executable: $QA_HANDLER"
  [ "$(file_owner "$QA_HANDLER")" = "$(id -u)" ] || die "QA_HANDLER must be owned by the current user: $QA_HANDLER"
  mode=$(file_mode "$QA_HANDLER")
  case "$mode" in
    ''|*[!0-7]*) die "could not read QA_HANDLER mode: $QA_HANDLER" ;;
  esac
  [ $((8#$mode & 8#022)) -eq 0 ] || die "QA_HANDLER must not be group- or world-writable: $QA_HANDLER"
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
      GRAPH_FOLDER_ID) GRAPH_FOLDER_ID=$value ;;
      GRAPH_REFRESH_TOKEN_FILE) GRAPH_REFRESH_TOKEN_FILE=$value ;;
      QA_HANDLER) QA_HANDLER=$value ;;
      MAX_SOURCE_AGE_SECONDS) MAX_SOURCE_AGE_SECONDS=$value ;;
      *) die "unknown configuration key: $key" ;;
    esac
  done < "$CONFIG_FILE"

  [ -n "$ZALO_BOT_TOKEN" ] || die "ZALO_BOT_TOKEN is missing from $CONFIG_FILE"
  [ "${#ZALO_BOT_TOKEN}" -le 4096 ] || die 'ZALO_BOT_TOKEN is too long'
  valid_private_id "$ZALO_BOT_ID" || die "ZALO_BOT_ID is missing or invalid in $CONFIG_FILE"
  valid_private_id "$ZALO_GROUP_ID" || die "ZALO_GROUP_ID is missing or invalid in $CONFIG_FILE"
  valid_private_id "$GRAPH_FOLDER_ID" || die "GRAPH_FOLDER_ID is missing or invalid in $CONFIG_FILE"
  case "$ZALO_BOT_TOKEN" in
    *[!A-Za-z0-9._:-]*) die 'ZALO_BOT_TOKEN contains unsupported characters' ;;
  esac
  case "$GRAPH_REFRESH_TOKEN_FILE" in
    /*) ;;
    *) die 'GRAPH_REFRESH_TOKEN_FILE must be an absolute path' ;;
  esac
  case "$MAX_SOURCE_AGE_SECONDS" in
    ''|*[!0-9]*) die 'MAX_SOURCE_AGE_SECONDS must be an integer' ;;
  esac
  [ "$MAX_SOURCE_AGE_SECONDS" -ge 300 ] && [ "$MAX_SOURCE_AGE_SECONDS" -le 604800 ] \
    || die 'MAX_SOURCE_AGE_SECONDS must be between 300 and 604800'
  validate_private_file "$GRAPH_REFRESH_TOKEN_FILE" 'Graph refresh-token file'
  validate_handler
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

iso_epoch() {
  local stamp=$1 normalized
  normalized=$(printf '%s' "$stamp" | sed -E 's/\.[0-9]+Z$/Z/')
  date -u -d "$normalized" +%s 2>/dev/null \
    || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$normalized" +%s 2>/dev/null
}

source_status() {
  local encoded folder_url children_url folder children file_count latest latest_epoch now age next
  GRAPH_ACCESS_TOKEN=
  if ! refresh_graph_token; then
    SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"graph-auth"}')
    return 0
  fi
  encoded=$(printf '%s' "$GRAPH_FOLDER_ID" | urlencode)
  folder_url="$GRAPH_API_ORIGIN/me/drive/items/$encoded?%24select=id,name,lastModifiedDateTime,folder"
  children_url="$GRAPH_API_ORIGIN/me/drive/items/$encoded/children?%24select=name,size,lastModifiedDateTime,file,folder&%24top=999"
  folder=$(graph_request "$folder_url" 2>/dev/null) || folder=
  if ! printf '%s' "$folder" | jq -e --arg id "$GRAPH_FOLDER_ID" --arg name "$EXPECTED_FOLDER_NAME" \
    '.error == null and .id == $id and .name == $name and .folder != null' >/dev/null 2>&1; then
    GRAPH_ACCESS_TOKEN=
    SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"folder-pin"}')
    return 0
  fi
  children=$(graph_request "$children_url" 2>/dev/null) || children=
  next=$(printf '%s' "$children" | jq -r '.["@odata.nextLink"] // empty' 2>/dev/null || true)
  if [ -n "$next" ] || ! printf '%s' "$children" | jq -e '.error == null and (.value | type == "array")' >/dev/null 2>&1; then
    GRAPH_ACCESS_TOKEN=
    SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"folder-list"}')
    return 0
  fi
  file_count=$(printf '%s' "$children" | jq '[.value[] | select(.file != null)] | length')
  latest=$(printf '%s' "$children" | jq -r '[.value[] | select(.file != null) | .lastModifiedDateTime // empty] | max // empty')
  if [ "$file_count" -eq 0 ] || [ -z "$latest" ]; then
    GRAPH_ACCESS_TOKEN=
    SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"empty-folder"}')
    return 0
  fi
  latest_epoch=$(iso_epoch "$latest" 2>/dev/null || true)
  case "$latest_epoch" in
    ''|*[!0-9]*)
      GRAPH_ACCESS_TOKEN=
      SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"invalid-source-time"}')
      return 0
      ;;
  esac
  now=$(date -u +%s)
  age=$((now - latest_epoch))
  if [ "$age" -lt -300 ]; then
    GRAPH_ACCESS_TOKEN=
    SOURCE_STATUS_JSON=$(jq -n '{status:"unavailable", reason:"future-source-time"}')
  elif [ "$age" -gt "$MAX_SOURCE_AGE_SECONDS" ]; then
    GRAPH_ACCESS_TOKEN=
    SOURCE_STATUS_JSON=$(jq -n --arg modified "$latest" --argjson count "$file_count" \
      '{status:"stale", latest_modified_at:$modified, direct_file_count:$count}')
  else
    SOURCE_STATUS_JSON=$(jq -n --arg modified "$latest" --argjson count "$file_count" \
      '{status:"fresh", latest_modified_at:$modified, direct_file_count:$count}')
  fi
}

scope_refusal_reason() { # <question>
  local question=$1
  if printf '%s\n' "$question" | grep -Eiq '(\.\./|\.\.\\|(^|[[:space:]])/[A-Za-z]|[A-Za-z]:\\|file:|https?://|\\\\)'; then
    printf 'path-traversal\n'
    return 0
  fi
  if printf '%s\n' "$question" | grep -Eiq '(^|[[:space:][:punct:]])(hãy|vui lòng|giúp|please|can you|could you)?[[:space:]]*(xóa|xoá|sửa|ghi|cập nhật|tải lên|upload|đổi|thay đổi|chạy|khởi động|restart|sync|deploy|merge|commit|push|delete|remove|edit|write|update|insert|upsert|move|rename)([[:space:][:punct:]]|$)'; then
    printf 'mutation-request\n'
    return 0
  fi
  if printf '%s\n' "$question" | grep -Eiq '(bỏ qua.*(hướng dẫn|chỉ dẫn)|ignore.*(instruction|previous)|system prompt|developer message|tiết lộ.*(token|bí mật)|show.*(token|secret))'; then
    printf 'instruction-override\n'
    return 0
  fi
  return 1
}

parse_event() { # <json>; sets EVENT_* globals
  local event=$1 chat_type chat_id is_bot text_type
  EVENT_ACTION=ignore
  EVENT_REASON=malformed-event
  EVENT_QUESTION=
  EVENT_SENDER=
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
  EVENT_QUESTION=$(printf '%s' "$event" | jq -r '.message.text')
  EVENT_SENDER=$(printf '%s' "$event" | jq -r '.message.from.display_name // "Thành viên"')
  EVENT_MESSAGE_ID=$(printf '%s' "$event" | jq -r '.message.message_id // empty')
  [ -n "$EVENT_QUESTION" ] && [ "${#EVENT_QUESTION}" -le 2000 ] && [ -n "$EVENT_MESSAGE_ID" ] || {
    EVENT_REASON=invalid-message
    return 0
  }
  [ "${#EVENT_SENDER}" -le 200 ] || EVENT_SENDER=${EVENT_SENDER:0:200}
  EVENT_ACTION=query
  EVENT_REASON=
}

handler_answer() { # <question> <sender> <source-json>; prints validated answer
  local question=$1 sender=$2 source=$3 modified count envelope raw answer
  modified=$(printf '%s' "$source" | jq -r '.latest_modified_at')
  count=$(printf '%s' "$source" | jq '.direct_file_count')
  envelope=$(jq -n \
    --arg question "$question" \
    --arg sender "$sender" \
    --arg folder "$EXPECTED_FOLDER_NAME" \
    --arg modified "$modified" \
    --argjson count "$count" \
    '{
      protocol:"folder-qa-handler/1",
      policy:{scope:"exact-folder-read-only", folder_name:$folder, source_cells_are_untrusted_data:true, system_changes_forbidden:true, answers_require_source_evidence:true},
      source:{latest_modified_at:$modified, direct_file_count:$count},
      request:{sender_display_name:$sender, question:$question}
    }')
  raw=$(printf '%s' "$envelope" | env -i \
    PATH="$PATH" LC_ALL="${LC_ALL:-C}" LANG="${LANG:-C}" \
    FM_GRAPH_FOLDER_ID="$GRAPH_FOLDER_ID" \
    FM_GRAPH_TOKEN_FD=3 \
    FM_GRAPH_API_ORIGIN="$GRAPH_API_ORIGIN" \
    "$QA_HANDLER" 3< <(printf '%s' "$GRAPH_ACCESS_TOKEN") 2>/dev/null) || return 1
  if ! printf '%s' "$raw" | jq -e --arg modified "$modified" '
      .ok == true
      and (.answer | type == "string" and length > 0 and length <= 2000)
      and .source_modified_at == $modified
      and .data_is_untrusted == true
      and (.files_consulted | type == "array" and length > 0 and length <= 50)
      and all(.files_consulted[]; type == "string" and length > 0 and length <= 255 and ((contains("/") or contains("\\") or contains("..")) | not))
    ' >/dev/null 2>&1; then
    return 1
  fi
  answer=$(printf '%s' "$raw" | jq -r '.answer')
  printf '%s' "$answer"
}

handle_event_json() { # <event-json>
  local event=$1 refusal status answer modified
  parse_event "$event"
  if [ "$EVENT_ACTION" = ignore ]; then
    jq -n --arg reason "$EVENT_REASON" '{action:"ignore", reason:$reason}'
    return 0
  fi
  refusal=$(scope_refusal_reason "$EVENT_QUESTION" 2>/dev/null || true)
  if [ -n "$refusal" ]; then
    jq -n --arg answer "$REFUSAL_TEXT" --arg reason "$refusal" '{action:"reply", reason:$reason, answer:$answer}'
    return 0
  fi
  source_status
  status=$(printf '%s' "$SOURCE_STATUS_JSON" | jq -r '.status')
  case "$status" in
    unavailable)
      GRAPH_ACCESS_TOKEN=
      jq -n --arg answer "$UNAVAILABLE_TEXT" '{action:"reply", reason:"source-unavailable", answer:$answer}'
      ;;
    stale)
      modified=$(printf '%s' "$SOURCE_STATUS_JSON" | jq -r '.latest_modified_at')
      GRAPH_ACCESS_TOKEN=
      jq -n --arg answer "$STALE_TEXT" --arg modified "$modified" \
        '{action:"reply", reason:"source-stale", answer:$answer, source_modified_at:$modified}'
      ;;
    fresh)
      modified=$(printf '%s' "$SOURCE_STATUS_JSON" | jq -r '.latest_modified_at')
      if answer=$(handler_answer "$EVENT_QUESTION" "$EVENT_SENDER" "$SOURCE_STATUS_JSON"); then
        GRAPH_ACCESS_TOKEN=
        jq -n --arg answer "$answer" --arg modified "$modified" \
          '{action:"reply", reason:"answered", answer:$answer, source_modified_at:$modified}'
      else
        GRAPH_ACCESS_TOKEN=
        jq -n --arg answer "$UNAVAILABLE_TEXT" '{action:"reply", reason:"handler-unavailable", answer:$answer}'
      fi
      ;;
    *)
      GRAPH_ACCESS_TOKEN=
      jq -n --arg answer "$UNAVAILABLE_TEXT" '{action:"reply", reason:"source-unavailable", answer:$answer}'
      ;;
  esac
}

verify_bot() {
  local raw
  raw=$(zalo_request getMe '{}' 20) || return 1
  printf '%s' "$raw" | jq -e --arg id "$ZALO_BOT_ID" '.ok == true and ((.result.id // .result.bot_id // "") | tostring) == $id' >/dev/null 2>&1
}

send_reply() { # <text>
  local text=$1 payload raw
  [ -n "$text" ] && [ "${#text}" -le 2000 ] || return 1
  payload=$(jq -n --arg chat "$ZALO_GROUP_ID" --arg text "$text" '{chat_id:$chat, text:$text}')
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
  need jq
  need curl
  printf 'configured: exact Zalo group, exact Graph folder, read-only handler\n'
}

cmd_source_status() {
  local status
  load_config
  need jq
  need curl
  source_status
  status=$(printf '%s' "$SOURCE_STATUS_JSON" | jq -r '.status')
  case "$status" in
    fresh|stale)
      printf '%s' "$SOURCE_STATUS_JSON" | jq '{status, latest_modified_at, direct_file_count}'
      ;;
    *)
      printf '%s\n' '{"status":"unavailable"}'
      ;;
  esac
  GRAPH_ACCESS_TOKEN=
}

cmd_handle() {
  local event
  load_config
  need jq
  need curl
  event=$(cat)
  handle_event_json "$event"
}

cmd_reply() {
  local text
  [ "$#" -eq 0 ] || die 'reply accepts text only on stdin'
  load_config
  need jq
  need curl
  text=$(cat)
  verify_bot || die 'bot identity check failed'
  send_reply "$text" || die 'fixed-group reply failed or had an unknown outcome'
  printf 'reply accepted by Zalo\n'
}

cmd_run() {
  local raw event result action answer code
  load_config
  need jq
  need curl
  need flock
  init_state
  exec 9> "$STATE_DIR/run.lock"
  flock -n 9 || die 'another folder-Q&A bridge is already running'
  verify_bot || die 'bot identity check failed'
  log 'ready for the configured group and read-only folder'
  while :; do
    raw=$(zalo_request getUpdates '{"timeout":30}' 40) || die 'getUpdates transport failed'
    if ! printf '%s' "$raw" | jq -e '.ok == true and (.result | type == "object")' >/dev/null 2>&1; then
      code=$(printf '%s' "$raw" | jq -r '.error_code // empty' 2>/dev/null || true)
      [ "$code" = 408 ] && continue
      die 'getUpdates was refused'
    fi
    event=$(printf '%s' "$raw" | jq -c '.result')
    parse_event "$event"
    if [ "$EVENT_ACTION" = query ] && ! seen_or_reserve "$EVENT_MESSAGE_ID"; then
      continue
    fi
    result=$(handle_event_json "$event")
    action=$(printf '%s' "$result" | jq -r '.action')
    [ "$action" = reply ] || continue
    answer=$(printf '%s' "$result" | jq -r '.answer')
    if ! send_reply "$answer"; then
      die 'fixed-group reply failed or had an unknown outcome; duplicate replay is suppressed'
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
  reply)
    shift
    cmd_reply "$@"
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
