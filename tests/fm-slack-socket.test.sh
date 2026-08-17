#!/usr/bin/env bash
# Behavior tests for the supervised Slack Socket Mode transport and event consumer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
NODE_DIR=$(command -v node 2>/dev/null) && NODE_DIR=$(dirname "$NODE_DIR") || NODE_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
[ -n "$NODE_DIR" ] && BASE_PATH="$NODE_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-slack-socket-tests)
CHANNEL_ID=C0BQ9K1TJKG
BOT_USER=U0BR5SQ4WN4
CAPTAIN_USER=U0CAPTAIN1

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile= url= data=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -m|-w) shift 2 ;;
    -s*) shift ;;
    -H) shift 2 ;;
    --data) data=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[ -z "${FM_SLACK_CURL_LOG:-}" ] || printf 'url=%s data=%s\n' "$url" "$data" >> "$FM_SLACK_CURL_LOG"
case "$url" in
  */auth.test) body='{"ok":true,"user_id":"U0BR5SQ4WN4"}' ;;
  */chat.postMessage) body='{"ok":true,"ts":"1786735224.700000","channel":"C0BQ9K1TJKG"}' ;;
  */reactions.add) body='{"ok":true}' ;;
  */reactions.remove) body='{"ok":true}' ;;
  *) body='{"ok":false,"error":"unexpected_method"}' ;;
esac
if [ -n "$ofile" ]; then printf '%s' "$body" > "$ofile"; else printf '%s' "$body"; fi
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

make_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state"
  chmod 700 "$home/config" "$home/state"
  printf 'FM_SLACK_BOT_TOKEN=xoxb-synthetic\nFM_SLACK_APP_TOKEN=xapp-synthetic\n' > "$home/.env"
  printf '%s\n' "$CHANNEL_ID" > "$home/config/slack-captain-channel"
  printf '%s\n' "$CAPTAIN_USER" > "$home/config/slack-captain-user"
  chmod 600 "$home/.env" "$home/config/slack-captain-channel" "$home/config/slack-captain-user"
}

run_event() {
  local home=$1 fakebin=$2 envelope_id=$3 event=$4
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-socket-event.sh" "$envelope_id" <<< "$event"
}

node_case() {
  PATH="$BASE_PATH" node "$ROOT/tests/fm-slack-socket.behavior.mjs" "$1"
}

test_fake_control() {
  node_case fake-control || fail "fake transport control failed"
}

test_envelope_ack() {
  node_case envelope-ack || fail "socket consumer did not ack the envelope"
}

test_reconnect() {
  node_case reconnect || fail "socket consumer did not reconnect cleanly"
}

test_instant_connect_failure() {
  node_case instant-connect-failure \
    || fail "instant socket connect failures were not rate-bounded"
}

test_no_hello_close() {
  node_case no-hello-close \
    || fail "socket close before hello did not escalate its backoff"
}

test_production_error_close() {
  node_case production-error-close \
    || fail "production socket error-close did not reject its pending waiter"
}

test_bridge() {
  local home="$TMP_ROOT/bridge" fakebin payload surfaced
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"envelope_id":"env-bridge","event":{"type":"message","channel":"C0BQ9K1TJKG","user":"U0CAPTAIN1","text":"status","ts":"1786735224.690829"}}'
SH
  chmod +x "$fakebin/node"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-slack-socket.sh" \
    || fail "socket bridge failed"
  payload=$(awk -F '\t' '$3 == "check" && $4 == "slack-socket:1786735224.690829" { print $5 }' \
    "$home/state/.wake-queue")
  case "$payload" in
    *'slack-captain-message 1786735224.690829 status') ;;
    *) fail "socket bridge did not publish the captain wake: $payload" ;;
  esac
  surfaced=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1"; slack_socket_surface_queued' _ "$ROOT/bin/fm-watch.sh") \
    || fail "watcher did not surface the socket wake"
  [ "$surfaced" = "$payload" ] || fail "watcher changed the socket wake payload"
  pass "supervised bridge publishes and watcher surfaces the captain wake"
}

test_bridge_fails_closed() {
  local home="$TMP_ROOT/bridge-fails-closed" fakebin
  make_home "$home"
  fakebin=$(fm_fakebin "$home/fake")
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"envelope_id":"env-bridge-failure","event":{"type":"message","channel":"C0BQ9K1TJKG","user":"U0CAPTAIN1","text":"status","ts":"1786735224.690829"}}'
SH
  chmod +x "$fakebin/node"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN=/usr/bin/false \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-slack-socket.sh"; then
    fail "socket bridge hid an event-handler failure"
  fi
  [ ! -e "$home/state/.wake-queue" ] || fail "failed event handler published a wake"
  pass "socket bridge exits for supervision when event handling fails"
}

test_captain() {
  local home="$TMP_ROOT/captain" fakebin log event out expected
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  log="$home/curl.log"; : > "$log"
  event='{"type":"message","channel":"C0BQ9K1TJKG","user":"U0CAPTAIN1","text":"status","ts":"1786735224.690829"}'
  out=$(FM_SLACK_CURL_LOG="$log" run_event "$home" "$fakebin" env-captain "$event") \
    || fail "captain event failed"
  printf -v expected 'slack-captain-message %s\t%s' 1786735224.690829 status
  [ "$out" = "$expected" ] || fail "captain wake differs from poll contract: $out"
  [ -f "$home/state/slack-inbox/1786735224.690829.json" ] || fail "captain event was not stashed"
  [ "$(grep -c '^method=reactions.add' "$log")" -eq 1 ] || fail "captain event was not acknowledged once"
  [ "$(grep -c '^method=chat.postMessage' "$log")" -eq 0 ] || fail "captain event posted an acknowledgement message"
  pass "captain event produces the poll wake, inbox, and received reaction"
}

