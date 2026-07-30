#!/usr/bin/env bash
# End-to-end behavior tests for durable Telegram topic intake, wake delivery, replies, and service installation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LISTENER="$ROOT/bin/fm-topic-listener.sh"
INBOX="$ROOT/bin/fm-topic-inbox.sh"
REPLY="$ROOT/bin/fm-topic-reply.sh"
SERVICE="$ROOT/bin/fm-topic-service.sh"
TMP_ROOT=$(fm_test_tmproot fm-topic-board)

make_home() {
  local home="$TMP_ROOT/$1" data
  data="$home/data/fm-telegram-topics"
  mkdir -p "$home/state" "$home/config" "$data"
  cat > "$data/config.env" <<'EOF'
FM_TOPIC_BOT_TOKEN=123456:test_topic_token
FM_TOPIC_CAPTAIN_ID=700000001
EOF
  chmod 600 "$data/config.env"
  cat > "$data/topic-map.json" <<'EOF'
{
  "chat_id": "-1001234567890",
  "group": "Example Dev Group",
  "bot": "@example_board_bot",
  "topics": {
    "3": {"name": "AlphaDev", "project": "Alpha's Place", "route": "alpha-mate"},
    "2": {"name": "BetaDev", "project": "Beta", "route": "beta-mate"},
    "4": {"name": "GammaDev", "project": "Gamma Retail", "route": "main"}
  }
}
EOF
  printf '%s\n' "$home"
}

make_multi_home() {
  local home data
  home=$(make_home "$1")
  data="$home/data/fm-telegram-topics"
  cat > "$data/config.env" <<'EOF'
FM_TOPIC_BOT_TOKEN=123456:test_topic_token
FM_TOPIC_CAPTAIN_ID=700000001
FM_TOPIC_APPROVED_SENDER_IDS=700000002,700000003
EOF
  chmod 600 "$data/config.env"
  cat > "$data/topic-map.json" <<'EOF'
{
  "bot": {"id": "7654321000", "username": "@example_board_bot"},
  "chats": {
    "-1001234567890": {
      "group": "Example Dev Group",
      "approved_sender_ids": ["700000001", "700000003"],
      "topics": {
        "3": {"name": "AlphaDev", "project": "Alpha's Place", "route": "alpha-mate"}
      }
    },
    "-1009876543210": {
      "group": "Second Example Group",
      "approved_sender_ids": ["700000001", "700000002"],
      "topics": {}
    }
  }
}
EOF
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
    FM_TOPIC_POLL_TIMEOUT=0 \
    FM_TOPIC_REMIND_SECONDS=300 \
    FM_TOPIC_CLAIMED_REMIND_SECONDS="${FM_TOPIC_CLAIMED_REMIND_SECONDS:-14400}" \
    FM_FAKE_GET_UPDATES="$response" \
    FM_FAKE_CURL_LOG="$log" \
    FM_FAKE_SEND_RESPONSE="$response" \
    "$LISTENER" --once
}

