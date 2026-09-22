#!/usr/bin/env bash
# Focused regression coverage for the local Hermes Telegram plugin source.
#
# The tests import the tracked plugin source directly, point it at a temporary
# FirstMate home, and use a fake `hermes` binary. They never touch the live
# Hermes plugin, never restart Hermes, and never send real Telegram traffic.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLUGIN="$ROOT/integrations/hermes/firstmate-telegram-relay/__init__.py"
NOTIFY="$ROOT/bin/fm-hermes-notify.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-telegram-relay)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

configure_hermes() {
  local home=$1
  : > "$home/hermes-send.log"
  cat > "$home/hermes-targets.txt" <<'EOF'
telegram:Rajiv [8629896233]
EOF
  cat > "$home/fakebin/hermes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = send ] && [ "${2:-}" = --list ] && [ "${3:-}" = telegram ]; then
  cat "$FM_TEST_HERMES_TARGETS_FILE"
  exit 0
fi
if [ "${1:-}" = send ] && [ "${2:-}" = --to ]; then
  to=${3:-}
  shift 3
  if [ -n "${FM_TEST_HERMES_FAIL_ONCE:-}" ] && [ -e "$FM_TEST_HERMES_FAIL_ONCE" ]; then
    rm -f "$FM_TEST_HERMES_FAIL_ONCE"
    exit 1
  fi
  printf "to=%s text=%s\n" "$to" "$*" >> "$FM_TEST_HERMES_SEND_LOG"
  exit 0
fi
exit 2
SH
  chmod +x "$home/fakebin/hermes"
}

call_plugin() {
  local home=$1 chat_id=$2 message_id=$3 text=$4
  PATH="$home/fakebin:$PATH" \
    FM_TEST_HERMES_TARGETS_FILE="$home/hermes-targets.txt" \
    FM_TEST_HERMES_SEND_LOG="$home/hermes-send.log" \
    FM_TEST_HERMES_FAIL_ONCE="$home/hermes-fail-once" \
    python3 - "$PLUGIN" "$ROOT" "$home" "$chat_id" "$message_id" "$text" <<'PY'
import importlib.util
import json
import sys

plugin_path, root, home, chat_id, message_id, text = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("firstmate_telegram_relay", plugin_path)
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)
plugin._FM_HOME = home
plugin._FM_INBOX = root + "/bin/fm-inbox.sh"
plugin._FM_NOTIFY = root + "/bin/fm-hermes-notify.sh"


class Platform:
    value = "telegram"


class Source:
    platform = Platform()
    chat_id = chat_id


class Event:
    source = Source()
    text = text
    user_name = "Rajiv"
    message_id = message_id


print(json.dumps(plugin._on_pre_gateway_dispatch(event=Event()), sort_keys=True))
PY
}

run_notify() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TEST_HERMES_TARGETS_FILE="$home/hermes-targets.txt" \
    FM_TEST_HERMES_SEND_LOG="$home/hermes-send.log" \
    FM_TEST_HERMES_FAIL_ONCE="$home/hermes-fail-once" \
    "$NOTIFY" "$@"
}

count_notes() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

