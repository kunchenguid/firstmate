#!/usr/bin/env bash
# Public-interface behavior tests for the disabled-by-default private Telegram
# bridge. Network I/O is replaced with a local curl executable; fixtures never
# touch a live Firstmate home, Telegram account, bot, or token.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-bridge)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
for tool in jq perl; do
  tool_dir=$(command -v "$tool" 2>/dev/null) && tool_dir=$(dirname "$tool_dir") || tool_dir=
  [ -z "$tool_dir" ] || BASE_PATH="$tool_dir:$BASE_PATH"
done
TEST_TOKEN=$(printf '%s:%s' 123456 'abcdefghijklmnopqrstuvwxyzABCDE_1234567890')

path_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cfg= data= ofile= argv=$*
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) cfg=$2; shift 2 ;;
    --data-binary) data=${2#@}; shift 2 ;;
    --output) ofile=$2; shift 2 ;;
    --write-out) shift 2 ;;
    *) shift ;;
  esac
done
url=$(sed -n 's/^url = "\(.*\)"/\1/p' "$cfg")
method=${url##*/}
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  printf 'method=%s argv=%s\n' "$method" "$argv" >> "$FAKE_CURL_LOG"
fi
count=1
if [ -n "${FAKE_CURL_COUNT_DIR:-}" ]; then
  mkdir -p "$FAKE_CURL_COUNT_DIR"
  count_file="$FAKE_CURL_COUNT_DIR/$method"
  count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$count" > "$count_file"
fi
if [ -n "${FAKE_PAYLOAD_DIR:-}" ]; then
  mkdir -p "$FAKE_PAYLOAD_DIR"
  cp "$data" "$FAKE_PAYLOAD_DIR/$method.$count.json"
fi
if [ "${FAKE_CURL_FAIL_METHOD:-}" = "$method" ]; then
  exit 7
fi
code=
body_file=
if [ -n "${FAKE_SEQUENCE_DIR:-}" ] && [ -f "$FAKE_SEQUENCE_DIR/$method.$count.code" ]; then
  code=$(cat "$FAKE_SEQUENCE_DIR/$method.$count.code")
  body_file="$FAKE_SEQUENCE_DIR/$method.$count.body"
else
  case "$method" in
    getMe) code=${FAKE_GETME_CODE:-200}; body_file=${FAKE_GETME_FILE:-} ;;
    getUpdates) code=${FAKE_GETUPDATES_CODE:-200}; body_file=${FAKE_GETUPDATES_FILE:-} ;;
    sendMessage) code=${FAKE_SEND_CODE:-200}; body_file=${FAKE_SEND_FILE:-} ;;
    *) code=404 ;;
  esac
fi
[ -z "$ofile" ] || { [ -z "$body_file" ] && : > "$ofile" || cp "$body_file" "$ofile"; }
printf '%s' "$code"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$home"
}

write_valid_config() {
  local home=$1
  mkdir -p "$home/config/telegram"
  chmod 700 "$home/config/telegram"
  jq -n --arg token "$TEST_TOKEN" \
    '{version:1,enabled:true,bot_token:$token,allowed_user_id:"42",allowed_chat_id:"42"}' \
    > "$home/config/telegram/bridge.json"
  chmod 600 "$home/config/telegram/bridge.json"
}

write_empty_updates() {
  printf '{"ok":true,"result":[]}\n' > "$1"
}

write_update() {
  local file=$1 update_id=$2 message_id=$3 user_id=$4 chat_id=$5 text=$6
  jq -n --argjson update "$update_id" --argjson message "$message_id" \
    --argjson user "$user_id" --argjson chat "$chat_id" --arg text "$text" '
      {ok:true,result:[{update_id:$update,message:{message_id:$message,from:{id:$user,is_bot:false},chat:{id:$chat,type:"private"},text:$text}}]}
    ' > "$file"
}

run_poll() {
  local home=$1 fakebin=$2 updates=$3
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_GETUPDATES_FILE="$updates" \
    "$ROOT/bin/fm-telegram-poll.sh"
}

count_wake_key() {
  local file=$1 key=$2
  awk -F '\t' -v key="$key" 'NF >= 5 && $4 == key {n++} END {print n+0}' "$file" 2>/dev/null
}