test_listener_is_lossless_and_topic_aware() {
  local home fakebin response log data count out status lifeline
  home=$(make_home listener-lossless)
  fakebin=$(make_fake_curl "$home")
  response="$home/updates.json"
  log="$home/curl.log"
  : > "$log"
  write_updates "$response" \
    '{"update_id":10,"message":{"message_id":101,"message_thread_id":3,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"Build the booking fix"}}' \
    '{"update_id":11,"message":{"message_id":102,"message_thread_id":3,"from":{"id":42},"chat":{"id":-1001234567890},"text":"not captain"}}' \
    '{"update_id":12,"message":{"message_id":103,"message_thread_id":99,"from":{"id":700000001},"chat":{"id":-1001234567890},"caption":"diagram","photo":[{"file_id":"p1"}]}}'

  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener rejected valid updates"
  data="$home/data/fm-telegram-topics"
  [ "$(cat "$data/.poll-offset")" = 13 ] || fail "listener did not advance offset past every inspected update"
  assert_present "$data/inbox/update-10.json" "mapped captain item was not retained"
  assert_absent "$data/inbox/update-11.json" "non-captain item reached the private inbox"
  assert_present "$data/inbox/update-12.json" "unmapped captain item was silently dropped"
  [ "$(jq -r '.route' "$data/inbox/update-10.json")" = alpha-mate ] || fail "mapped topic did not retain its secondmate route"
  [ "$(jq -r '.topic' "$data/inbox/update-10.json")" = AlphaDev ] || fail "mapped topic name was not retained"
  [ "$(jq -r '.group' "$data/inbox/update-10.json")" = "Example Dev Group" ] || fail "legacy map item did not retain its group identity"
  [ "$(jq -r '.from_id' "$data/inbox/update-10.json")" = 700000001 ] || fail "legacy map item did not retain its sender"
  [ "$(jq -r '.route' "$data/inbox/update-12.json")" = main ] || fail "unmapped topic did not fall back to main"
  [ "$(jq -r '.content_type' "$data/inbox/update-12.json")" = photo ] || fail "non-text captain message metadata was not retained"
  count=$(find "$data/inbox" -type f -name 'update-*.json' | wc -l | tr -d '[:space:]')
  [ "$count" -eq 2 ] || fail "listener persisted an unexpected inbox count: $count"
  assert_grep "$(printf '\tcheck\ttopic-board\t')" "$home/state/.wake-queue" "listener did not queue a durable topic wake"

  printf '10\n' > "$data/.poll-offset"
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener failed while replaying an unconfirmed batch"
  count=$(find "$data/inbox" -type f -name 'update-*.json' | wc -l | tr -d '[:space:]')
  [ "$count" -eq 2 ] || fail "replayed Telegram updates created duplicate inbox items"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$INBOX" list)
  assert_contains "$out" $'10\tpending\tAlphaDev\tAlpha\x27s Place\talpha-mate' "inbox list omitted topic and route context"

  lifeline="$home/direct-message.env"
  printf 'TELEGRAM_BOT_TOKEN=123456:test_topic_token\n' > "$lifeline"
  chmod 600 "$lifeline"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TOPIC_LIFELINE_CONFIG="$lifeline" "$LISTENER" --check-config 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "listener accepted the direct-message bot token for topic polling"
  assert_contains "$out" 'refusing to risk the captain lifeline' "same-token refusal did not explain the safety boundary"
  pass "listener persists before offset, survives replay exactly once, and retains mapped or unmapped captain content"
}

