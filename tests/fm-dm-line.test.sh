#!/usr/bin/env bash
# End-to-end behavior tests for the session-independent captain direct-message line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LISTENER="$ROOT/bin/fm-dm-listener.sh"
INBOX="$ROOT/bin/fm-dm-inbox.sh"
REPLY="$ROOT/bin/fm-dm-reply.sh"
SERVICE="$ROOT/bin/fm-dm-service.sh"
TMP_ROOT=$(fm_test_tmproot fm-dm-line)

CAPTAIN_ID=700000001

make_home() {
  local home="$TMP_ROOT/$1" data
  data="$home/data/fm-telegram-dm"
  mkdir -p "$home/state" "$home/config" "$data"
  cat > "$data/config.env" <<'EOF'
FM_TOPIC_BOT_TOKEN=123456:test_dm_token
FM_TOPIC_CAPTAIN_ID=700000001
EOF
  chmod 600 "$data/config.env"
  printf '%s\n' "$home"
}

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  printf '%s\n' "$arg" >> "${FM_FAKE_CURL_LOG:?}"
done
printf '%s\n' END >> "$FM_FAKE_CURL_LOG"
case " $* " in
  *getUpdates*) cat "${FM_FAKE_GET_UPDATES:?}" ;;
  *sendMessage*)
    rc=${FM_FAKE_SEND_RC:-0}
    [ "$rc" -eq 0 ] || exit "$rc"
    cat "${FM_FAKE_SEND_RESPONSE:?}"
    ;;
  *) echo 'unexpected fake curl request' >&2; exit 2 ;;
esac
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

write_updates() {
  local file=$1
  shift
  jq -n --args '$ARGS.positional | map(fromjson) | {ok:true, result:.}' "$@" > "$file"
}

listener_once() {
  local home=$1 fakebin=$2 response=$3 log=$4
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_DM_POLL_TIMEOUT=0 \
    FM_DM_REMIND_SECONDS=300 \
    FM_DM_CLAIMED_REMIND_SECONDS="${FM_DM_CLAIMED_REMIND_SECONDS:-14400}" \
    FM_DM_PLUGIN_PID_FILE="$home/plugin-bot.pid" \
    FM_FAKE_GET_UPDATES="$response" \
    FM_FAKE_CURL_LOG="$log" \
    FM_FAKE_SEND_RESPONSE="$response" \
    "$LISTENER" --once
}

test_listener_accepts_only_captain_private_messages() {
  local home fakebin response log data count out
  home=$(make_home accept)
  fakebin=$(make_fake_curl "$home")
  data="$home/data/fm-telegram-dm"
  response="$home/updates.json"
  log="$home/curl.log"

  write_updates "$response" \
    "{\"update_id\":10,\"message\":{\"message_id\":100,\"chat\":{\"id\":$CAPTAIN_ID,\"type\":\"private\"},\"from\":{\"id\":$CAPTAIN_ID},\"text\":\"hello from the captain\"}}" \
    "{\"update_id\":11,\"message\":{\"message_id\":101,\"chat\":{\"id\":$CAPTAIN_ID,\"type\":\"private\"},\"from\":{\"id\":999},\"text\":\"impostor\"}}" \
    "{\"update_id\":12,\"message\":{\"message_id\":102,\"chat\":{\"id\":-100777,\"type\":\"supergroup\"},\"from\":{\"id\":$CAPTAIN_ID},\"text\":\"group noise\"}}" \
    "{\"update_id\":13,\"message\":{\"message_id\":103,\"chat\":{\"id\":$CAPTAIN_ID,\"type\":\"private\"},\"from\":{\"id\":$CAPTAIN_ID},\"photo\":[{\"file_id\":\"p1\"}],\"caption\":\"a picture\"}}"

  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener rejected valid direct messages"

  assert_present "$data/inbox/update-10.json" "captain text message was not retained"
  assert_absent "$data/inbox/update-11.json" "non-captain sender reached the private inbox"
  assert_absent "$data/inbox/update-12.json" "group message reached the direct-message inbox"
  assert_present "$data/inbox/update-13.json" "captain media message was not retained"
  [ "$(cat "$data/.poll-offset")" = 14 ] || fail "offset did not advance past the full batch"
  [ "$(jq -r '.thread_id' "$data/inbox/update-10.json")" = null ] || fail "direct message carried a forum thread id"
  [ "$(jq -r '.route' "$data/inbox/update-10.json")" = main ] || fail "direct message was not routed to main"
  [ "$(jq -r '.content_type' "$data/inbox/update-13.json")" = photo ] || fail "media content type was not classified"
  assert_grep "$(printf '\tcheck\ttopic-board\t')" "$home/state/.wake-queue" "listener did not queue a durable wake"
  assert_grep 'direct message' "$home/state/.wake-queue" "wake payload did not name the direct-message inbox"

  # Replaying the same unconfirmed batch must not duplicate or error.
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener failed while replaying an unconfirmed batch"
  count=$(find "$data/inbox" -name 'update-*.json' | wc -l | tr -d '[:space:]')
  [ "$count" = 2 ] || fail "replay changed the inbox item count to $count"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$INBOX" list)
  assert_contains "$out" "$(printf '10\tpending\tDirect message')" "inbox list omitted the direct-message item"
  pass "listener persists exactly the captain's private messages with durable replay"
}

