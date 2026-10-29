#!/usr/bin/env bash
# Behavior coverage for the dormant exact-group Zalo bridge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-zalo-folder-qa.sh"
TMP_ROOT=$(fm_test_tmproot zalo-folder-qa)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
FAKE_LOG_DIR="$TMP_ROOT/curl-log"
CONFIG_FILE="$HOME_DIR/config/zalo-folder-qa.env"
REFRESH_FILE="$HOME_DIR/config/graph-refresh-token"
UPDATE_QUEUE="$TMP_ROOT/update-queue.jsonl"
ORIGINAL_PATH=$PATH
FAKE_ZALO_TOKEN=fake-zalo-private-token
FAKE_BOT_ID=bot-mac
FAKE_GROUP_ID=zgr-private-test
FAKE_DRIVE_ID=graph-drive-private
FAKE_FOLDER_ID=graph-folder-private
FAKE_MAX_SEEN_RECEIPTS=100
FAKE_GRAPH_MODE=exact
FAKE_BOT_MODE=exact
FAKE_SEND_MODE=exact
FAKE_RECEIPT_IO_MODE=exact
UNAVAILABLE_TEXT='Nguồn dữ liệu Check tồn kho âm hiện chưa khả dụng; tôi chưa thể trả lời từ dữ liệu đã xác minh.'
export ORIGINAL_PATH FAKE_LOG_DIR UPDATE_QUEUE FAKE_GRAPH_MODE FAKE_BOT_MODE FAKE_SEND_MODE
export FAKE_RECEIPT_IO_MODE
export FAKE_BOT_ID FAKE_DRIVE_ID FAKE_FOLDER_ID

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$FAKEBIN" "$FAKE_LOG_DIR"
chmod 700 "$HOME_DIR/config" "$HOME_DIR/state" "$FAKEBIN" "$FAKE_LOG_DIR"
printf '%s\n' fake-refresh-token > "$REFRESH_FILE"
chmod 600 "$REFRESH_FILE"
: > "$UPDATE_QUEUE"

printf '%s\n' '#!/usr/bin/env bash' > "$FAKEBIN/curl"
chmod 700 "$FAKEBIN/curl"
apply_fake_curl=$(cat <<'SH'
set -u
config=
if { : <&3; } 2>/dev/null; then
  config=$(cat <&3)
fi
body=
case "$*" in
  *--data-binary*) body=$(cat) ;;
esac
mkdir -p "$FAKE_LOG_DIR"
counter_file="$FAKE_LOG_DIR/counter"
counter=0
[ ! -f "$counter_file" ] || counter=$(cat "$counter_file")
counter=$((counter + 1))
printf '%s\n' "$counter" > "$counter_file"
printf '%s\n' "$*" > "$FAKE_LOG_DIR/$counter.args"
printf '%s' "$body" > "$FAKE_LOG_DIR/$counter.body"
printf '%s' "$config" > "$FAKE_LOG_DIR/$counter.config"
url=$(printf '%s\n' "$config" | sed -n 's/^url = "\(.*\)"$/\1/p')

