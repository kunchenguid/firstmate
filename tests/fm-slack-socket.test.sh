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
  */reactions.add)
    if [ -n "${FAKE_SLACK_REACTION_FAIL:-}" ]; then
      body='{"ok":false,"error":"reaction_failed"}'
    else
      body='{"ok":true}'
    fi
    ;;
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

test_captain_ack_retry() {
  local home="$TMP_ROOT/captain-ack-retry" fakebin log event out expected
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  log="$home/curl.log"; : > "$log"
  event='{"type":"message","channel":"C0BQ9K1TJKG","user":"U0CAPTAIN1","text":"status","ts":"1786735224.690830"}'
  out=$(FM_SLACK_CURL_LOG="$log" FAKE_SLACK_REACTION_FAIL=1 \
    run_event "$home" "$fakebin" env-captain-failed-ack "$event") \
    || fail "captain event with failed acknowledgement failed"
  printf -v expected 'slack-captain-message %s\t%s' 1786735224.690830 status
  [ "$out" = "$expected" ] || fail "failed acknowledgement suppressed the captain wake: $out"
  [ -f "$home/state/slack-inbox/1786735224.690830.json" ] || fail "failed acknowledgement suppressed inbox publication"
  [ ! -e "$home/state/slack-acked/1786735224.690830" ] || fail "failed acknowledgement recorded completion"
  [ -f "$home/state/slack-ack-pending/1786735224.690830" ] || fail "failed acknowledgement lost its retry marker"
  out=$(FM_SLACK_CURL_LOG="$log" run_event "$home" "$fakebin" env-captain-retry "$event") \
    || fail "captain acknowledgement retry failed"
  [ -z "$out" ] || fail "captain acknowledgement retry duplicated the wake: $out"
  [ -f "$home/state/slack-acked/1786735224.690830" ] || fail "successful retry did not retain its marker"
  [ ! -e "$home/state/slack-ack-pending/1786735224.690830" ] || fail "successful retry remained pending"
  pass "Socket Mode retries failed acknowledgement without duplicating delivery"
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

# The fake curl answers chat.postMessage with this ts, so every decision posted
# through fm-slack-post.sh in this suite binds to it.
DECISION_TS=1786735224.700000

# Slack reaction event frames, mirroring the recorded envelope field style in
# the captain home's state/slack-refused/ fixtures (string channel/user/ts
# fields, event_ts on the outer event) and Slack's documented reaction_added /
# reaction_removed shape: type, user, reaction, item{type,channel,ts},
# item_user (the reacted message's author), event_ts.
reaction_event() {
  local kind=$1 user=$2 reaction=$3 item_ts=$4 item_user=$5 event_ts=$6
  printf '{"type":"%s","user":"%s","reaction":"%s","item":{"type":"message","channel":"%s","ts":"%s"},"item_user":"%s","event_ts":"%s"}' \
    "$kind" "$user" "$reaction" "$CHANNEL_ID" "$item_ts" "$item_user" "$event_ts"
}

run_decision() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-post.sh" decision "$@"
}

assert_reaction_refused() {
  local case_name=$1 event=$2 expected_reason=$3
  local home="$TMP_ROOT/$case_name" fakebin out refusal
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  out=$(run_event "$home" "$fakebin" "env-$case_name" "$event") \
    || fail "$case_name event failed"
  [ -z "$out" ] || fail "$case_name event emitted a wake: $out"
  refusal="$home/state/slack-refused/$DECISION_TS.json"
  [ -f "$refusal" ] || fail "$case_name refusal was not recorded"
  [ "$(jq -r '.reason' "$refusal")" = "$expected_reason" ] \
    || fail "$case_name refusal reason was wrong: $(jq -r '.reason' "$refusal")"
}

test_reaction_approve() {
  local home="$TMP_ROOT/reaction-approve" fakebin log event out expected record
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  log="$home/curl.log"; : > "$log"
  FM_SLACK_CURL_LOG="$log" run_decision "$home" "$fakebin" merge-pr-42 "Ship PR 42?" >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" white_check_mark "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  out=$(FM_SLACK_CURL_LOG="$log" run_event "$home" "$fakebin" env-reaction-approve "$event") \
    || fail "reaction_added event failed"
  printf -v expected 'slack-captain-message %s\t%s' 1786735300.000100 'merge-pr-42: yes'
  [ "$out" = "$expected" ] || fail "reaction answer wake differs from the typed path: $out"
  record="$home/state/slack-decision-resolved/merge-pr-42.json"
  [ -f "$record" ] || fail "reaction answer was not recorded"
  [ "$(jq -r '.answer' "$record")" = yes ] || fail "recorded answer was wrong"
  [ -f "$home/state/slack-inbox/1786735300.000100.json" ] || fail "reaction event was not stashed"
  [ "$(grep -c '^method=reactions.add ' "$log")" -eq 1 ] \
    || fail "reaction answer was not acknowledged once"
  grep -F 'timestamp=1786735224.700000' "$log" | grep -F 'name=eyes' >/dev/null \
    || fail "ack did not land on the decision message"
  pass "captain check reaction resolves the bound decision as yes"
}