test_multi_chat_sender_scope_and_origin_reply() {
  local home fakebin response send_response log data out
  home=$(make_multi_home multi-chat)
  fakebin=$(make_fake_curl "$home")
  response="$home/updates.json"
  send_response="$home/send.json"
  log="$home/curl.log"
  data="$home/data/fm-telegram-topics"
  : > "$log"
  write_updates "$response" \
    '{"update_id":60,"message":{"message_id":601,"message_thread_id":77,"from":{"id":700000002},"chat":{"id":-1009876543210},"text":"second group request"}}' \
    '{"update_id":61,"message":{"message_id":602,"message_thread_id":3,"from":{"id":42},"chat":{"id":-1001234567890},"text":"unapproved sender"}}' \
    '{"update_id":62,"message":{"message_id":603,"message_thread_id":3,"from":{"id":700000001},"chat":{"id":-1005555555555},"text":"unknown group"}}' \
    '{"update_id":63,"message":{"message_id":604,"message_thread_id":77,"from":{"id":700000003},"chat":{"id":-1009876543210},"text":"approved only in group A"}}' \
    '{"update_id":64,"message":{"message_id":605,"message_thread_id":77,"from":{"id":1087968824},"chat":{"id":-1009876543210},"text":"anonymous admin"}}'

  out=$(listener_once "$home" "$fakebin" "$response" "$log" 2>&1) || fail "multi-chat listener rejected its configured second group: $out"
  assert_present "$data/inbox/update-60.json" "second configured chat message was not retained"
  assert_absent "$data/inbox/update-61.json" "unapproved sender reached the inbox"
  assert_absent "$data/inbox/update-62.json" "unconfigured chat reached the inbox"
  assert_absent "$data/inbox/update-63.json" "sender scoped only to group A reached group B"
  assert_absent "$data/inbox/update-64.json" "anonymous-admin sender reached the inbox"
  assert_contains "$out" 'unapproved sender 42' "unapproved sender rejection was not logged"
  assert_contains "$out" 'unconfigured chat -1005555555555' "unconfigured chat rejection was not logged"
  assert_contains "$out" 'not approved for chat -1009876543210' "per-chat sender rejection was not logged"
  assert_contains "$out" 'anonymous-admin sender 1087968824' "anonymous-admin rejection was not logged distinctly"
  [ "$(jq -r '.group' "$data/inbox/update-60.json")" = "Second Example Group" ] || fail "second-chat item lost its group identity"
  [ "$(jq -r '.from_id' "$data/inbox/update-60.json")" = 700000002 ] || fail "second approved sender was not retained"
  [ "$(jq -r '.route' "$data/inbox/update-60.json")" = main ] || fail "unmapped second-chat topic did not route to main"
  [ "$(jq -r '.topic' "$data/inbox/update-60.json")" = "Unmapped topic 77" ] || fail "unmapped second-chat topic lost its explicit label"

  printf '%s\n' '{"ok":true,"result":{"message_id":901,"message_thread_id":77,"chat":{"title":"Second Example Group"}}}' > "$send_response"
  printf 'Reply to the second group.' | PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" "$REPLY" 60 >/dev/null \
    || fail "reply to the second configured chat failed"
  assert_grep 'chat_id=-1009876543210' "$log" "reply did not use the item's originating second chat"
  assert_grep 'message_thread_id=77' "$log" "reply did not use the item's originating second-chat thread"
  [ "$(jq -r '.origin.chat_id' "$data/outbox/update-60-initial.json")" = -1009876543210 ] || fail "reply intent did not retain the originating second chat"
  [ "$(jq -r '.origin.group' "$data/outbox/update-60-initial.json")" = "Second Example Group" ] || fail "reply intent did not retain the originating group identity"
  [ "$(jq -r '.origin.from_id' "$data/outbox/update-60-initial.json")" = 700000002 ] || fail "reply intent did not retain the originating sender"
  pass "multi-chat intake scopes senders per group, retains origin, and replies to the originating chat"
}

test_multi_sender_config_validation_fails_closed() {
  local home data out status
  home=$(make_multi_home invalid-senders)
  data="$home/data/fm-telegram-topics"

  sed -i 's/700000002,700000003/700000002,not-an-id/' "$data/config.env"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTENER" --check-config 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "malformed credential sender allowlist was accepted"
  assert_contains "$out" 'approved Telegram sender ids' "malformed sender allowlist refusal was not explicit"

  sed -i 's/700000002,not-an-id/700000002,700000003/' "$data/config.env"
  jq '.chats["-1009876543210"].approved_sender_ids += ["not-an-id"]' "$data/topic-map.json" > "$data/topic-map.bad"
  mv "$data/topic-map.bad" "$data/topic-map.json"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTENER" --check-config 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "malformed per-chat sender allowlist was accepted"
  assert_contains "$out" 'topic map has an invalid schema' "malformed map sender refusal was not explicit"
  pass "credential and per-chat sender allowlists fail closed on malformed ids"
}