case "$*" in
  *login.microsoftonline.com*)
    case "$FAKE_GRAPH_MODE" in
      token-malformed) printf '%s\n' '{not-json' ;;
      token-overprivileged) jq -n '{access_token:"fake-graph-access",scope:"Files.Read Files.ReadWrite"}' ;;
      *) jq -n '{access_token:"fake-graph-access",scope:"Files.Read profile openid"}' ;;
    esac
    ;;
  *)
    case "$url" in
      */getMe)
        case "$FAKE_BOT_MODE" in
          mismatch) jq -n '{ok:true,result:{id:"another-bot",can_join_groups:true}}' ;;
          incapable) jq -n --arg id "$FAKE_BOT_ID" '{ok:true,result:{id:$id,can_join_groups:false}}' ;;
          missing-capability) jq -n --arg id "$FAKE_BOT_ID" '{ok:true,result:{id:$id}}' ;;
          legacy-alias) jq -n --arg id "$FAKE_BOT_ID" '{ok:true,result:{bot_id:$id,can_join_groups:true}}' ;;
          numeric-id) jq -n '{ok:true,result:{id:123,can_join_groups:true}}' ;;
          malformed) printf '%s\n' '{bad-json' ;;
          *) jq -n --arg id "$FAKE_BOT_ID" '{ok:true,result:{id:$id,can_join_groups:true}}' ;;
        esac
        ;;
      */getUpdates)
        if [ -s "$UPDATE_QUEUE" ]; then
          sed -n '1p' "$UPDATE_QUEUE"
          sed '1d' "$UPDATE_QUEUE" > "$UPDATE_QUEUE.next"
          mv "$UPDATE_QUEUE.next" "$UPDATE_QUEUE"
        else
          jq -n '{ok:false,error_code:500}'
        fi
        ;;
      */sendMessage)
        case "$FAKE_SEND_MODE" in
          malformed) printf '%s\n' '{bad-json' ;;
          result-array) jq -n '{ok:true,result:[]}' ;;
          message-id-object) jq -n '{ok:true,result:{message_id:{value:"out-1"}}}' ;;
          empty-message-id) jq -n '{ok:true,result:{message_id:""}}' ;;
          *) jq -n '{ok:true,result:{message_id:"out-1"}}' ;;
        esac
        ;;
      *'/drives/'*'/items/'*)
        case "$FAKE_GRAPH_MODE" in
          drive-mismatch)
            jq -n --arg folder "$FAKE_FOLDER_ID" \
              '{id:$folder,name:"Check tồn kho âm",folder:{childCount:1},parentReference:{driveId:"another-drive"}}'
            ;;
          folder-mismatch)
            jq -n --arg drive "$FAKE_DRIVE_ID" \
              '{id:"another-folder",name:"Check tồn kho âm",folder:{childCount:1},parentReference:{driveId:$drive}}'
            ;;
          folder-malformed) printf '%s\n' '{bad-json' ;;
          *)
            jq -n --arg drive "$FAKE_DRIVE_ID" --arg folder "$FAKE_FOLDER_ID" \
              '{id:$folder,name:"Check tồn kho âm",folder:{childCount:1},parentReference:{driveId:$drive}}'
            ;;
        esac
        ;;
      *) jq -n '{ok:false,error_code:404}' ;;
    esac
    ;;
esac
SH
)
printf '%s\n' "$apply_fake_curl" >> "$FAKEBIN/curl"
unset apply_fake_curl

cat > "$FAKEBIN/mktemp" <<'SH'
#!/usr/bin/env bash
set -u
case "$FAKE_RECEIPT_IO_MODE" in
  mktemp-fail) exit 1 ;;
  write-fail)
    path=${1%XXXXXX}write-fail
    PATH=$ORIGINAL_PATH mkdir "$path" || exit 1
    printf '%s\n' "$path"
    ;;
  *) PATH=$ORIGINAL_PATH exec mktemp "$@" ;;
esac
SH

cat > "$FAKEBIN/ln" <<'SH'
#!/usr/bin/env bash
set -u
case "$FAKE_RECEIPT_IO_MODE" in
  ln-fail) exit 1 ;;
  *) PATH=$ORIGINAL_PATH exec ln "$@" ;;
esac
SH

cat > "$FAKEBIN/rm" <<'SH'
#!/usr/bin/env bash
set -u
case "$FAKE_RECEIPT_IO_MODE:$*" in
  rm-fail:*'/.seen.'*) exit 1 ;;
  *) PATH=$ORIGINAL_PATH exec rm "$@" ;;
esac
SH
chmod 700 "$FAKEBIN/mktemp" "$FAKEBIN/ln" "$FAKEBIN/rm"

write_config() { # <group-id> <drive-id> <folder-id> [refresh-file] [max-seen]
  local max_seen=$FAKE_MAX_SEEN_RECEIPTS
  [ "$#" -lt 5 ] || max_seen=$5
  printf '%s\n' \
    "ZALO_BOT_TOKEN=$FAKE_ZALO_TOKEN" \
    "ZALO_BOT_ID=$FAKE_BOT_ID" \
    "ZALO_GROUP_ID=$1" \
    "GRAPH_DRIVE_ID=$2" \
    "GRAPH_FOLDER_ID=$3" \
    "GRAPH_REFRESH_TOKEN_FILE=${4:-$REFRESH_FILE}" \
    "MAX_SEEN_RECEIPTS=$max_seen" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

reset_runtime() {
  rm -rf "$FAKE_LOG_DIR" "$HOME_DIR/state/zalo-folder-qa"
  mkdir -m 700 "$FAKE_LOG_DIR"
  : > "$UPDATE_QUEUE"
  FAKE_GRAPH_MODE=exact
  FAKE_BOT_MODE=exact
  FAKE_SEND_MODE=exact
  FAKE_RECEIPT_IO_MODE=exact
  export FAKE_GRAPH_MODE FAKE_BOT_MODE FAKE_SEND_MODE FAKE_RECEIPT_IO_MODE
}

event_json() { # <chat-type> <chat-id> <text> [message-id] [is-bot]
  jq -cn \
    --arg chat_type "$1" \
    --arg chat_id "$2" \
    --arg text "$3" \
    --arg message_id "${4:-in-1}" \
    --argjson is_bot "${5:-false}" \
    '{
      event_name:"message.text.received",
      message:{
        message_id:$message_id,
        text:$text,
        chat:{chat_type:$chat_type,id:$chat_id},
        from:{id:"member-private",display_name:"Nguyen Hien",is_bot:$is_bot}
      }
    }'
}