test_reaction_decline() {
  local home="$TMP_ROOT/reaction-decline" fakebin event out expected record
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" merge-pr-42 "Ship PR 42?" >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" x "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  out=$(run_event "$home" "$fakebin" env-reaction-decline "$event") \
    || fail "reaction_added event failed"
  printf -v expected 'slack-captain-message %s\t%s' 1786735300.000100 'merge-pr-42: no'
  [ "$out" = "$expected" ] || fail "decline wake differs from the typed path: $out"
  record="$home/state/slack-decision-resolved/merge-pr-42.json"
  [ "$(jq -r '.answer' "$record")" = no ] || fail "recorded decline was wrong"
  pass "captain x reaction resolves the bound decision as no"
}

test_reaction_option() {
  local home="$TMP_ROOT/reaction-option" fakebin event out expected record
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" pick-harness "Pick a harness" claude codex pi >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" two "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  out=$(run_event "$home" "$fakebin" env-reaction-option "$event") \
    || fail "reaction_added event failed"
  printf -v expected 'slack-captain-message %s\t%s' 1786735300.000100 'pick-harness: 2'
  [ "$out" = "$expected" ] || fail "option wake differs from the typed path: $out"
  record="$home/state/slack-decision-resolved/pick-harness.json"
  [ "$(jq -r '.answer' "$record")" = 2 ] || fail "recorded option was wrong"
  pass "captain number reaction selects the matching numbered option"
}

test_reaction_option_out_of_range() {
  local home="$TMP_ROOT/reaction-option-out-of-range" fakebin event out refusal
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" pick-harness "Pick a harness" claude codex >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" three "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  out=$(run_event "$home" "$fakebin" env-reaction-option-out-of-range "$event") \
    || fail "reaction_added event failed"
  [ -z "$out" ] || fail "out-of-range option emitted a wake: $out"
  refusal="$home/state/slack-refused/$DECISION_TS.json"
  [ "$(jq -r '.reason' "$refusal")" = option-out-of-range ] \
    || fail "out-of-range refusal reason was wrong"
  [ ! -e "$home/state/slack-decision-resolved/pick-harness.json" ] \
    || fail "out-of-range option resolved the decision"
  pass "a number reaction beyond the posted options is refused, never guessed"
}