test_disabled_and_protected_config() {
  local home fakebin updates out rc external hard alias
  home=$(new_home disabled)
  fakebin=$(make_fake_curl "$home")
  updates="$home/updates.json"; write_empty_updates "$updates"
  out=$(run_poll "$home" "$fakebin" "$updates"); rc=$?
  expect_code 0 "$rc" "disabled poll"
  [ -z "$out" ] || fail "disabled bridge must be silent"
  assert_absent "$home/state/telegram" "disabled bridge created runtime state"
  assert_contains "$(cat "$ROOT/bin/fm-private-lib.sh")" "\$fh->sync" "private publication does not fsync file and directory state"

  write_valid_config "$home"
  [ "$(path_mode "$home/config/telegram")" = 700 ] || fail "config directory mode is not 0700"
  [ "$(path_mode "$home/config/telegram/bridge.json")" = 600 ] || fail "config mode is not 0600"
  chmod 644 "$home/config/telegram/bridge.json"
  run_poll "$home" "$fakebin" "$updates" >/dev/null
  assert_absent "$home/state/telegram/offset" "unsafe config advanced the offset"
  jq '.allowed_user_id="9999999999999999" | .allowed_chat_id="9999999999999999"' \
    "$home/config/telegram/bridge.json" > "$home/config/telegram/oversized-id.json"
  chmod 600 "$home/config/telegram/oversized-id.json"
  mv "$home/config/telegram/oversized-id.json" "$home/config/telegram/bridge.json"
  run_poll "$home" "$fakebin" "$updates" >/dev/null
  assert_absent "$home/state/telegram/offset" "out-of-range numeric allowlist advanced the offset"

  home=$(new_home symlink-config)
  fakebin=$(make_fake_curl "$home")
  external="$home/external.json"
  jq -n --arg token "$TEST_TOKEN" \
    '{version:1,enabled:true,bot_token:$token,allowed_user_id:"42",allowed_chat_id:"42"}' > "$external"
  chmod 600 "$external"
  mkdir -p "$home/config/telegram"; chmod 700 "$home/config/telegram"
  ln -s "$external" "$home/config/telegram/bridge.json"
  run_poll "$home" "$fakebin" "$updates" >/dev/null
  assert_absent "$home/state/telegram/offset" "symlink config advanced the offset"

  home=$(new_home hardlink-config)
  fakebin=$(make_fake_curl "$home")
  write_valid_config "$home"
  hard="$home/config/telegram/bridge.json"; alias="$home/config/telegram/alias.json"
  ln "$hard" "$alias"
  run_poll "$home" "$fakebin" "$updates" >/dev/null
  assert_absent "$home/state/telegram/offset" "hard-linked config advanced the offset"
  pass "Telegram stays inert and rejects unsafe config modes, symlinks, and hard links"
}