count_inbox_wakes() {
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

test_away_presence_commands_are_consumed_before_generic_inbox() {
  local home out
  home=$(make_home away-presence)
  configure_hermes "$home"
  out=$(call_plugin "$home" 8629896233 msg-away-1 "Captain away") \
    || fail "plugin call failed for Captain away"
  assert_contains "$out" '"result": "mode:AWAY"' "Captain away was not handled by the presence path"
  assert_equals AWAY "$(run_notify "$home" presence status)" "Captain away did not persist AWAY"
  assert_equals 0 "$(count_notes "$home")" "a consumed AWAY command was also queued as a generic inbox note"
  assert_equals 0 "$(count_inbox_wakes "$home")" "a consumed AWAY command produced an inbox wake"
  assert_grep 'Captain presence is now AWAY' "$home/hermes-send.log" \
    "the AWAY command did not send its one confirmation"

  out=$(call_plugin "$home" 8629896233 msg-away-2 "I'm heading out, use Telegram") \
    || fail "plugin call failed for natural-language AWAY"
  assert_contains "$out" '"result": "mode:AWAY"' "natural-language AWAY was not handled by the presence path"
  assert_equals 0 "$(count_notes "$home")" "a natural-language AWAY command reached generic inbox"
  out=$(call_plugin "$home" 8629896233 msg-away-3 "Stepping out for dinner; please use Telegram while I'm away") \
    || fail "plugin call failed for semantic AWAY"
  assert_contains "$out" '"result": "mode:AWAY"' "semantic AWAY variant was not handled by the presence path"
  assert_equals 0 "$(count_notes "$home")" "a semantic AWAY command reached generic inbox"
  assert_equals 3 "$(wc -l < "$home/hermes-send.log" | tr -d '[:space:]')" \
    "each distinct AWAY command should send exactly one confirmation"
  pass "clear AWAY commands are consumed by the dedicated inbound presence handler"
}

test_home_presence_commands_are_consumed_before_generic_inbox() {
  local home out
  home=$(make_home home-presence)
  configure_hermes "$home"
  run_notify "$home" presence away >/dev/null
  : > "$home/hermes-send.log"
  out=$(call_plugin "$home" 8629896233 msg-home-1 "Captain home") \
    || fail "plugin call failed for Captain home"
  assert_contains "$out" '"result": "mode:HOME"' "Captain home was not handled by the presence path"
  assert_equals HOME "$(run_notify "$home" presence status)" "Captain home did not persist HOME"
  assert_equals 0 "$(count_notes "$home")" "a consumed HOME command was also queued as a generic inbox note"
  assert_grep 'Captain presence is now HOME' "$home/hermes-send.log" \
    "the HOME command did not send its one confirmation"

  run_notify "$home" presence away >/dev/null
  : > "$home/hermes-send.log"
  out=$(call_plugin "$home" 8629896233 msg-home-2 "I'm back home, stop proactive Telegram notifications") \
    || fail "plugin call failed for natural-language HOME"
  assert_contains "$out" '"result": "mode:HOME"' "natural-language HOME was not handled by the presence path"
  assert_equals HOME "$(run_notify "$home" presence status)" "natural-language HOME did not persist HOME"
  assert_equals 0 "$(count_notes "$home")" "a natural-language HOME command reached generic inbox"
  pass "clear HOME commands are consumed by the dedicated inbound presence handler"
}

test_ambiguous_and_normal_messages_fall_through_once_to_generic_inbox() {
  local home out
  home=$(make_home generic-fallback)
  configure_hermes "$home"
  out=$(call_plugin "$home" 8629896233 msg-ambiguous-1 "I might be away later, maybe use Telegram") \
    || fail "plugin call failed for ambiguous text"
  assert_contains "$out" '"relayed to FirstMate Primary inbox"' "ambiguous text did not fall through to inbox"
  assert_equals HOME "$(run_notify "$home" presence status)" "ambiguous text changed presence"
  assert_equals 1 "$(count_notes "$home")" "ambiguous text did not create exactly one generic note"
  assert_equals 1 "$(count_inbox_wakes "$home")" "ambiguous text did not create exactly one inbox wake"
  [ -s "$home/hermes-send.log" ] && fail "ambiguous text sent a presence confirmation"

  out=$(call_plugin "$home" 8629896233 msg-normal-1 "Any updates?") \
    || fail "plugin call failed for normal text"
  assert_contains "$out" '"relayed to FirstMate Primary inbox"' "normal text did not fall through to inbox"
  assert_equals 2 "$(count_notes "$home")" "normal text did not create exactly one additional generic note"
  assert_equals 2 "$(count_inbox_wakes "$home")" "normal text did not create exactly one additional inbox wake"
  [ -s "$home/hermes-send.log" ] && fail "normal text sent a presence confirmation"
  pass "ambiguous and normal Telegram messages fall through once to the generic inbox"
}

test_unauthorized_chat_is_ignored() {
  local home out
  home=$(make_home unauthorized)
  configure_hermes "$home"
  out=$(call_plugin "$home" 111111111 msg-unauth-1 "Captain away") \
    || fail "plugin call failed for unauthorized chat"
  assert_equals null "$out" "unauthorized chat was not left to Hermes"
  assert_equals 0 "$(count_notes "$home")" "unauthorized chat wrote an inbox note"
  [ -s "$home/hermes-send.log" ] && fail "unauthorized chat sent a confirmation"
  pass "unauthorized Telegram chats are ignored exactly at the plugin boundary"
}

test_replayed_presence_event_is_deduped_without_a_second_response() {
  local home first second
  home=$(make_home replay-presence)
  configure_hermes "$home"
  first=$(call_plugin "$home" 8629896233 msg-replay-1 "Captain away") \
    || fail "first replay fixture call failed"
  second=$(call_plugin "$home" 8629896233 msg-replay-1 "Captain away") \
    || fail "second replay fixture call failed"
  assert_contains "$first" '"result": "mode:AWAY"' "first replay fixture call did not consume presence"
  assert_contains "$second" '"duplicate Telegram event already relayed"' \
    "replayed presence event was not recognized as a duplicate"
  assert_equals 1 "$(wc -l < "$home/hermes-send.log" | tr -d '[:space:]')" \
    "replayed presence event sent a second confirmation"
  assert_equals 0 "$(count_notes "$home")" "replayed presence event created a generic note"
  pass "a replayed gateway dispatch of one presence event is deduped without a second response"
}

test_replayed_generic_event_uses_inbox_request_id_dedupe() {
  local home first second
  home=$(make_home replay-generic)
  configure_hermes "$home"
  first=$(call_plugin "$home" 8629896233 msg-replay-generic "Any updates?") \
    || fail "first generic replay fixture call failed"
  second=$(call_plugin "$home" 8629896233 msg-replay-generic "Any updates?") \
    || fail "second generic replay fixture call failed"
  assert_contains "$first" '"relayed to FirstMate Primary inbox"' "first generic event was not queued"
  assert_contains "$second" '"duplicate Telegram event already relayed"' \
    "second generic event was not deduped"
  assert_equals 1 "$(count_notes "$home")" "replayed generic event created a second note"
  assert_equals 1 "$(count_inbox_wakes "$home")" "replayed generic event created a second wake"
  pass "a replayed gateway dispatch of one generic event is deduped without a second note"
}

test_confirmation_failure_is_consumed_and_retried_by_notify() {
  local home out retry
  home=$(make_home confirm-fail)
  configure_hermes "$home"
  : > "$home/hermes-fail-once"
  out=$(call_plugin "$home" 8629896233 msg-confirm-fail "Captain away") \
    || fail "plugin call failed for failed confirmation"
  assert_contains "$out" '"result": "mode:AWAY"' "confirmation failure did not still consume the mode command"
  assert_equals AWAY "$(run_notify "$home" presence status)" "failed confirmation rolled back AWAY"
  assert_equals 0 "$(count_notes "$home")" "failed confirmation queued a generic note"
  assert_grep "status=failed" "$home/state/hermes-notify/.presence-confirm.record" \
    "failed confirmation was not durably preserved"
  retry=$(run_notify "$home" confirm-retry) || fail "confirm-retry failed after plugin partial success: $retry"
  assert_contains "$retry" "confirmation:sent" "confirm-retry did not report a sent confirmation"
  assert_grep 'Captain presence is now AWAY' "$home/hermes-send.log" \
    "confirm-retry did not deliver the stored confirmation"
  pass "a failed presence confirmation is consumed once and retried through fm-hermes-notify"
}

test_away_presence_commands_are_consumed_before_generic_inbox
test_home_presence_commands_are_consumed_before_generic_inbox
test_ambiguous_and_normal_messages_fall_through_once_to_generic_inbox
test_unauthorized_chat_is_ignored
test_replayed_presence_event_is_deduped_without_a_second_response
test_replayed_generic_event_uses_inbox_request_id_dedupe
test_confirmation_failure_is_consumed_and_retried_by_notify