test_reaction_unbound() {
  local event
  event=$(reaction_event reaction_added "$CAPTAIN_USER" white_check_mark "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  assert_reaction_refused reaction-unbound "$event" unbound-message
  pass "a reaction on a message with no recorded binding is refused, never guessed"
}

test_reaction_unmapped() {
  local home="$TMP_ROOT/reaction-unmapped" fakebin event out refusal
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" merge-pr-42 "Ship PR 42?" >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" thumbsup "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  out=$(run_event "$home" "$fakebin" env-reaction-unmapped "$event") \
    || fail "reaction_added event failed"
  [ -z "$out" ] || fail "unmapped reaction emitted a wake: $out"
  refusal="$home/state/slack-refused/$DECISION_TS.json"
  [ "$(jq -r '.reason' "$refusal")" = unmapped-reaction ] \
    || fail "unmapped refusal reason was wrong"
  [ ! -e "$home/state/slack-decision-resolved/merge-pr-42.json" ] \
    || fail "unmapped reaction resolved the decision"
  pass "an unmapped reaction leaves the decision unanswered and firstmate waiting"
}

test_reaction_non_captain() {
  local event
  event=$(reaction_event reaction_added U0SOMEONE2 white_check_mark "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  assert_reaction_refused reaction-non-captain "$event" non-captain-user
  pass "a reaction from a non-captain is refused and recorded"
}

test_reaction_bot_self() {
  local event
  event=$(reaction_event reaction_added "$BOT_USER" eyes "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  assert_reaction_refused reaction-bot-self "$event" non-captain-user
  pass "firstmate's own ack reaction keeps refusing"
}

test_reaction_non_firstmate_message() {
  local event
  event=$(reaction_event reaction_added "$CAPTAIN_USER" white_check_mark "$DECISION_TS" U0SOMEONE2 1786735300.000100)
  assert_reaction_refused reaction-non-firstmate "$event" non-firstmate-message
  pass "a captain reaction on someone else's message is refused and recorded"
}

test_reaction_removed_after_answer() {
  local home="$TMP_ROOT/reaction-removed-after-answer" fakebin event out expected record
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" merge-pr-42 "Ship PR 42?" >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" white_check_mark "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  run_event "$home" "$fakebin" env-reaction-add "$event" >/dev/null \
    || fail "reaction_added event failed"
  event=$(reaction_event reaction_removed "$CAPTAIN_USER" white_check_mark "$DECISION_TS" "$BOT_USER" 1786735310.000200)
  out=$(run_event "$home" "$fakebin" env-reaction-remove "$event") \
    || fail "reaction_removed event failed"
  printf -v expected 'slack-captain-reaction %s\t%s' 1786735310.000200 \
    'conflict: merge-pr-42 was answered yes by white_check_mark; removal does not reopen it'
  [ "$out" = "$expected" ] || fail "removal conflict was not reported: $out"
  record="$home/state/slack-decision-resolved/merge-pr-42.json"
  [ "$(jq -r '.answer' "$record")" = yes ] || fail "removal reversed the recorded answer"
  pass "removing a reaction after the answer is reported, never a reversal"
}

test_reaction_removed_unresolved() {
  local home="$TMP_ROOT/reaction-removed-unresolved" fakebin event out
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" merge-pr-42 "Ship PR 42?" >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_removed "$CAPTAIN_USER" white_check_mark "$DECISION_TS" "$BOT_USER" 1786735310.000200)
  out=$(run_event "$home" "$fakebin" env-reaction-remove-unresolved "$event") \
    || fail "reaction_removed event failed"
  [ -z "$out" ] || fail "removal before any answer emitted a wake: $out"
  [ ! -e "$home/state/slack-decision-resolved/merge-pr-42.json" ] \
    || fail "removal recorded an answer"
  pass "removing a reaction before any answer stays silent"
}

test_reaction_conflict_second_answer() {
  local home="$TMP_ROOT/reaction-conflict-second" fakebin event out expected record
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" merge-pr-42 "Ship PR 42?" >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" white_check_mark "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  run_event "$home" "$fakebin" env-reaction-add "$event" >/dev/null \
    || fail "reaction_added event failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" x "$DECISION_TS" "$BOT_USER" 1786735305.000150)
  out=$(run_event "$home" "$fakebin" env-reaction-second "$event") \
    || fail "second reaction_added event failed"
  printf -v expected 'slack-captain-reaction %s\t%s' 1786735305.000150 \
    'conflict: merge-pr-42 was already answered yes; ignored x'
  [ "$out" = "$expected" ] || fail "contradictory answer was not reported: $out"
  record="$home/state/slack-decision-resolved/merge-pr-42.json"
  [ "$(jq -r '.answer' "$record")" = yes ] || fail "contradictory reaction overwrote the first answer"
  pass "a contradictory second reaction is reported and the first answer stands"
}

test_reaction_duplicate_silent() {
  local home="$TMP_ROOT/reaction-duplicate" fakebin event out
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" merge-pr-42 "Ship PR 42?" >/dev/null \
    || fail "decision post failed"
  event=$(reaction_event reaction_added "$CAPTAIN_USER" white_check_mark "$DECISION_TS" "$BOT_USER" 1786735300.000100)
  run_event "$home" "$fakebin" env-reaction-add "$event" >/dev/null \
    || fail "reaction_added event failed"
  out=$(run_event "$home" "$fakebin" env-reaction-dup "$event") \
    || fail "duplicate reaction_added event failed"
  [ -z "$out" ] || fail "a duplicate of the answering reaction emitted a wake: $out"
  [ "$(jq -r '.answer' "$home/state/slack-decision-resolved/merge-pr-42.json")" = yes ] \
    || fail "duplicate reaction changed the recorded answer"
  pass "a repeated delivery of the answering reaction stays silent"
}

test_bridge_reaction() {
  local home="$TMP_ROOT/bridge-reaction" fakebin payload
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  run_decision "$home" "$fakebin" merge-pr-42 "Ship PR 42?" >/dev/null \
    || fail "decision post failed"
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"envelope_id":"env-bridge-reaction","event":{"type":"reaction_added","user":"U0CAPTAIN1","reaction":"white_check_mark","item":{"type":"message","channel":"C0BQ9K1TJKG","ts":"1786735224.700000"},"item_user":"U0BR5SQ4WN4","event_ts":"1786735300.000100"}}'
SH
  chmod +x "$fakebin/node"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-slack-socket.sh" \
    || fail "socket bridge failed on a reaction event"
  payload=$(awk -F '\t' '$3 == "check" && $4 == "slack-socket:1786735300.000100" { print $5 }' \
    "$home/state/.wake-queue")
  case "$payload" in
    *'slack-captain-message 1786735300.000100 merge-pr-42: yes') ;;
    *) fail "socket bridge did not publish the reaction answer wake: $payload" ;;
  esac
  pass "supervised bridge keys a reaction answer wake by its event ts"
}