test_boundary_offset_and_failed_persistence() {
  local home fakebin response log data
  home=$(make_home offset-boundary)
  fakebin=$(make_fake_curl "$home")
  response="$home/updates.json"
  log="$home/curl.log"
  : > "$log"
  data="$home/data/fm-telegram-topics"
  printf '20\n' > "$data/.poll-offset"
  write_updates "$response" \
    '{"update_id":20,"message":{"message_id":201,"message_thread_id":2,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"boundary"}}'
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener failed at the exact offset boundary"
  [ "$(cat "$data/.poll-offset")" = 21 ] || fail "boundary update did not advance the offset"

  printf '30\n' > "$data/.poll-offset"
  mkdir "$data/inbox/update-30.json"
  write_updates "$response" \
    '{"update_id":30,"message":{"message_id":301,"message_thread_id":2,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"must persist"}}'
  if listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1; then
    fail "listener advanced despite an unwritable item destination"
  fi
  [ "$(cat "$data/.poll-offset")" = 30 ] || fail "failed item persistence advanced the durable offset"

  rmdir "$data/inbox/update-30.json"
  cat > "$fakebin/sync" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/sync"
  printf '31\n' > "$data/.poll-offset"
  write_updates "$response" \
    '{"update_id":31,"message":{"message_id":302,"message_thread_id":2,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"must flush"}}'
  if listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1; then
    fail "listener accepted an inbox write whose filesystem flush failed"
  fi
  [ "$(cat "$data/.poll-offset")" = 31 ] || fail "failed inbox flush advanced the durable offset"
  assert_absent "$data/inbox/update-31.json" "failed inbox flush published an item as durable"
  pass "offset boundary advances and persistence or flush failure leaves the update recoverable"
}