test_pairing_and_allowlist_negative_control() {
  local home fakebin token_file getme updates log out rc
  home=$(new_home pairing)
  fakebin=$(make_fake_curl "$home")
  token_file="$home/token"; printf '%s\n' "$TEST_TOKEN" > "$token_file"; chmod 600 "$token_file"
  getme="$home/getme.json"; printf '{"ok":true,"result":{"id":123456,"is_bot":true,"username":"fixture_bot"}}\n' > "$getme"
  updates="$home/pair-updates.json"
  printf '{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"from":{"id":42,"is_bot":false,"username":"not-retained"},"chat":{"id":42,"type":"private"},"text":"pair"}},{"update_id":2,"message":{"message_id":2,"from":{"id":88,"is_bot":false},"chat":{"id":-100,"type":"group"},"text":"ignore"}}]}\n' > "$updates"
  log="$home/curl.log"
  out=$(printf 'PAIR 42 42\n' | PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FAKE_GETME_FILE="$getme" FAKE_GETUPDATES_FILE="$updates" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-telegram-setup.sh" pair --token-file "$token_file" 2>&1); rc=$?
  expect_code 0 "$rc" "pairing"
  assert_contains "$out" "user_id=42 chat_id=42" "private candidate was not shown"
  assert_not_contains "$out" "user_id=88" "group candidate was shown"
  assert_not_contains "$out" "$TEST_TOKEN" "pairing output exposed the token"
  assert_no_grep "$TEST_TOKEN" "$log" "curl argv exposed the token"
  [ "$(path_mode "$home/config/telegram/bridge.json")" = 600 ] || fail "paired config mode is not 0600"
  rm -f "$token_file"
  ! grep -R -F "$TEST_TOKEN" "$home/state" "$log" >/dev/null 2>&1 \
    || fail "token escaped protected config into runtime data or diagnostics"

  # Threat negative control: removing the exact user allowlist must make the
  # same otherwise-valid configuration unable to activate or process input.
  jq 'del(.allowed_user_id)' "$home/config/telegram/bridge.json" > "$home/config/telegram/missing.json"
  chmod 600 "$home/config/telegram/missing.json"
  mv "$home/config/telegram/missing.json" "$home/config/telegram/bridge.json"
  write_update "$home/request.json" 10 10 42 42 'must not pass without allowlist'
  run_poll "$home" "$fakebin" "$home/request.json" >/dev/null
  assert_absent "$home/state/telegram/offset" "negative control failed: missing allowlist advanced offset"
  [ -z "$(find "$home/state/telegram/inbox" -type f -name '*.json' -print 2>/dev/null)" ] \
    || fail "negative control failed: missing allowlist accepted a request"
  pass "pairing confirms exact private IDs and removing the allowlist blocks activation"
}

test_authorization_shape_order_and_media() {
  local home fakebin updates oversized
  home=$(new_home filtering); fakebin=$(make_fake_curl "$home"); write_valid_config "$home"
  oversized=$(awk 'BEGIN { for (i=0; i<4097; i++) printf "x" }')
  jq -n --arg oversized "$oversized" '{ok:true,result:[
    {update_id:1,message:{message_id:1,from:{id:99,is_bot:false},chat:{id:99,type:"private"},text:"unauthorized secret"}},
    {update_id:2,edited_message:{message_id:2,from:{id:42,is_bot:false},chat:{id:42,type:"private"},text:"edited"}},
    {update_id:3,message:{message_id:3,from:{id:42,is_bot:false},chat:{id:42,type:"private"},text:"caption",photo:[{file_id:"x"}]}},
    {update_id:4,message:{message_id:4,from:{id:42,is_bot:false},chat:{id:42,type:"private"},text:$oversized}},
    {update_id:5,callback_query:{id:"unsupported"}},
    {update_id:6,message:{message_id:6,from:{id:"42",is_bot:false},chat:{id:"42",type:"private"},text:"typed wrong"}}
  ]}' > "$home/filter.json"
  run_poll "$home" "$fakebin" "$home/filter.json" >/dev/null
  [ "$(cat "$home/state/telegram/offset")" = 7 ] || fail "rejected valid-ID updates did not advance the offset"
  [ "$(jq -r .disposition "$home/state/telegram/updates/1.json")" = unauthorized ] || fail "unauthorized disposition missing"
  [ "$(jq -r .disposition "$home/state/telegram/updates/2.json")" = edited-message ] || fail "edited disposition missing"
  [ "$(jq -r .disposition "$home/state/telegram/updates/3.json")" = unsupported-media ] || fail "media disposition missing"
  [ "$(jq -r .disposition "$home/state/telegram/updates/4.json")" = oversized ] || fail "oversized disposition missing"
  [ "$(jq -r .disposition "$home/state/telegram/updates/5.json")" = unsupported-update ] || fail "unsupported disposition missing"
  [ "$(jq -r .disposition "$home/state/telegram/updates/6.json")" = malformed ] || fail "malformed numeric identity disposition missing"
  [ -z "$(find "$home/state/telegram/inbox" -type f -name '*.json' -print)" ] || fail "rejected input reached the inbox"
  ! grep -R -F 'unauthorized secret' "$home/state/telegram" >/dev/null 2>&1 || fail "unauthorized body was retained"

  home=$(new_home ordering); fakebin=$(make_fake_curl "$home"); write_valid_config "$home"
  printf '{"ok":true,"result":[{"update_id":2},{"update_id":1}]}\n' > "$home/out-of-order.json"
  run_poll "$home" "$fakebin" "$home/out-of-order.json" >/dev/null
  assert_absent "$home/state/telegram/offset" "out-of-order response advanced offset"
  printf '{"ok":true,"result":[{"update_id":2},{"update_id":2}]}\n' > "$home/duplicate.json"
  run_poll "$home" "$fakebin" "$home/duplicate.json" >/dev/null
  assert_absent "$home/state/telegram/offset" "duplicate response advanced offset"
  pass "unauthorized, edited, media, oversized, malformed, duplicate, and out-of-order updates fail closed"
}

