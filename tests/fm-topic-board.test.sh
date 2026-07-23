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
FM_TOPIC_CAPTAIN_ID=953048088
EOF
  chmod 600 "$data/config.env"
  cat > "$data/topic-map.json" <<'EOF'
{
  "chat_id": "-1004497246253",
  "group": "DevBois II",
  "bot": "@secondmate_kingbot",
  "topics": {
    "3": {"name": "LMoonDev", "project": "L'Moon", "route": "lmoon-mate"},
    "2": {"name": "KoruDev", "project": "Koru", "route": "koru-mate"},
    "4": {"name": "VisDev", "project": "Vintage in Style", "route": "main"}
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
    '{"update_id":10,"message":{"message_id":101,"message_thread_id":3,"from":{"id":953048088},"chat":{"id":-1004497246253},"text":"Build the booking fix"}}' \
    '{"update_id":11,"message":{"message_id":102,"message_thread_id":3,"from":{"id":42},"chat":{"id":-1004497246253},"text":"not captain"}}' \
    '{"update_id":12,"message":{"message_id":103,"message_thread_id":99,"from":{"id":953048088},"chat":{"id":-1004497246253},"caption":"diagram","photo":[{"file_id":"p1"}]}}'

  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener rejected valid updates"
  data="$home/data/fm-telegram-topics"
  [ "$(cat "$data/.poll-offset")" = 13 ] || fail "listener did not advance offset past every inspected update"
  assert_present "$data/inbox/update-10.json" "mapped captain item was not retained"
  assert_absent "$data/inbox/update-11.json" "non-captain item reached the private inbox"
  assert_present "$data/inbox/update-12.json" "unmapped captain item was silently dropped"
  [ "$(jq -r '.route' "$data/inbox/update-10.json")" = lmoon-mate ] || fail "mapped topic did not retain its secondmate route"
  [ "$(jq -r '.topic' "$data/inbox/update-10.json")" = LMoonDev ] || fail "mapped topic name was not retained"
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
  assert_contains "$out" $'10\tpending\tLMoonDev\tL\x27Moon\tlmoon-mate' "inbox list omitted topic and route context"

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
    '{"update_id":20,"message":{"message_id":201,"message_thread_id":2,"from":{"id":953048088},"chat":{"id":-1004497246253},"text":"boundary"}}'
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "listener failed at the exact offset boundary"
  [ "$(cat "$data/.poll-offset")" = 21 ] || fail "boundary update did not advance the offset"

  printf '30\n' > "$data/.poll-offset"
  mkdir "$data/inbox/update-30.json"
  write_updates "$response" \
    '{"update_id":30,"message":{"message_id":301,"message_thread_id":2,"from":{"id":953048088},"chat":{"id":-1004497246253},"text":"must persist"}}'
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
    '{"update_id":31,"message":{"message_id":302,"message_thread_id":2,"from":{"id":953048088},"chat":{"id":-1004497246253},"text":"must flush"}}'
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
    '{"update_id":40,"message":{"message_id":401,"message_thread_id":3,"from":{"id":953048088},"chat":{"id":-1004497246253},"text":"wake now"}}'

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
    '{"update_id":41,"message":{"message_id":402,"message_thread_id":3,"from":{"id":953048088},"chat":{"id":-1004497246253},"text":"wake even if signal is masked"}}'

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
  printf '%s\n' '{"ok":true,"result":{"message_id":900,"message_thread_id":3,"chat":{"title":"DevBois II"}}}' > "$send_response"
  write_updates "$response" \
    '{"update_id":50,"message":{"message_id":501,"message_thread_id":3,"from":{"id":953048088},"chat":{"id":-1004497246253},"text":"ship it"}}'
  listener_once "$home" "$fakebin" "$response" "$log" >/dev/null 2>&1 || fail "could not seed reply item"
  data="$home/data/fm-telegram-topics"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$INBOX" claim 50 lmoon-mate >/dev/null || fail "claim failed"
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
    '{"update_id":51,"message":{"message_id":502,"message_thread_id":3,"from":{"id":953048088},"chat":{"id":-1004497246253},"text":"ambiguous"}}'
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

test_listener_is_lossless_and_topic_aware
test_boundary_offset_and_failed_persistence
test_fast_wake_signals_only_verified_home_watcher
test_queued_topic_wake_survives_unhandled_usr1
test_claim_reply_idempotency_and_ambiguous_delivery
test_service_and_supervision_integration