wait_for_file() {
  local file=$1 i=0
  while [ "$i" -lt 100 ]; do
    [ -e "$file" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_process_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_fast_wake_signals_only_verified_home_watcher() {
  local home fakebin response log watch_out watcher
  home=$(make_home fast-wake)
  fakebin=$(make_fake_curl "$home")
  response="$home/updates.json"
  log="$home/curl.log"
  watch_out="$home/watch.out"
  : > "$log"
  write_updates "$response" \
    '{"update_id":40,"message":{"message_id":401,"message_thread_id":3,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"wake now"}}'

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=60 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$watch_out" 2>&1 &
  watcher=$!
  if ! wait_for_file "$home/state/.watch.lock/pid" || ! wait_for_file "$home/state/.last-watcher-beat"; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    fail "test watcher did not become healthy"
  fi
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || {
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    fail "listener failed while signaling the watcher"
  }
  if ! wait_for_process_exit "$watcher" 50; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    fail "watcher did not exit within one poll interval through the USR1 fast path"
  fi
  wait "$watcher" || fail "watcher did not exit cleanly through the USR1 fast path"
  assert_grep 'check: topic-board: external event queued' "$watch_out" "watcher did not report the queued topic event"
  assert_grep "$(printf '\tcheck\ttopic-board\t')" "$home/state/.wake-queue" "fast wake lost its durable queue record"
  pass "listener queues first, then returns the identity-verified home watcher immediately"
}

test_queued_topic_wake_survives_unhandled_usr1() {
  local home fakebin response log watch_out watcher
  home=$(make_home queued-wake-fallback)
  fakebin=$(make_fake_curl "$home")
  response="$home/updates.json"
  log="$home/curl.log"
  watch_out="$home/watch.out"
  : > "$log"
  write_updates "$response" \
    '{"update_id":41,"message":{"message_id":402,"message_thread_id":3,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"wake even if signal is masked"}}'

  (
    trap '' USR1
    exec env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch.sh"
  ) > "$watch_out" 2>&1 &
  watcher=$!
  if ! wait_for_file "$home/state/.watch.lock/pid" || ! wait_for_file "$home/state/.last-watcher-beat"; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    fail "fallback test watcher did not become healthy"
  fi
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || {
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    fail "listener failed while queueing the fallback topic wake"
  }
  if ! wait_for_process_exit "$watcher" 30; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    fail "watcher left an actionable topic-board record queued after USR1 was not handled"
  fi
  wait "$watcher" || fail "watcher did not exit cleanly through the queued topic fallback"
  assert_grep 'check: topic-board: topic-message 1 unanswered' "$watch_out" "queued fallback did not emit the durable topic reason"
  assert_grep "$(printf '\tcheck\ttopic-board\t')" "$home/state/.wake-queue" "queued fallback lost its durable topic record"
  pass "a queued topic wake exits within one poll even when USR1 is not handled"
}

test_claim_reply_idempotency_and_ambiguous_delivery() {
  local home fakebin response send_response log data out status send_count
  home=$(make_home replies)
  fakebin=$(make_fake_curl "$home")
  response="$home/updates.json"
  send_response="$home/send.json"
  log="$home/curl.log"
  : > "$log"
  printf '%s\n' '{"ok":true,"result":{"message_id":900,"message_thread_id":3,"chat":{"title":"Example Dev Group"}}}' > "$send_response"
  write_updates "$response" \
    '{"update_id":50,"message":{"message_id":501,"message_thread_id":3,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"ship it"}}'
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "could not seed reply item"
  data="$home/data/fm-telegram-topics"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$INBOX" claim 50 alpha-mate >/dev/null || fail "claim failed"
  [ "$(jq -r '.status' "$data/inbox/update-50.json")" = claimed ] || fail "claim status was not persisted"
  out=$(printf 'Started and routed.' | PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" "$REPLY" 50)
  assert_contains "$out" 'sent into topic thread 3' "reply did not report the originating thread"
  assert_absent "$data/inbox/update-50.json" "answered item remained in the active inbox"
  assert_present "$data/answered/update-50.json" "answered item was deleted instead of archived"
  [ "$(jq -r '.status' "$data/outbox/update-50-initial.json")" = sent ] || fail "reply intent was not recorded as sent"

  printf 'Started and routed.' | PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" "$REPLY" 50 >/dev/null || fail "idempotent reply replay failed"
  send_count=$(grep -c 'sendMessage' "$log")
  [ "$send_count" -eq 1 ] || fail "same keyed reply was sent more than once"

  printf 'Finished successfully.' | PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" "$REPLY" 50 --follow-up completion >/dev/null || fail "follow-up to archived item failed"
  assert_grep 'message_thread_id=3' "$log" "reply did not carry the originating message_thread_id"
  send_count=$(grep -c 'sendMessage' "$log")
  [ "$send_count" -eq 2 ] || fail "stable follow-up key did not create exactly one additional send"

  write_updates "$response" \
    '{"update_id":51,"message":{"message_id":502,"message_thread_id":3,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"ambiguous"}}'
  printf '51\n' > "$data/.poll-offset"
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "could not seed ambiguous reply item"
  set +e
  printf 'Maybe delivered.' | PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" FM_FAKE_SEND_RC=28 "$REPLY" 51 >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "transport failure was reported as a successful reply"
  [ "$(jq -r '.status' "$data/outbox/update-51-initial.json")" = delivery_unknown ] || fail "ambiguous send was not durably marked"
  set +e
  printf 'Maybe delivered.' | PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" "$REPLY" 51 >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "ambiguous reply retried automatically"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_CURL_LOG="$log" FM_FAKE_SEND_RESPONSE="$send_response" "$REPLY" 51 --confirm-sent >/dev/null || fail "manual sent confirmation failed"
  assert_present "$data/answered/update-51.json" "confirmed ambiguous item was not archived"
  pass "claims persist, keyed replies do not duplicate, and ambiguous delivery requires an explicit decision"
}

epoch_to_iso8601() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

backdate_claimed_at() {
  local item=$1 epoch=$2 stamp tmp
  stamp=$(epoch_to_iso8601 "$epoch") || fail "could not compute a backdated claimed_at stamp"
  tmp="$item.tmp"
  jq --arg claimed_at "$stamp" '.claimed_at = $claimed_at' "$item" > "$tmp" && mv "$tmp" "$item"
}

test_claimed_item_reminds_on_the_longer_cadence() {
  local home fakebin response log data now item
  home=$(make_home claimed-reminder)
  fakebin=$(make_fake_curl "$home")
  response="$home/updates.json"
  log="$home/curl.log"
  data="$home/data/fm-telegram-topics"
  : > "$log"
  write_updates "$response" \
    '{"update_id":55,"message":{"message_id":551,"message_thread_id":3,"from":{"id":700000001},"chat":{"id":-1001234567890},"text":"long-running work"}}'
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "could not seed claimed reminder item"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$INBOX" claim 55 alpha-mate >/dev/null || fail "could not claim reminder item"
  item="$data/inbox/update-55.json"

  rm -f "$home/state/.wake-queue"
  now=$(date +%s)
  printf '%s\n' "$((now - 300))" > "$data/.last-wake"
  FM_TOPIC_CLAIMED_REMIND_SECONDS=900 listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 \
    || fail "listener failed while checking the pending reminder cadence"
  assert_absent "$home/state/.wake-queue" "claimed item re-fired on the pending reminder cadence"

  backdate_claimed_at "$item" "$((now - 900))"
  printf '%s\n' "$((now - 900))" > "$data/.last-wake"
  FM_TOPIC_CLAIMED_REMIND_SECONDS=900 listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 \
    || fail "listener failed while checking the claimed reminder cadence"
  assert_grep 'topic-message 1 unanswered' "$home/state/.wake-queue" "claimed item did not resurface after the longer cadence"
  pass "claimed topic items skip the pending cadence and resurface on the longer cadence"
}

test_claimed_item_cadence_survives_concurrent_wake_clock_resets() {
  local home data now stale_claim_epoch fresh_claim_epoch count
  home=$(make_home claimed-cadence-decoupling)
  data="$home/data/fm-telegram-topics"
  mkdir -p "$data/inbox"
  now=$(date +%s)
  stale_claim_epoch=$((now - 1000))
  fresh_claim_epoch=$((now - 5))

  jq -n --arg claimed_at "$(epoch_to_iso8601 "$stale_claim_epoch")" \
    '{update_id:77, status:"claimed", claimed_by:"alpha-mate", claimed_at:$claimed_at, topic:"AlphaDev", project:"Alpha'"'"'s Place", route:"alpha-mate", text:"old claim", group:"Example Dev Group", from_id:"700000001", chat_id:"-1001234567890", thread_id:3}' \
    > "$data/inbox/update-77.json"

  (
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT"
    . "$ROOT/bin/fm-topic-lib.sh"
    printf '%s\n' "$fresh_claim_epoch" > "$FM_TOPIC_LAST_WAKE"
    count=$(fm_topic_unanswered_count 900) || exit 1
    [ "$count" -eq 1 ] || { echo "expected claimed item aged past claimed_at threshold to count despite a fresh shared wake clock, got $count" >&2; exit 1; }
  ) || fail "claimed-item cadence stayed coupled to the shared wake clock instead of the item's own claimed_at"
  pass "claimed-item cadence uses each item's own claimed_at and ignores concurrent wake-clock resets"
}

test_claimed_item_with_missing_claimed_at_surfaces_immediately() {
  local home data count
  home=$(make_home claimed-missing-timestamp)
  data="$home/data/fm-telegram-topics"
  mkdir -p "$data/inbox"

  jq -n \
    '{update_id:88, status:"claimed", claimed_by:"alpha-mate", topic:"AlphaDev", project:"Alpha'"'"'s Place", route:"alpha-mate", text:"corrupted claim", group:"Example Dev Group", from_id:"700000001", chat_id:"-1001234567890", thread_id:3}' \
    > "$data/inbox/update-88.json"

  (
    # shellcheck disable=SC2030 # Scoped to this subshell on purpose; read below via the sourced lib.
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT"
    . "$ROOT/bin/fm-topic-lib.sh"
    printf '%s\n' "$(date +%s)" > "$FM_TOPIC_LAST_WAKE"
    count=$(fm_topic_unanswered_count 14400) || exit 1
    [ "$count" -eq 1 ] || { echo "expected a claimed item with no claimed_at to surface immediately, got $count" >&2; exit 1; }
  ) || fail "a claimed item with a missing claimed_at stayed silently invisible instead of surfacing"
  pass "claimed items with a missing or unparseable claimed_at fail open and surface immediately"
}

test_service_and_supervision_integration() {
  local home fakebin systemctl_log systemd_dir unit out status plugin repo arm_log
  home=$(make_home service)
  fakebin=$(fm_fakebin "$home/systemctl")
  systemctl_log="$home/systemctl.log"
  systemd_dir="$home/systemd"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SYSTEMCTL_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/systemctl"

  unit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SERVICE" print-unit)
  assert_contains "$unit" 'Restart=always' "service unit does not restart persistently"
  assert_contains "$unit" "ExecStart=\"$ROOT/bin/fm-topic-listener.sh\"" "service unit does not run the tracked listener"
  assert_not_contains "$unit" 'test_topic_token' "service unit leaked the bot token"
  assert_not_contains "$unit" 'After=default.target' "service unit recreated the known default-target ordering cycle"

  : > "$home/state/topic-watch.check.sh"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TOPIC_SYSTEMD_DIR="$systemd_dir" FM_TOPIC_SYSTEMCTL="$fakebin/systemctl" FM_FAKE_SYSTEMCTL_LOG="$systemctl_log" "$SERVICE" install 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "service installer accepted the competing prototype poller"
  assert_contains "$out" 'two getUpdates consumers' "prototype conflict refusal did not explain the token race"
  rm -f "$home/state/topic-watch.check.sh"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TOPIC_SYSTEMD_DIR="$systemd_dir" FM_TOPIC_SYSTEMCTL="$fakebin/systemctl" FM_FAKE_SYSTEMCTL_LOG="$systemctl_log" "$SERVICE" install >/dev/null || fail "service installation failed"
  assert_present "$systemd_dir/firstmate-topic-board.service" "service installer did not persist the unit"
  assert_grep 'enable --now firstmate-topic-board.service' "$systemctl_log" "service installer did not enable the durable unit"

  # shellcheck source=bin/fm-supervision-lib.sh
  . "$ROOT/bin/fm-supervision-lib.sh"
  if ! FM_HOME="$home" fm_supervision_unhealthy "$home/state" 300 "$home"; then
    fail "topic credentials did not require supervision with an empty fleet"
  fi
  [ "$FM_SUP_TOPIC_BOARD" = true ] || fail "supervision status did not expose active topic-board demand"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-supervision-instructions.sh" --harness codex --topic-board 1)
  assert_contains "$out" 'Telegram topic board: active' "session supervision block omitted topic-board demand"

  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$home/opencode-root"
  arm_log="$home/opencode-arm.log"
  mkdir -p "$repo/bin"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'armed\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$arm_log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({event: {type: "session.idle", properties: {sessionID: "topic-test"}}});
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) await new Promise((resolve) => setTimeout(resolve, 20));
if (!existsSync(process.env.FM_ARM_LOG)) process.exit(1);
EOF
  )
  status=$?
  expect_code 0 "$status" "OpenCode did not arm for topic-board-only supervision"
  [ -z "$out" ] || fail "OpenCode topic-board arm test printed output: $out"
  pass "systemd persistence refuses poller races and every primary supervision path stays active for the topic board"
}

test_multi_chat_sender_scope_and_origin_reply
test_multi_sender_config_validation_fails_closed
test_listener_is_lossless_and_topic_aware
test_boundary_offset_and_failed_persistence
test_fast_wake_signals_only_verified_home_watcher
test_queued_topic_wake_survives_unhandled_usr1
test_claim_reply_idempotency_and_ambiguous_delivery
test_claimed_item_reminds_on_the_longer_cadence
test_claimed_item_cadence_survives_concurrent_wake_clock_resets
test_claimed_item_with_missing_claimed_at_surfaces_immediately
test_service_and_supervision_integration