test_persist_before_offset_and_one_wake() {
  local home fakebin updates out rc request hostile fields
  home=$(new_home crash-recovery); fakebin=$(make_fake_curl "$home"); write_valid_config "$home"
  # shellcheck disable=SC2016 # Literal command-substitution text is an encoding fixture.
  hostile=$(printf 'line one\nline two\t$(touch /tmp/not-run)')
  updates="$home/update.json"; write_update "$updates" 200 77 42 42 "$hostile"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_GETUPDATES_FILE="$updates" \
    FMTG_TEST_CRASH_AFTER_PERSIST=1 "$ROOT/bin/fm-telegram-poll.sh" 2>&1); rc=$?
  expect_code 91 "$rc" "persist-before-offset crash seam"
  assert_present "$home/state/telegram/inbox/tg-200-77.json" "request was not durable before crash"
  assert_present "$home/state/telegram/updates/200.json" "update journal was not durable before crash"
  # Threat negative control: this assertion fails immediately if offset
  # advancement is moved ahead of the two durable publications above.
  assert_absent "$home/state/telegram/offset" "negative control failed: offset advanced before durable recovery point"

  out=$(run_poll "$home" "$fakebin" "$updates"); rc=$?
  expect_code 0 "$rc" "crash recovery poll"
  [ "$(cat "$home/state/telegram/offset")" = 201 ] || fail "recovery did not advance offset exactly once"
  [ "$(count_wake_key "$home/state/.wake-queue" tg-200-77)" = 1 ] || fail "recovery queued the request more than once"
  request=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-request.sh" show tg-200-77)
  [ "$(printf '%s' "$request" | jq -r .text)" = "$hostile" ] || fail "request text encoding changed"
  fields=$(awk -F '\t' '$4 == "tg-200-77" {print NF ":" $5}' "$home/state/.wake-queue")
  [ "$fields" = '5:telegram-request tg-200-77' ] || fail "wake payload included body data or invalid fields"
  run_poll "$home" "$fakebin" "$updates" >/dev/null
  [ "$(count_wake_key "$home/state/.wake-queue" tg-200-77)" = 1 ] || fail "replay duplicated the durable wake"
  pass "inbound persistence precedes offset advancement and crash recovery emits one body-free wake"
}

send_file() {
  local path=$1 text=$2
  printf '%s' "$text" > "$path"
  chmod 600 "$path"
}