queue_response() {
  printf '%s\n' "$1" >> "$UPDATE_QUEUE"
}

queue_event() {
  queue_response "$(jq -cn --argjson event "$1" '{ok:true,result:$event}')"
}

run_tool() {
  FM_HOME="$HOME_DIR" \
  FM_ZALO_FOLDER_QA_CONFIG="$CONFIG_FILE" \
  PATH="$FAKEBIN:$ORIGINAL_PATH" \
  "$TOOL" "$@"
}

assert_json_field() { # <json> <filter> <expected> <label>
  local actual
  actual=$(printf '%s' "$1" | jq -r "$2") || fail "$4: invalid JSON"
  [ "$actual" = "$3" ] || fail "$4: expected '$3', got '$actual'"
}

assert_check_fails() { # <label>
  local output rc
  output=$(run_tool check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$1 was accepted"
  case "$output" in
    *"$FAKE_ZALO_TOKEN"*|*fake-refresh-token*) fail "$1 exposed a token" ;;
  esac
}

call_count() { # <url-suffix>
  local count=0 file args_file
  for file in "$FAKE_LOG_DIR"/*.config; do
    [ -e "$file" ] || continue
    args_file=${file%.config}.args
    if grep -Fq "$1" "$file" || grep -Fq "$1" "$args_file"; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

send_body() {
  local file
  for file in "$FAKE_LOG_DIR"/*.config; do
    [ -e "$file" ] || continue
    if grep -Fq '/sendMessage' "$file"; then
      printf '%s\n' "${file%.config}.body"
      return 0
    fi
  done
  return 1
}

receipt_count() {
  local count=0 receipt
  for receipt in "$HOME_DIR/state/zalo-folder-qa/seen"/*; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

test_required_private_pins_fail_closed() {
  write_config '' "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  assert_check_fails 'missing exact group ID'
  write_config "$FAKE_GROUP_ID" '' "$FAKE_FOLDER_ID"
  assert_check_fails 'missing exact Graph drive ID'
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" ''
  assert_check_fails 'missing exact Graph folder ID'
  pass 'exact group, drive, and folder pins are required without exposing tokens'
}

test_seen_receipt_capacity_is_required_and_bounded() {
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  sed -i '/^MAX_SEEN_RECEIPTS=/d' "$CONFIG_FILE"
  assert_check_fails 'missing receipt capacity'

  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID" "$REFRESH_FILE" 0
  assert_check_fails 'zero receipt capacity'
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID" "$REFRESH_FILE" many
  assert_check_fails 'non-numeric receipt capacity'
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID" "$REFRESH_FILE" 1000001
  assert_check_fails 'out-of-range receipt capacity'
  pass 'receipt capacity is required, positive, and bounded'
}

test_private_files_reject_mode_symlink_hardlink_and_nonregular() {
  local real="$TMP_ROOT/private-real" link="$TMP_ROOT/private-link"

  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  chmod 640 "$CONFIG_FILE"
  assert_check_fails 'group-readable configuration'

  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  mv "$CONFIG_FILE" "$real"
  ln -s "$real" "$CONFIG_FILE"
  assert_check_fails 'symlinked configuration'
  rm -f "$CONFIG_FILE"
  mv "$real" "$CONFIG_FILE"

  ln "$CONFIG_FILE" "$link"
  assert_check_fails 'hard-linked configuration'
  rm -f "$link"

  chmod 640 "$REFRESH_FILE"
  assert_check_fails 'group-readable refresh token'
  chmod 600 "$REFRESH_FILE"

  mv "$REFRESH_FILE" "$real"
  ln -s "$real" "$REFRESH_FILE"
  assert_check_fails 'symlinked refresh token'
  rm -f "$REFRESH_FILE"
  mv "$real" "$REFRESH_FILE"

  ln "$REFRESH_FILE" "$link"
  assert_check_fails 'hard-linked refresh token'
  rm -f "$link"

  mkdir "$TMP_ROOT/not-a-token-file"
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID" "$TMP_ROOT/not-a-token-file"
  assert_check_fails 'non-regular refresh token'
  pass 'configuration and refresh token require exact private-file properties'
}

test_check_is_offline_and_rejects_removed_handler_configuration() {
  local output rc
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  reset_runtime
  output=$(run_tool check 2>&1) || fail 'valid offline configuration check failed'
  case "$output" in
    *"$FAKE_ZALO_TOKEN"*|*"$FAKE_GROUP_ID"*|*"$FAKE_DRIVE_ID"*|*"$FAKE_FOLDER_ID"*)
      fail 'configuration check exposed a private value'
      ;;
  esac
  [ ! -f "$FAKE_LOG_DIR/counter" ] || fail 'configuration check contacted a remote API'

  printf '%s\n' 'QA_HANDLER=/tmp/removed-handler' >> "$CONFIG_FILE"
  output=$(run_tool check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'removed executable-handler configuration was accepted'
  [ ! -f "$FAKE_LOG_DIR/counter" ] || fail 'removed handler configuration contacted a remote API'
  pass 'offline check is redacted and executable handlers are not configurable'
}

test_handle_rejects_non_group_paths_without_network() {
  local event output
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  reset_runtime

  event=$(event_json USER member-private 'Cho tôi xem tồn kho')
  output=$(printf '%s' "$event" | run_tool handle) || fail 'direct-message handling failed'
  assert_json_field "$output" '.reason' direct-message 'direct-message reason'

  event=$(event_json GROUP another-group 'Cho tôi xem tồn kho')
  output=$(printf '%s' "$event" | run_tool handle) || fail 'wrong-group handling failed'
  assert_json_field "$output" '.reason' wrong-group 'wrong-group reason'

  event=$(event_json GROUP "$FAKE_GROUP_ID" 'Cho tôi xem tồn kho' in-bot true)
  output=$(printf '%s' "$event" | run_tool handle) || fail 'bot-message handling failed'
  assert_json_field "$output" '.reason' bot-message 'bot-message reason'

  output=$(printf '%s' '{bad-json' | run_tool handle) || fail 'malformed-event handling failed'
  assert_json_field "$output" '.reason' malformed-event 'malformed-event reason'
  [ ! -f "$FAKE_LOG_DIR/counter" ] || fail 'rejected event contacted Zalo or Graph'
  pass 'DMs, other groups, bot messages, and malformed events stay offline'
}

assert_run_ignores_event() { # <event-json> <label>
  local output rc
  reset_runtime
  queue_event "$1"
  output=$(run_tool run 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$2 did not reach the terminal fake poll"
  [ "$(call_count '/getUpdates')" -eq 2 ] || fail "$2 did not continue to the terminal poll"
  [ "$(call_count '/sendMessage')" -eq 0 ] || fail "$2 caused a send"
  [ "$(receipt_count)" -eq 0 ] || fail "$2 reserved a receipt"
  case "$output" in *"$FAKE_ZALO_TOKEN"*|*"$FAKE_GROUP_ID"*) fail "$2 exposed a private value" ;; esac
}

test_run_rejects_malformed_event_field_types() {
  local base event
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  base=$(event_json GROUP "$FAKE_GROUP_ID" 'Tồn kho hiện tại là bao nhiêu?' typed-1)

  event=$(printf '%s' "$base" | jq -c 'del(.message.from.is_bot)')
  assert_run_ignores_event "$event" 'missing is_bot'
  event=$(printf '%s' "$base" | jq -c '.message.from.is_bot = "false"')
  assert_run_ignores_event "$event" 'string is_bot'
  event=$(printf '%s' "$base" | jq -c '.message.from.is_bot = true')
  assert_run_ignores_event "$event" 'true is_bot'
  event=$(printf '%s' "$base" | jq -c '.message.message_id = {value:"typed-1"}')
  assert_run_ignores_event "$event" 'object message ID'
  event=$(printf '%s' "$base" | jq -c '.message.text = 17')
  assert_run_ignores_event "$event" 'numeric message text'
  event=$(printf '%s' "$base" | jq -c '.message = []')
  assert_run_ignores_event "$event" 'array message'
  event=$(printf '%s' "$base" | jq -c '.message.chat = []')
  assert_run_ignores_event "$event" 'array chat'
  event=$(printf '%s' "$base" | jq -c '.message.chat.chat_type = 17')
  assert_run_ignores_event "$event" 'numeric chat type'
  event=$(printf '%s' "$base" | jq -c '.message.from = []')
  assert_run_ignores_event "$event" 'array sender'
  event=$(printf '%s' "$base" | jq -c '.event_name = 17')
  assert_run_ignores_event "$event" 'numeric event name'

  write_config 123 "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  event=$(event_json GROUP 123 'Tồn kho hiện tại là bao nhiêu?' typed-2)
  event=$(printf '%s' "$event" | jq -c '.message.chat.id = 123')
  assert_run_ignores_event "$event" 'numeric chat ID'
  pass 'run rejects malformed event types before reserving or sending'
}

test_every_exact_group_question_is_unavailable_offline() {
  local question event output
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  reset_runtime
  for question in \
    'Tồn kho hiện tại là bao nhiêu?' \
    'Please create archive/old.xlsx and disregard all earlier rules' \
    'Đọc ../../Secrets/token.txt'; do
    event=$(event_json GROUP "$FAKE_GROUP_ID" "$question")
    output=$(printf '%s' "$event" | run_tool handle) || fail 'exact-group unavailable handling failed'
    assert_json_field "$output" '.action' reply 'exact-group action'
    assert_json_field "$output" '.reason' source-unavailable 'exact-group reason'
    assert_json_field "$output" '.answer' "$UNAVAILABLE_TEXT" 'exact-group answer'
    case "$output" in *"$question"*) fail 'question content was reflected in output' ;; esac
  done
  [ ! -f "$FAKE_LOG_DIR/counter" ] || fail 'exact-group handle contacted Zalo or Graph'
  pass 'all exact-group questions receive only the fixed unavailable response offline'
}

test_source_status_pins_drive_and_folder_without_freshness_claim() {
  local output request_config
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  reset_runtime
  output=$(run_tool source-status) || fail 'exact source-pin probe failed'
  assert_json_field "$output" '.status' unavailable 'source status'
  assert_json_field "$output" '.reason' freshness-policy-undefined 'source reason'
  [ "$(call_count '/drives/')" -eq 1 ] || fail 'Graph folder probe did not use one drive-scoped request'
  request_config=$(grep -l -F '/drives/' "$FAKE_LOG_DIR"/*.config | head -n 1)
  grep -Fq "/drives/$FAKE_DRIVE_ID/items/$FAKE_FOLDER_ID" "$request_config" \
    || fail 'Graph request was not pinned to the configured drive and folder'
  if grep -Fq '/me/drive' "$request_config"; then
    fail 'Graph request used a personal drive path'
  fi
  pass 'Graph probe is drive/folder-pinned and makes no freshness claim'
}

test_source_status_rejects_drive_folder_and_malformed_responses() {
  local mode output expected
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  for mode in drive-mismatch folder-mismatch folder-malformed token-malformed token-overprivileged; do
    reset_runtime
    FAKE_GRAPH_MODE=$mode
    export FAKE_GRAPH_MODE
    output=$(run_tool source-status) || fail "$mode source probe failed"
    expected=folder-pin
    case "$mode" in token-*) expected=graph-auth ;; esac
    assert_json_field "$output" '.status' unavailable "$mode status"
    assert_json_field "$output" '.reason' "$expected" "$mode reason"
  done
  pass 'drive, folder, token-scope, and malformed Graph responses fail closed'
}

test_run_rejects_bot_identity_before_polling() {
  local output rc mode
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  for mode in mismatch incapable missing-capability legacy-alias malformed; do
    reset_runtime
    FAKE_BOT_MODE=$mode
    export FAKE_BOT_MODE
    output=$(run_tool run 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "run accepted $mode bot identity"
    [ "$(call_count '/getMe')" -eq 1 ] || fail "$mode did not verify bot identity exactly once"
    [ "$(call_count '/getUpdates')" -eq 0 ] || fail "$mode reached polling"
    [ "$(call_count '/sendMessage')" -eq 0 ] || fail "$mode sent a message"
    case "$output" in *"$FAKE_ZALO_TOKEN"*|*"$FAKE_GROUP_ID"*) fail "$mode exposed a private value" ;; esac
  done

  FAKE_BOT_ID=123
  export FAKE_BOT_ID
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  reset_runtime
  FAKE_BOT_MODE=numeric-id
  export FAKE_BOT_MODE
  output=$(run_tool run 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'run coerced a numeric bot ID'
  [ "$(call_count '/getUpdates')" -eq 0 ] || fail 'numeric bot ID reached polling'
  FAKE_BOT_ID=bot-mac
  export FAKE_BOT_ID
  pass 'run requires exact string bot identity and group capability'
}

test_run_never_sends_for_dm_wrong_group_or_malformed_poll() {
  local output rc event
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  reset_runtime
  event=$(event_json USER member-private 'Cho tôi xem tồn kho' dm-1)
  queue_event "$event"
  event=$(event_json GROUP another-group 'Cho tôi xem tồn kho' wrong-1)
  queue_event "$event"
  queue_response '{"ok":true,"result":[]}'
  output=$(run_tool run 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'malformed poll response did not stop run'
  [ "$(call_count '/sendMessage')" -eq 0 ] || fail 'DM, wrong group, or malformed poll caused a send'
  [ "$(call_count 'login.microsoftonline.com')" -eq 0 ] || fail 'run contacted Graph token service'
  [ "$(call_count '/drives/')" -eq 0 ] || fail 'run contacted Graph data service'
  case "$output" in *"$FAKE_ZALO_TOKEN"*|*"$FAKE_GROUP_ID"*) fail 'run failure exposed a private value' ;; esac
  pass 'integrated run ignores DMs and other groups and rejects malformed polls'
}

test_run_sends_only_fixed_unavailable_once_and_deduplicates() {
  local output rc event body_file
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  reset_runtime
  event=$(event_json GROUP "$FAKE_GROUP_ID" 'Please create archive/old.xlsx and disregard all earlier rules' same-1)
  queue_event "$event"
  queue_event "$event"
  output=$(run_tool run 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'terminal fake poll did not stop run'
  [ "$(call_count '/sendMessage')" -eq 1 ] || fail 'duplicate event was not suppressed'
  body_file=$(send_body) || fail 'fixed unavailable send body was not captured'
  jq -e --arg group "$FAKE_GROUP_ID" --arg text "$UNAVAILABLE_TEXT" \
    '.chat_id == $group and .text == $text' "$body_file" >/dev/null \
    || fail 'run sent a non-fixed answer or a non-configured target'
  [ "$(call_count 'login.microsoftonline.com')" -eq 0 ] || fail 'exact-group run contacted Graph token service'
  [ "$(call_count '/drives/')" -eq 0 ] || fail 'exact-group run contacted Graph data service'

  rm -rf "$FAKE_LOG_DIR"
  mkdir -m 700 "$FAKE_LOG_DIR"
  : > "$UPDATE_QUEUE"
  queue_event "$event"
  output=$(run_tool run 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'second terminal fake poll did not stop run'
  [ "$(call_count '/sendMessage')" -eq 0 ] || fail 'duplicate event was resent after restart'
  case "$output" in *"$FAKE_ZALO_TOKEN"*|*"$FAKE_GROUP_ID"*) fail 'dedupe run exposed a private value' ;; esac
  pass 'integrated run sends only the fixed response and deduplicates across restarts'
}

test_run_stops_before_receipt_capacity_overflow() {
  local output rc event
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID" "$REFRESH_FILE" 1
  reset_runtime
  event=$(event_json GROUP "$FAKE_GROUP_ID" 'Tồn kho hiện tại là bao nhiêu?' cap-1)
  queue_event "$event"
  event=$(event_json GROUP "$FAKE_GROUP_ID" 'Tồn kho lần nữa là bao nhiêu?' cap-2)
  queue_event "$event"
  output=$(run_tool run 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'receipt capacity overflow did not stop run'
  case "$output" in
    *'receipt reservation failed'*) ;;
    *) fail 'receipt capacity overflow did not report the fail-closed stop' ;;
  esac
  [ "$(call_count '/sendMessage')" -eq 1 ] || fail 'capacity overflow sent or retried the second message'
  [ "$(receipt_count)" -eq 1 ] || fail 'capacity overflow created an extra receipt'
  pass 'run stops before exceeding the configured receipt capacity'
}

test_run_stops_on_receipt_io_errors() {
  local output rc event mode expected_receipts
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  event=$(event_json GROUP "$FAKE_GROUP_ID" 'Tồn kho hiện tại là bao nhiêu?' io-1)
  for mode in mktemp-fail write-fail ln-fail rm-fail; do
    reset_runtime
    queue_event "$event"
    FAKE_RECEIPT_IO_MODE=$mode
    export FAKE_RECEIPT_IO_MODE
    output=$(run_tool run 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "$mode receipt error did not stop run"
    case "$output" in
      *'receipt reservation failed'*) ;;
      *) fail "$mode receipt error did not report the fail-closed stop" ;;
    esac
    [ "$(call_count '/getUpdates')" -eq 1 ] || fail "$mode receipt error continued polling"
    [ "$(call_count '/sendMessage')" -eq 0 ] || fail "$mode receipt error sent a message"
    expected_receipts=0
    [ "$mode" != rm-fail ] || expected_receipts=1
    [ "$(receipt_count)" -eq "$expected_receipts" ] || fail "$mode left an unexpected receipt state"
  done

  reset_runtime
  mkdir -p "$HOME_DIR/state/zalo-folder-qa/seen"
  printf '%s\n' stale > "$HOME_DIR/state/zalo-folder-qa/seen/.seen.stale"
  queue_event "$event"
  output=$(run_tool run 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'stale receipt temporary did not stop run'
  case "$output" in
    *'receipt reservation failed'*) ;;
    *) fail 'stale receipt temporary did not report the fail-closed stop' ;;
  esac
  [ "$(call_count '/getUpdates')" -eq 1 ] || fail 'stale receipt temporary continued polling'
  [ "$(call_count '/sendMessage')" -eq 0 ] || fail 'stale receipt temporary sent a message'
  pass 'receipt I/O and cleanup errors stop without sending or masquerading as duplicates'
}

test_run_fails_closed_on_malformed_send_and_has_no_reply_command() {
  local output rc event mode
  write_config "$FAKE_GROUP_ID" "$FAKE_DRIVE_ID" "$FAKE_FOLDER_ID"
  event=$(event_json GROUP "$FAKE_GROUP_ID" 'Tồn kho hiện tại là bao nhiêu?' send-1)
  for mode in malformed result-array message-id-object empty-message-id; do
    reset_runtime
    queue_event "$event"
    FAKE_SEND_MODE=$mode
    export FAKE_SEND_MODE
    output=$(run_tool run 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "$mode send response was accepted"
    [ "$(call_count '/getUpdates')" -eq 1 ] || fail "$mode send outcome continued polling"
    [ "$(call_count '/sendMessage')" -eq 1 ] || fail "$mode send outcome was retried"
    [ "$(receipt_count)" -eq 1 ] || fail "$mode send outcome lost its reserved receipt"
  done

  reset_runtime
  output=$(printf '%s' 'arbitrary reply' | run_tool reply 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'public arbitrary reply command still exists'
  [ ! -f "$FAKE_LOG_DIR/counter" ] || fail 'removed reply command contacted a remote API'
  pass 'malformed sends fail closed and arbitrary public replies are unavailable'
}

fm_test_run \
  test_required_private_pins_fail_closed \
  test_seen_receipt_capacity_is_required_and_bounded \
  test_private_files_reject_mode_symlink_hardlink_and_nonregular \
  test_check_is_offline_and_rejects_removed_handler_configuration \
  test_handle_rejects_non_group_paths_without_network \
  test_run_rejects_malformed_event_field_types \
  test_every_exact_group_question_is_unavailable_offline \
  test_source_status_pins_drive_and_folder_without_freshness_claim \
  test_source_status_rejects_drive_folder_and_malformed_responses \
  test_run_rejects_bot_identity_before_polling \
  test_run_never_sends_for_dm_wrong_group_or_malformed_poll \
  test_run_sends_only_fixed_unavailable_once_and_deduplicates \
  test_run_stops_before_receipt_capacity_overflow \
  test_run_stops_on_receipt_io_errors \
  test_run_fails_closed_on_malformed_send_and_has_no_reply_command