assert_refused() {
  local case_name=$1 user=$2 extra=$3 expected_reason=$4
  local home="$TMP_ROOT/$case_name" fakebin event out refusal
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  event='{"type":"message","channel":"C0BQ9K1TJKG","user":"'"$user"'","text":"status","ts":"1786735224.690829"'"$extra"'}'
  out=$(run_event "$home" "$fakebin" "env-$case_name" "$event") || fail "$case_name event failed"
  [ -z "$out" ] || fail "$case_name event emitted a wake: $out"
  refusal="$home/state/slack-refused/1786735224.690829.json"
  [ -f "$refusal" ] || fail "$case_name refusal was not recorded"
  [ "$(jq -r '.reason' "$refusal")" = "$expected_reason" ] || fail "$case_name refusal reason was wrong"
  [ ! -e "$home/state/slack-inbox/1786735224.690829.json" ] || fail "$case_name event reached the inbox"
}

test_other_user() {
  assert_refused other-user U0SOMEONE2 '' non-captain-user
  pass "non-captain human event is recorded as refused"
}

test_bot_user() {
  assert_refused bot-user "$BOT_USER" '' bot-user
  pass "the app bot event is recorded as refused"
}

test_subtype() {
  assert_refused subtype "$CAPTAIN_USER" ',"subtype":"channel_join"' non-captain-subtype
  pass "subtyped captain event is refused by the shared message rule"
}

test_malformed_event() {
  local home="$TMP_ROOT/malformed" fakebin event out refusal
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  event='{"type":"message","channel":"C0BQ9K1TJKG","user":"U0SOMEONE2","text":"status"}'
  out=$(run_event "$home" "$fakebin" env-malformed "$event") || fail "malformed event failed closed"
  [ -z "$out" ] || fail "malformed event emitted a wake: $out"
  refusal="$home/state/slack-refused/envelope-env-malformed.json"
  [ -f "$refusal" ] || fail "malformed event refusal was not recorded"
  [ "$(jq -r '.reason' "$refusal")" = malformed-event ] || fail "malformed refusal reason was wrong"
  pass "malformed inbound event is recorded as refused"
}

test_supervision() {
  local home="$TMP_ROOT/supervision"
  make_home "$home"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    "$ROOT/bin/fm-procevent-slack-socket.sh" arm >/dev/null \
    || fail "socket adapter did not register the worker"
  [ -f "$home/state/procevent/slack-captain-socket.source" ] \
    || fail "socket worker registration is missing"
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$ROOT/bin/fm-supervision-lib.sh"
  fm_supervision_needed "$home/state" \
    || fail "registered socket worker did not require supervision"
  pass "socket worker is owned by existing process-event supervision"
}

test_bootstrap() {
  local home="$TMP_ROOT/bootstrap"
  make_home "$home"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$home/claims" PATH="$BASE_PATH" \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null \
    || fail "bootstrap failed while arming Slack transports"
  [ -x "$home/state/slack-watch.check.sh" ] || fail "bootstrap removed or omitted the existing poll"
  [ -f "$home/state/procevent/slack-captain-socket.source" ] \
    || fail "bootstrap did not arm the socket worker"
  before=$(shasum -a 256 "$home/state/procevent/slack-captain-socket.source")
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$home/claims" PATH="$BASE_PATH" \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null \
    || fail "repeat bootstrap failed with an armed socket worker"
  after=$(shasum -a 256 "$home/state/procevent/slack-captain-socket.source")
  [ "$before" = "$after" ] || fail "repeat bootstrap replaced the live socket registration"
  pass "bootstrap arms Socket Mode alongside the existing poll"
}

case "${FM_SLACK_SOCKET_TEST_CASE:-all}" in
  fake-control) test_fake_control ;;
  envelope-ack) test_envelope_ack ;;
  reconnect) test_reconnect ;;
  instant-connect-failure) test_instant_connect_failure ;;
  no-hello-close) test_no_hello_close ;;
  production-error-close) test_production_error_close ;;
  bridge) test_bridge ;;
  bridge-fails-closed) test_bridge_fails_closed ;;
  captain) test_captain ;;
  other-user) test_other_user ;;
  bot-user) test_bot_user ;;
  subtype) test_subtype ;;
  malformed) test_malformed_event ;;
  supervision) test_supervision ;;
  bootstrap) test_bootstrap ;;
  all)
    test_fake_control
    test_envelope_ack
    test_reconnect
    test_instant_connect_failure
    test_no_hello_close
    test_production_error_close
    test_bridge
    test_bridge_fails_closed
    test_captain
    test_other_user
    test_bot_user
    test_subtype
    test_malformed_event
    test_supervision
    test_bootstrap
    ;;
  *) fail "unknown FM_SLACK_SOCKET_TEST_CASE" ;;
esac

printf '\nall Slack socket tests passed\n'