test_exact_approval_and_sent_receipts() {
  local home fakebin counts updates send_body text out rc request
  home=$(new_home approval); fakebin=$(make_fake_curl "$home"); write_valid_config "$home"
  counts="$home/counts"; mkdir -p "$counts"
  updates="$home/request.json"; write_update "$updates" 1 10 42 42 'prepare the release decision'
  FAKE_CURL_COUNT_DIR="$counts" run_poll "$home" "$fakebin" "$updates" >/dev/null
  send_body="$home/send.json"; printf '{"ok":true,"result":{"message_id":900}}\n' > "$send_body"
  text="$home/text"; send_file "$text" 'Approve with /approve release-42 or deny with /deny release-42.'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_SEND_FILE="$send_body" \
    FAKE_CURL_COUNT_DIR="$counts" "$ROOT/bin/fm-telegram-send.sh" reply tg-1-10 reply-1 \
    --text-file "$text" --approval-id release-42 2>&1); rc=$?
  expect_code 0 "$rc" "approval decision send"
  assert_contains "$out" 'sent reply-1 900' "sent receipt output missing"
  [ "$(jq -r .state "$home/state/telegram/outbound/reply-1.json")" = sent ] || fail "sent receipt state missing"
  assert_absent "$home/state/telegram/inbox/tg-1-10.json" "sent reply retained inbound message body"
  [ "$(jq -r .status "$home/state/telegram/approvals/release-42.json")" = pending ] || fail "approval binding not pending"

  jq -n '{ok:true,result:[
    {update_id:2,message:{message_id:11,from:{id:42,is_bot:false},chat:{id:42,type:"private"},text:"/approve release-42",reply_to_message:{message_id:900}}},
    {update_id:3,message:{message_id:12,from:{id:42,is_bot:false},chat:{id:42,type:"private"},text:"/approve release-42",reply_to_message:{message_id:900}}},
    {update_id:4,message:{message_id:13,from:{id:42,is_bot:false},chat:{id:42,type:"private"},text:"/approve release-42",reply_to_message:{message_id:899}}}
  ]}' > "$home/approvals.json"
  run_poll "$home" "$fakebin" "$home/approvals.json" >/dev/null
  request=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-request.sh" show tg-2-11)
  [ "$(printf '%s' "$request" | jq -r .approval_id)" = release-42 ] || fail "exact approval did not bind"
  [ "$(printf '%s' "$request" | jq -r .approval_decision)" = approve ] || fail "exact approval decision missing"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-telegram-request.sh" show tg-3-12 | jq -r .approval_id)" = null ] \
    || fail "replayed approval retained authority"
  # Threat negative control: removing exact reply correlation must revoke
  # approval authority even when the text and approval ID still match.
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-telegram-request.sh" show tg-4-13 | jq -r .approval_id)" = null ] \
    || fail "negative control failed: wrong reply correlation authorized the action"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_SEND_FILE="$send_body" \
    FAKE_CURL_COUNT_DIR="$counts" "$ROOT/bin/fm-telegram-send.sh" reply tg-1-10 reply-1 \
    --text-file "$text" --approval-id release-42 2>&1); rc=$?
  expect_code 0 "$rc" "sent receipt dedupe"
  [ "$(cat "$counts/sendMessage")" = 1 ] || fail "sent receipt was dispatched twice"
  pass "approval authority requires one exact direct-reply correlation and sent receipts deduplicate"
}

test_outbound_failure_states_quiet_filter_and_redaction() {
  local home fakebin counts body text out rc before sequence
  home=$(new_home outbound); fakebin=$(make_fake_curl "$home"); write_valid_config "$home"
  counts="$home/counts"; mkdir -p "$counts"
  text="$home/text"; send_file "$text" 'Captain-relevant fixture result.'
  body="$home/rejected.json"; printf '{"ok":false,"description":"fixture rejection"}\n' > "$body"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_SEND_FILE="$body" FAKE_SEND_CODE=400 \
    FAKE_CURL_COUNT_DIR="$counts" "$ROOT/bin/fm-telegram-send.sh" notify failure fail-1 --text-file "$text" 2>&1); rc=$?
  expect_code 1 "$rc" "definite HTTP rejection"
  [ "$(jq -r .state "$home/state/telegram/outbound/fail-1.json")" = definite-failure ] || fail "definite failure state missing"
  assert_not_contains "$out" 'fixture rejection' "Telegram body leaked into diagnostic"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_FAIL_METHOD=sendMessage \
    FAKE_CURL_COUNT_DIR="$counts" "$ROOT/bin/fm-telegram-send.sh" notify deployment uncertain-1 --text-file "$text" 2>&1); rc=$?
  expect_code 3 "$rc" "ambiguous transport"
  [ "$(jq -r .state "$home/state/telegram/outbound/uncertain-1.json")" = uncertain ] || fail "uncertain state missing"
  before=$(cat "$counts/sendMessage")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_SEND_FILE="$body" FAKE_CURL_COUNT_DIR="$counts" \
    "$ROOT/bin/fm-telegram-send.sh" notify deployment uncertain-1 --text-file "$text" >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "uncertain retry refusal"
  [ "$(cat "$counts/sendMessage")" = "$before" ] || fail "uncertain receipt retried network delivery"

  before=$(cat "$counts/sendMessage")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_COUNT_DIR="$counts" \
    "$ROOT/bin/fm-telegram-send.sh" notify raw-progress ignored-1 --text-file "$text" >/dev/null; rc=$?
  expect_code 0 "$rc" "quiet notification filter"
  [ "$(cat "$counts/sendMessage")" = "$before" ] || fail "quiet filter dispatched a raw progress event"
  assert_absent "$home/state/telegram/outbound/ignored-1.json" "quiet filter wrote a receipt"

  sequence="$home/sequence"; mkdir -p "$sequence"
  printf '429\n' > "$sequence/sendMessage.1.code"
  printf '{"ok":false,"parameters":{"retry_after":1}}\n' > "$sequence/sendMessage.1.body"
  printf '200\n' > "$sequence/sendMessage.2.code"
  printf '{"ok":true,"result":{"message_id":901}}\n' > "$sequence/sendMessage.2.body"
  counts="$home/retry-counts"; mkdir -p "$counts"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_SEQUENCE_DIR="$sequence" FAKE_CURL_COUNT_DIR="$counts" \
    "$ROOT/bin/fm-telegram-send.sh" notify pr-green retry-1 --text-file "$text" >/dev/null; rc=$?
  expect_code 0 "$rc" "bounded 429 retry"
  [ "$(cat "$counts/sendMessage")" = 2 ] || fail "429 retry was not bounded to the explicit recovery"
  ! grep -R -F "$TEST_TOKEN" "$home/state" >/dev/null 2>&1 || fail "token leaked into receipts or error wakes"
  ! grep -R -F 'Captain-relevant fixture result.' "$home/state/telegram/outbound" >/dev/null 2>&1 \
    || fail "outbound message body was retained in a receipt"
  pass "outbound receipts distinguish definite and uncertain delivery, bound 429 retry, redact, and filter noise"
}