test_listener_waits_while_plugin_poller_lives() {
  local home fakebin response log data
  home=$(make_home conflict)
  fakebin=$(make_fake_curl "$home")
  data="$home/data/fm-telegram-dm"
  response="$home/updates.json"
  log="$home/curl.log"
  write_updates "$response"

  printf '%s\n' $$ > "$home/plugin-bot.pid"
  if listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1; then
    fail "listener polled while a live plugin poller owned the token"
  fi
  [ ! -e "$log" ] || ! grep -q getUpdates "$log" || fail "listener sent getUpdates despite the live plugin poller"
  assert_absent "$data/.poll-offset" "conflict wait advanced the offset"

  printf '%s\n' 999999999 > "$home/plugin-bot.pid"
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener refused to poll after the plugin poller died"
  pass "listener yields the token to a live plugin poller and resumes when it dies"
}

test_check_config_refuses_board_token_reuse() {
  local home out
  home=$(make_home boardclash)
  mkdir -p "$home/data/fm-telegram-topics"
  cat > "$home/data/fm-telegram-topics/config.env" <<'EOF'
FM_TOPIC_BOT_TOKEN=123456:test_dm_token
FM_TOPIC_CAPTAIN_ID=700000001
EOF
  chmod 600 "$home/data/fm-telegram-topics/config.env"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTENER" --check-config 2>&1)
  expect_code 1 $? "same-token board reuse was not refused"
  assert_contains "$out" 'refusing to steal the board token' "board-token refusal did not explain the safety boundary"

  rm "$home/data/fm-telegram-topics/config.env"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTENER" --check-config 2>&1)
  expect_code 0 $? "valid direct-message config was refused: $out"
  pass "config validation refuses to consume the topic-board token"
}

test_reply_archives_and_standalone_send_records() {
  local home fakebin response log data out send_response
  home=$(make_home reply)
  fakebin=$(make_fake_curl "$home")
  data="$home/data/fm-telegram-dm"
  response="$home/updates.json"
  log="$home/curl.log"

  write_updates "$response" \
    "{\"update_id\":20,\"message\":{\"message_id\":200,\"chat\":{\"id\":$CAPTAIN_ID,\"type\":\"private\"},\"from\":{\"id\":$CAPTAIN_ID},\"text\":\"question\"}}"
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener rejected the reply fixture"

  send_response="$home/send-response.json"
  printf '{"ok":true,"result":{"message_id":900}}\n' > "$send_response"

  printf 'answer text\n' > "$home/reply.txt"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" \
    "$REPLY" 20 --text-file "$home/reply.txt" 2>&1) || fail "reply to a direct message failed: $out"
  assert_present "$data/answered/update-20.json" "answered item was not archived"
  assert_absent "$data/inbox/update-20.json" "answered item stayed in the inbox"
  grep -q 'message_thread_id' "$log" && fail "direct-chat reply sent a forum thread id"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" \
    "$REPLY" send --text-file "$home/reply.txt" 2>&1) || fail "standalone send failed: $out"
  assert_contains "$out" 'ok: message 900 sent to captain chat' "standalone send did not confirm"
  [ "$(find "$data/outbox" -name 'send-*.json' | wc -l | tr -d '[:space:]')" = 1 ] || fail "standalone send left no outbox record"
  pass "replies archive the item and standalone sends leave durable records"
}

test_claimed_item_reminds_on_the_longer_cadence() {
  local home fakebin response log data now
  home=$(make_home claimed-reminder)
  fakebin=$(make_fake_curl "$home")
  data="$home/data/fm-telegram-dm"
  response="$home/updates.json"
  log="$home/curl.log"
  : > "$log"
  write_updates "$response" \
    "{\"update_id\":25,\"message\":{\"message_id\":250,\"chat\":{\"id\":$CAPTAIN_ID,\"type\":\"private\"},\"from\":{\"id\":$CAPTAIN_ID},\"text\":\"long-running direct work\"}}"
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "could not seed claimed direct-message reminder item"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$INBOX" claim 25 main >/dev/null || fail "could not claim direct-message reminder item"

  rm -f "$home/state/.wake-queue"
  now=$(date +%s)
  printf '%s\n' "$((now - 300))" > "$data/.last-wake"
  FM_DM_CLAIMED_REMIND_SECONDS=900 listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 \
    || fail "direct-message listener failed while checking the pending reminder cadence"
  assert_absent "$home/state/.wake-queue" "claimed direct-message item re-fired on the pending reminder cadence"

  printf '%s\n' "$((now - 900))" > "$data/.last-wake"
  FM_DM_CLAIMED_REMIND_SECONDS=900 listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 \
    || fail "direct-message listener failed while checking the claimed reminder cadence"
  assert_grep 'unanswered captain direct message' "$home/state/.wake-queue" "claimed direct-message item did not resurface after the longer cadence"
  pass "claimed direct-message items use the shared longer reminder cadence"
}

test_service_unit_and_supervision_demand() {
  local home out
  home=$(make_home service)

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SERVICE" print-unit)
  assert_contains "$out" 'fm-dm-listener.sh' "rendered unit does not start the listener"
  assert_contains "$out" 'Restart=always' "rendered unit does not restart automatically"

  # shellcheck source=bin/fm-supervision-lib.sh
  . "$ROOT/bin/fm-supervision-lib.sh"
  if ! FM_HOME="$home" fm_supervision_unhealthy "$home/state" 300 "$home"; then
    fail "direct-message credentials did not require supervision with an empty fleet"
  fi
  [ "$FM_SUP_TOPIC_BOARD" = true ] || fail "supervision status did not expose direct-message demand"
  pass "service unit renders and direct-message credentials demand a live watcher"
}

test_listener_accepts_only_captain_private_messages
test_listener_waits_while_plugin_poller_lives
test_check_config_refuses_board_token_reuse
test_reply_archives_and_standalone_send_records
test_claimed_item_reminds_on_the_longer_cadence
test_service_unit_and_supervision_demand