test_unhandled_auto_reply_once() {
  local home="$TMP_ROOT/unhandled-auto-reply" fakebin log rearm_log ts i
  make_home "$home"
  fakebin=$(make_fake_curl "$home/fake")
  log="$home/curl.log"; : > "$log"
  rearm_log="$home/rearm.log"
  ts="$(date +%s).690829"
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
printf '%s\n' '{"envelope_id":"env-auto-reply","event":{"type":"message","channel":"C0BQ9K1TJKG","user":"U0CAPTAIN1","text":"status","ts":"$ts"}}'
SH
  cat > "$fakebin/fake-rearm" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$rearm_log"
SH
  chmod +x "$fakebin/node" "$fakebin/fake-rearm"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    FM_SLACK_CURL_LOG="$log" FM_SLACK_UNHANDLED_AFTER=3 \
    FM_SLACK_UNHANDLED_REARM="$fakebin/fake-rearm" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-socket.sh" || fail "socket bridge failed while scheduling auto-reply"
  sleep 0.5
  [ "$(grep -c '^method=chat.postMessage' "$log" || true)" -eq 0 ] \
    || fail "the auto-reply posted before its timeout: $(cat "$log")"
  i=0
  while [ "$(grep -c '^method=chat.postMessage' "$log" || true)" -lt 1 ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(grep -c '^method=chat.postMessage' "$log" || true)" -eq 1 ] \
    || fail "an unhandled message did not receive one timed auto-reply: $(cat "$log")"
  grep -F 'MAIN%20has%20not%20picked%20this%20up%20in%205%20min%3B%20watcher%20re-arm%20requested' "$log" >/dev/null \
    || fail "the timed auto-reply text was wrong: $(cat "$log")"
  grep -F "thread_ts=$ts" "$log" >/dev/null \
    || fail "the timed auto-reply was not posted in the message thread: $(cat "$log")"
  [ "$(wc -l < "$rearm_log" | tr -d '[:space:]')" = 1 ] \
    || fail "the timed auto-reply did not request exactly one re-arm: $(cat "$rearm_log")"
  [ "$(cat "$rearm_log")" = --recover ] \
    || fail "the timed auto-reply did not use the shared recovery path: $(cat "$rearm_log")"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    FM_SLACK_CURL_LOG="$log" FM_SLACK_UNHANDLED_AFTER=3 \
    FM_SLACK_UNHANDLED_REARM="$fakebin/fake-rearm" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-socket.sh" || fail "duplicate socket delivery failed"
  sleep 3.2
  [ "$(grep -c '^method=chat.postMessage' "$log" || true)" -eq 1 ] \
    || fail "one unhandled message received more than one auto-reply: $(cat "$log")"
  [ "$(wc -l < "$rearm_log" | tr -d '[:space:]')" = 1 ] \
    || fail "one unhandled message requested more than one re-arm: $(cat "$rearm_log")"
  pass "an unhandled Socket Mode message receives one timed thread reply and re-arm"
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
  captain-ack-retry) test_captain_ack_retry ;;
  other-user) test_other_user ;;
  bot-user) test_bot_user ;;
  subtype) test_subtype ;;
  malformed) test_malformed_event ;;
  reaction-approve) test_reaction_approve ;;
  reaction-decline) test_reaction_decline ;;
  reaction-option) test_reaction_option ;;
  reaction-option-out-of-range) test_reaction_option_out_of_range ;;
  reaction-unbound) test_reaction_unbound ;;
  reaction-unmapped) test_reaction_unmapped ;;
  reaction-non-captain) test_reaction_non_captain ;;
  reaction-bot-self) test_reaction_bot_self ;;
  reaction-non-firstmate-message) test_reaction_non_firstmate_message ;;
  reaction-removed-after-answer) test_reaction_removed_after_answer ;;
  reaction-removed-unresolved) test_reaction_removed_unresolved ;;
  reaction-conflict-second-answer) test_reaction_conflict_second_answer ;;
  reaction-duplicate-silent) test_reaction_duplicate_silent ;;
  bridge-reaction) test_bridge_reaction ;;
  auto-reply) test_unhandled_auto_reply_once ;;
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
    test_captain_ack_retry
    test_other_user
    test_bot_user
    test_subtype
    test_malformed_event
    test_reaction_approve
    test_reaction_decline
    test_reaction_option
    test_reaction_option_out_of_range
    test_reaction_unbound
    test_reaction_unmapped
    test_reaction_non_captain
    test_reaction_bot_self
    test_reaction_non_firstmate_message
    test_reaction_removed_after_answer
    test_reaction_removed_unresolved
    test_reaction_conflict_second_answer
    test_reaction_duplicate_silent
    test_bridge_reaction
    test_unhandled_auto_reply_once
    test_supervision
    test_bootstrap
    ;;
  *) fail "unknown FM_SLACK_SOCKET_TEST_CASE" ;;
esac

printf '\nall Slack socket tests passed\n'