test_deterministic_rich_plain_presentation() {
  local home input out snapshot before different long chunks part units fakebin body payloads sequence rc
  home=$(new_home presentation); write_valid_config "$home"
  input="$home/rich-input"
  cat > "$input" <<'EOF'
# Release summary 😀

- **Ready** for [review](https://example.test/pr/42?a=1&b=2)
- No raw buttons

> Captain-visible outcome only.

| Project | State | Next action |
| --- | --- | --- |
| Alpha 😀 | Green | Review the linked PR |

```sh
echo '<safe>'
```

Model markup stays literal: <b onclick="x">unsafe</b> & <tg-emoji emoji-id="1">x</tg-emoji>.
EOF
  chmod 600 "$input"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-render.sh" rich-1 --text-file "$input")
  assert_contains "$out" 'rendered rich-1' "renderer did not publish a snapshot"
  snapshot="$home/state/telegram/rendered/rich-1.json"
  assert_present "$snapshot" "rendered snapshot missing"
  [ "$(path_mode "$snapshot")" = 600 ] || fail "rendered snapshot is not mode 0600"
  assert_grep '&lt;b onclick=\"x\"&gt;unsafe&lt;/b&gt;' "$snapshot" "raw model HTML was not neutralized"
  assert_grep '&lt;tg-emoji emoji-id=\"1\"&gt;x&lt;/tg-emoji&gt;' "$snapshot" "raw Telegram entity was not neutralized"
  assert_grep '<b>Project:</b> Alpha 😀' "$snapshot" "wide table did not fall back to labeled records"
  assert_grep 'review (https://example.test/pr/42?a=1&b=2)' "$snapshot" "plain fallback lost a readable URL"
  assert_no_grep 'reply_markup' "$snapshot" "renderer emitted model-controlled reply markup"
  assert_no_grep 'inline_keyboard' "$snapshot" "renderer emitted a button"
  assert_not_contains "$(jq -r '.presentation.messages[].rich_text' "$snapshot")" '<tg-emoji' \
    "renderer emitted a raw custom emoji entity"
  cp "$snapshot" "$home/before.json"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-render.sh" rich-1 --text-file "$input" >/dev/null
  cmp -s "$snapshot" "$home/before.json" || fail "same receipt/source did not reuse the restart-stable snapshot"
  different="$home/different"; send_file "$different" 'different content'
  FM_HOME="$home" "$ROOT/bin/fm-telegram-render.sh" rich-1 --text-file "$different" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "presentation identity collision"

  send_file "$home/emoji" 'A😀B'
  FM_HOME="$home" "$ROOT/bin/fm-telegram-render.sh" emoji-1 --text-file "$home/emoji" >/dev/null
  [ "$(jq -r '.presentation.messages[0].display_width' "$home/state/telegram/rendered/emoji-1.json")" = 4 ] \
    || fail "emoji display width was not two cells"
  printf 'e\314\201\n' > "$home/combining"; chmod 600 "$home/combining"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-render.sh" combining-1 --text-file "$home/combining" >/dev/null
  [ "$(jq -r '.presentation.messages[0].display_width' "$home/state/telegram/rendered/combining-1.json")" = 1 ] \
    || fail "combining-mark display width was not one cell"

  long="$home/long"
  awk 'BEGIN { for (i=0; i<450; i++) printf "record-%04d 😀 https://example.test/%04d ", i, i }' > "$long"
  chmod 600 "$long"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-render.sh" split-1 --text-file "$long" >/dev/null
  chunks=$(jq -r '.presentation.messages | length' "$home/state/telegram/rendered/split-1.json")
  [ "$chunks" -gt 1 ] && [ "$chunks" -le 12 ] || fail "bounded renderer did not split into 2..12 messages"
  part=0
  while [ "$part" -lt "$chunks" ]; do
    units=$(jq -r --argjson part "$part" '.presentation.messages[$part].rich_text' "$home/state/telegram/rendered/split-1.json" \
      | perl -MEncode=decode,encode -0777 -ne '$s=decode("UTF-8", $_); print length(encode("UTF-16BE", $s))/2')
    [ "$units" -le 3501 ] || fail "rendered chunk exceeded its UTF-16 bound"
    part=$((part + 1))
  done

  fakebin=$(make_fake_curl "$home")
  body="$home/send.json"; printf '{"ok":true,"result":{"message_id":910}}\n' > "$body"
  payloads="$home/payloads"; mkdir -p "$home/ordered-counts"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_SEND_FILE="$body" FAKE_PAYLOAD_DIR="$payloads" \
    FAKE_CURL_COUNT_DIR="$home/ordered-counts" \
    "$ROOT/bin/fm-telegram-send.sh" notify pr-green ordered-1 --text-file "$long" >/dev/null
  chunks=$(jq -r '.chunks_total' "$home/state/telegram/outbound/ordered-1.json")
  [ "$(find "$payloads" -type f -name 'sendMessage.*.json' | wc -l | tr -d ' ')" = "$chunks" ] \
    || fail "ordered delivery did not dispatch every rendered part"
  [ "$(jq -r '.delivered_parts | map(.part) == [range(0; length)]' "$home/state/telegram/outbound/ordered-1.json")" = true ] \
    || fail "same-chat delivery receipts are not in strict part order"
  part=1
  while [ "$part" -le "$chunks" ]; do
    [ "$(jq -r '.parse_mode' "$payloads/sendMessage.$part.json")" = HTML ] || fail "rich part bypassed the owned HTML mode"
    jq -e 'has("reply_markup") or has("inline_keyboard") | not' "$payloads/sendMessage.$part.json" >/dev/null \
      || fail "outbound rich payload included buttons"
    part=$((part + 1))
  done

  # A definite entity-parse rejection may retry exactly once with the already
  # rendered plain snapshot; ambiguous failures still never use this path.
  sequence="$home/fallback-sequence"; mkdir -p "$sequence" "$home/fallback-counts" "$home/fallback-payloads"
  printf '400\n' > "$sequence/sendMessage.1.code"
  printf '{"ok":false,"description":"Bad Request: can not parse entities"}\n' > "$sequence/sendMessage.1.body"
  printf '200\n' > "$sequence/sendMessage.2.code"
  printf '{"ok":true,"result":{"message_id":911}}\n' > "$sequence/sendMessage.2.body"
  send_file "$home/fallback" '[Review](https://example.test/review?a=1&b=2)'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_SEQUENCE_DIR="$sequence" \
    FAKE_CURL_COUNT_DIR="$home/fallback-counts" FAKE_PAYLOAD_DIR="$home/fallback-payloads" \
    "$ROOT/bin/fm-telegram-send.sh" notify decision fallback-1 --text-file "$home/fallback" >/dev/null; rc=$?
  expect_code 0 "$rc" "definite rich validation fallback"
  [ "$(cat "$home/fallback-counts/sendMessage")" = 2 ] || fail "plain fallback was not exactly one bounded retry"
  [ "$(jq -r '.parse_mode' "$home/fallback-payloads/sendMessage.1.json")" = HTML ] || fail "first fallback attempt was not rich"
  [ "$(jq -r '.parse_mode // "plain"' "$home/fallback-payloads/sendMessage.2.json")" = plain ] || fail "second fallback attempt retained markup mode"
  assert_grep 'Review (https://example.test/review?a=1&b=2)' "$home/fallback-payloads/sendMessage.2.json" \
    "plain fallback did not retain a readable URL"
  [ "$(jq -r '.delivered_parts[0].format' "$home/state/telegram/outbound/fallback-1.json")" = plain ] \
    || fail "plain fallback format was not durably receipted"
  pass "one renderer owns safe rich/plain semantics, Unicode width, snapshots, splitting, fallback, and ordered delivery"
}

test_retention_and_runtime_harness_matrix() {
  local home fakebin updates old backend out harness
  home=$(new_home retention); fakebin=$(make_fake_curl "$home"); write_valid_config "$home"
  updates="$home/empty.json"; write_empty_updates "$updates"
  mkdir -p "$home/state/telegram/inbox" "$home/state/telegram/updates" "$home/state/telegram/outbound" "$home/state/telegram/rendered"
  chmod 700 "$home/state/telegram" "$home/state/telegram/inbox" "$home/state/telegram/updates" "$home/state/telegram/outbound" "$home/state/telegram/rendered"
  printf '{"schema":"firstmate.telegram-request.v1"}\n' > "$home/state/telegram/inbox/tg-old.json"
  printf '{}\n' > "$home/state/telegram/updates/1.json"
  printf '{}\n' > "$home/state/telegram/outbound/old.json"
  printf '{}\n' > "$home/state/telegram/rendered/old.json"
  chmod 600 "$home/state/telegram/inbox/tg-old.json" "$home/state/telegram/updates/1.json" "$home/state/telegram/outbound/old.json" "$home/state/telegram/rendered/old.json"
  old=200001010000
  touch -t "$old" "$home/state/telegram/inbox/tg-old.json" "$home/state/telegram/updates/1.json" "$home/state/telegram/outbound/old.json" "$home/state/telegram/rendered/old.json"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMTG_RETENTION_SECS=1 FAKE_GETUPDATES_FILE="$updates" \
    "$ROOT/bin/fm-telegram-poll.sh" >/dev/null
  assert_absent "$home/state/telegram/inbox/tg-old.json" "expired request body was retained"
  assert_absent "$home/state/telegram/updates/1.json" "expired update journal was retained"
  assert_absent "$home/state/telegram/outbound/old.json" "expired outbound receipt was retained"
  assert_absent "$home/state/telegram/rendered/old.json" "expired rendered snapshot was retained"
  assert_grep 'request-retention-expired' "$home/state/.wake-queue" "expired request did not wake the operator"

  for harness in claude codex opencode pi grok; do
    out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness" --telegram-mode 1)
    assert_contains "$out" "$home/config/telegram-mode.env" "$harness did not render Telegram cadence"
    assert_not_contains "$out" '__FM_TELEGRAM_MODE_ENV' "$harness leaked a Telegram placeholder"
  done

  # The authenticated check path is backend-neutral: each supported runtime
  # executes the same generated shim and exits on its already-durable wake.
  for backend in tmux herdr zellij orca cmux; do
    home=$(new_home "runtime-$backend"); fakebin=$(make_fake_curl "$home"); write_valid_config "$home"
    printf '%s\n' "$backend" > "$home/config/backend"
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
    write_update "$home/runtime-update.json" 1 1 42 42 "runtime $backend"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_GETUPDATES_FILE="$home/runtime-update.json" \
      FM_POLL=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      "$ROOT/bin/fm-watch.sh")
    assert_contains "$out" 'telegram-requests 1' "$backend watcher did not surface Telegram request"
    [ "$(count_wake_key "$home/state/.wake-queue" tg-1-1)" = 1 ] || fail "$backend watcher duplicated the Telegram wake"
  done
  pass "retention is bounded and all five harnesses plus five runtimes preserve remote supervision delivery"
}

test_disabled_and_protected_config
test_pairing_and_allowlist_negative_control
test_authorization_shape_order_and_media
test_persist_before_offset_and_one_wake
test_exact_approval_and_sent_receipts
test_outbound_failure_states_quiet_filter_and_redaction
test_deterministic_rich_plain_presentation
test_retention_and_runtime_harness_matrix

echo "All Telegram bridge tests passed."
