#!/usr/bin/env bash
# Behavior tests for the Discord workspace process-event adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-discord-workspace-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
HOME1="$TMP_ROOT/home1"
HOME2="$TMP_ROOT/home2"
HOME3="$TMP_ROOT/home3"
HOME4="$TMP_ROOT/home4"
HOME5="$TMP_ROOT/home5"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
ped() { FM_HOME="$1" "$ROOT/bin/fm-procevent-discord-workspace.sh" "${@:2}"; }

cleanup_procevent_discord() {
  pe "$HOME1" sweep-home >/dev/null 2>&1 || true
  pe "$HOME2" sweep-home >/dev/null 2>&1 || true
  pe "$HOME3" sweep-home >/dev/null 2>&1 || true
  pe "$HOME4" sweep-home >/dev/null 2>&1 || true
  pe "$HOME5" sweep-home >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_procevent_discord EXIT

make_config() {
  local home=$1 cfg=$2
  mkdir -p "$home/state" "$home/data" "$home/config"
  chmod 700 "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-discord-workspace.sh" sample-config > "$cfg"
  python3 - "$cfg" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["profiles"]["proapplis"]["thread_ids"]["exchange"]=["888888888888888881"]
data["transcription"]["provider"]="fake"
data["transcription"]["fake_transcripts"]={
  "999999999999999998":"transcribed voice fixture",
  "999999999999999996":"transcribed upload fixture"
}
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
}

note_count() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

wake_count() {
  awk 'END { print NR + 0 }' "$1/state/.wake-queue" 2>/dev/null
}

wake_payloads() {
  awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null
}

first_note() {
  local home=$1
  for f in "$home/state/inbox"/*.note; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

result_path() {
  local home=$1 seq=$2
  printf '%s/state/procevent-inbox/discord-workspace.%s.result\n' "$home" "$seq"
}

CFG1="$HOME1/config/discord-workspace.json"
make_config "$HOME1" "$CFG1"
for invalid_limit in NaN Infinity 0; do
  INVALID_CFG="$TMP_ROOT/invalid-limit-$invalid_limit.json"
  python3 - "$CFG1" "$INVALID_CFG" "$invalid_limit" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["audio"]["max_duration_secs"] = sys.argv[3]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_status=0
  invalid_out=$(FM_HOME="$HOME1" "$ROOT/bin/fm-discord-workspace.sh" config-check --config "$INVALID_CFG" 2>&1) || invalid_status=$?
  [ "$invalid_status" -ne 0 ] || fail "audio duration limit $invalid_limit was accepted"
  assert_contains "$invalid_out" "positive finite number" "invalid audio duration limit is refused"
done
pass "audio configuration rejects non-finite and non-positive durations"

FIXTURE1="$TMP_ROOT/messages.json"
cat > "$FIXTURE1" <<'JSON'
{
  "messages": [
    {"id":"999999999999999991","channel_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"direct message without a guild"},
    {"id":"999999999999999992","guild_id":"121212121212121212","channel_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"wrong guild"},
    {"id":"999999999999999993","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"333333333333333333","bot":true},"content":"bot message"},
    {"id":"999999999999999994","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"454545454545454545"},"content":"wrong author"},
    {"id":"999999999999999995","guild_id":"111111111111111111","channel_id":"555555555555555553","author":{"id":"444444444444444444"},"content":"artifact forum input"},
    {"id":"999999999999999996","guild_id":"111111111111111111","channel_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"forum root input without an allowlisted thread"},
    {"id":"999999999999999997","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"Thread text request."}
  ]
}
JSON

out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE1" ped "$HOME1" source --config "$CFG1")
assert_contains "$out" "Thread text request" "source returns the first allowlisted exchange-thread message"
assert_not_contains "$out" "wrong guild" "source skips unknown guilds"
printf '%s\n' "$out" > "$TMP_ROOT/result.json"
class=$(ped "$HOME1" classify "$TMP_ROOT/result.json")
assert_contains "$class" "message" "classify identifies accepted text messages"
if ped "$HOME1" silent "$TMP_ROOT/result.json" >/dev/null 2>&1; then
  fail "accepted text message was classified silent"
fi
pass "source enforces guild, channel, author, bot, and forum allowlists"

nofixture_status=0
nofixture_out=$(ped "$HOME1" source --config "$CFG1" 2>&1) || nofixture_status=$?
[ "$nofixture_status" -ne 0 ] || fail "source without fixture succeeded"
assert_contains "$nofixture_out" "no network call" "source without fixture refuses before network"
out=$(ped "$HOME1" arm --dry-run --config "$CFG1")
assert_contains "$out" "arm dry-run" "arm dry-run is explicit"
assert_contains "$out" "register command" "arm dry-run prints the registration command"
arm_status=0
arm_out=$(ped "$HOME1" arm --config "$CFG1" 2>&1) || arm_status=$?
[ "$arm_status" -ne 0 ] || fail "non-dry-run arm was accepted"
assert_contains "$arm_out" "live polling is disabled" "non-dry-run arm refuses while live polling is disabled"
pass "process-event arming remains offline unless a later live task activates it"

pe "$HOME1" register discord-workspace discord-workspace -- \
  "$ROOT/bin/fm-procevent-discord-workspace.sh" source --config "$CFG1" >/dev/null
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE1" pe "$HOME1" start discord-workspace)
assert_contains "$out" "autohandled" "process-event start autohandles accepted Discord messages"
assert_present "$(result_path "$HOME1" 1)" "first captured Discord result exists"
assert_present "$HOME1/state/procevent-inbox/discord-workspace.1.handled" "autohandle records the process-event acknowledgement"
[ "$(note_count "$HOME1")" = 1 ] || fail "autohandle created the wrong inbox note count"
[ "$(wake_count "$HOME1")" = 1 ] || fail "autohandle created the wrong wake count"
assert_contains "$(wake_payloads "$HOME1")" "captain inbox note" "accepted Discord event announces through the inbox"
assert_not_contains "$(wake_payloads "$HOME1")" "procevent discord-workspace" "self-announcing adapter suppresses duplicate process-event wake"
NOTE=$(first_note "$HOME1") || fail "autohandle did not create an inbox note"
assert_grep "Discord workspace / proapplis / text" "$NOTE" "note body identifies Discord text intake"
assert_grep "Thread text request." "$NOTE" "note body preserves the captain text"
ack_out=$(pe "$HOME1" handled discord-workspace 1)
assert_contains "$ack_out" "already-handled" "process-event acknowledgement is idempotent"
link_out=$(FM_HOME="$HOME1" "$ROOT/bin/fm-discord-workspace.sh" link-task inbound-task \
  --config "$CFG1" \
  --request-id discord:111111111111111111:888888888888888881:999999999999999997)
assert_contains "$link_out" "request record exists" "task linking reuses the canonical inbound request record"
assert_contains "$link_out" "task link written" "processed inbound request links to a task"
pass "processed inbound requests use the task-link request shape"

rm -f "$HOME1/state/discord-workspace/cursors/proapplis/888888888888888881.cursor"
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE1" pe "$HOME1" start discord-workspace)
assert_contains "$out" "autohandled" "replayed fixture is still handled"
assert_present "$HOME1/state/procevent-inbox/discord-workspace.2.handled" "replayed fixture is acknowledged"
[ "$(note_count "$HOME1")" = 1 ] || fail "replayed Discord message created a duplicate inbox note"
[ "$(wake_count "$HOME1")" = 1 ] || fail "replayed Discord message created a duplicate inbox wake"
pass "Discord process-event replay deduplicates through fm-inbox external ids"

CFG2="$HOME2/config/discord-workspace.json"
make_config "$HOME2" "$CFG2"
for invalid_duration in NaN Infinity 0; do
  INVALID_AUDIO="$TMP_ROOT/invalid-audio-$invalid_duration.json"
  cat > "$INVALID_AUDIO" <<JSON
{"messages":[{"id":"999999999999999990","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"444444444444444444"},"flags":8192,"attachments":[{"id":"101010101010101011","filename":"voice.ogg","content_type":"audio/ogg","size":1024,"duration_secs":"$invalid_duration","url":"https://cdn.discordapp.com/attachments/1/voice.ogg"}]}]}
JSON
  invalid_audio_out=$(FM_DISCORD_WORKSPACE_FIXTURE="$INVALID_AUDIO" ped "$HOME2" source --config "$CFG2")
  assert_contains "$invalid_audio_out" '"kind": "audio-rejected"' "invalid attachment duration is rejected"
  assert_contains "$invalid_audio_out" "positive finite number" "invalid attachment duration refusal names the boundary"
done
pass "audio attachments reject non-finite and non-positive durations"

for metadata_case in size-boolean size-string size-fraction duration-boolean duration-string; do
  INVALID_METADATA="$TMP_ROOT/invalid-metadata-$metadata_case.json"
  python3 - "$INVALID_METADATA" "$metadata_case" <<'PY'
import json, sys
case = sys.argv[2]
size = {"size-boolean": True, "size-string": "1024", "size-fraction": 1024.5}.get(case, 1024)
duration = {"duration-boolean": True, "duration-string": "12"}.get(case, 12)
data = {"messages": [{
    "id": "999999999999999990",
    "guild_id": "111111111111111111",
    "channel_id": "888888888888888881",
    "parent_id": "555555555555555552",
    "author": {"id": "444444444444444444"},
    "flags": 8192,
    "attachments": [{
        "id": "101010101010101011",
        "filename": "voice.ogg",
        "content_type": "audio/ogg",
        "size": size,
        "duration_secs": duration,
        "url": "https://cdn.discordapp.com/attachments/1/voice.ogg",
    }],
}]}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_metadata_out=$(FM_DISCORD_WORKSPACE_FIXTURE="$INVALID_METADATA" ped "$HOME2" source --config "$CFG2")
  assert_contains "$invalid_metadata_out" '"kind": "audio-rejected"' "invalid $metadata_case metadata is rejected"
  case "$metadata_case" in
    size-*) assert_contains "$invalid_metadata_out" "positive JSON integer" "invalid $metadata_case refusal names the JSON type boundary" ;;
    *) assert_contains "$invalid_metadata_out" "encoded as a JSON number" "invalid $metadata_case refusal names the JSON type boundary" ;;
  esac
done
pass "audio metadata preserves strict JSON numeric types"

for flags_case in boolean numeric-string invalid-string negative; do
  INVALID_FLAGS="$TMP_ROOT/invalid-flags-$flags_case.json"
  python3 - "$INVALID_FLAGS" "$flags_case" <<'PY'
import json, sys
flags = {"boolean": True, "numeric-string": "8192", "invalid-string": "voice", "negative": -1}[sys.argv[2]]
data = {"messages": [{
    "id": "999999999999999990",
    "guild_id": "111111111111111111",
    "channel_id": "888888888888888881",
    "parent_id": "555555555555555552",
    "author": {"id": "444444444444444444"},
    "content": "Retain rejected text context.",
    "flags": flags,
    "attachments": [{
        "id": "101010101010101011",
        "filename": "voice.ogg",
        "content_type": "audio/ogg",
        "size": 1024,
        "duration_secs": 12,
        "url": "https://cdn.discordapp.com/attachments/1/voice.ogg",
    }],
}]}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_flags_status=0
  invalid_flags_out=$(FM_DISCORD_WORKSPACE_FIXTURE="$INVALID_FLAGS" ped "$HOME2" source --config "$CFG2") || invalid_flags_status=$?
  [ "$invalid_flags_status" -eq 0 ] || fail "malformed $flags_case flags aborted Discord source"
  assert_contains "$invalid_flags_out" '"kind": "message-rejected"' "malformed $flags_case flags produce a controlled rejection"
  assert_not_contains "$invalid_flags_out" '"kind": "audio-rejected"' "malformed general metadata is not mislabeled as audio"
  assert_contains "$invalid_flags_out" "Retain rejected text context." "malformed $flags_case flags retain safe text context"
  assert_contains "$invalid_flags_out" "non-negative JSON integer" "malformed $flags_case flags name the type boundary"
done
for bot_case in string-false numeric-zero; do
  INVALID_BOT="$TMP_ROOT/invalid-bot-$bot_case.json"
  python3 - "$INVALID_BOT" "$bot_case" <<'PY'
import json, sys
bot = {"string-false": "false", "numeric-zero": 0}[sys.argv[2]]
data = {"messages": [{
    "id": "999999999999999990",
    "guild_id": "111111111111111111",
    "channel_id": "888888888888888881",
    "parent_id": "555555555555555552",
    "author": {"id": "444444444444444444", "bot": bot},
    "content": "Retain malformed author context.",
}]}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_bot_status=0
  invalid_bot_out=$(FM_DISCORD_WORKSPACE_FIXTURE="$INVALID_BOT" ped "$HOME2" source --config "$CFG2") || invalid_bot_status=$?
  [ "$invalid_bot_status" -eq 0 ] || fail "malformed $bot_case bot metadata aborted Discord source"
  assert_contains "$invalid_bot_out" '"kind": "message-rejected"' "malformed $bot_case bot metadata produces a generic rejection"
  assert_contains "$invalid_bot_out" "author bot metadata must be a JSON boolean" "malformed $bot_case bot metadata names the type boundary"
  assert_contains "$invalid_bot_out" "Retain malformed author context." "malformed $bot_case bot metadata retains text context"
done
for container_case in attachments author content attachment-member; do
  INVALID_CONTAINER="$TMP_ROOT/invalid-container-$container_case.json"
  python3 - "$INVALID_CONTAINER" "$container_case" <<'PY'
import json, sys
message = {
    "id": "999999999999999990",
    "guild_id": "111111111111111111",
    "channel_id": "888888888888888881",
    "parent_id": "555555555555555552",
    "author": {"id": "444444444444444444"},
    "content": "Retain malformed container context.",
}
if sys.argv[2] == "attachments":
    message["attachments"] = {}
elif sys.argv[2] == "author":
    message["author"] = []
    message["author_id"] = "444444444444444444"
elif sys.argv[2] == "content":
    message["content"] = {"request": "not text"}
else:
    message["attachments"] = ["not an object"]
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({"messages": [message]}, stream)
PY
  invalid_container_status=0
  invalid_container_out=$(FM_DISCORD_WORKSPACE_FIXTURE="$INVALID_CONTAINER" ped "$HOME2" source --config "$CFG2") || invalid_container_status=$?
  [ "$invalid_container_status" -eq 0 ] || fail "malformed $container_case container aborted Discord source"
  assert_contains "$invalid_container_out" '"kind": "message-rejected"' "malformed $container_case container produces a generic rejection"
  case "$container_case" in
    attachments) assert_contains "$invalid_container_out" "message.attachments must be a list" "malformed attachments container names the type boundary" ;;
    author) assert_contains "$invalid_container_out" "message author metadata must be a JSON object" "malformed author container names the type boundary" ;;
    content)
      assert_contains "$invalid_container_out" "message content must be a JSON string" "malformed content names the type boundary"
      assert_not_contains "$invalid_container_out" "not text" "malformed content is not coerced into request text"
      ;;
    attachment-member) assert_contains "$invalid_container_out" "attachments must contain only JSON objects" "malformed attachment member names the type boundary" ;;
  esac
  if [ "$container_case" != content ]; then
    assert_contains "$invalid_container_out" "Retain malformed container context." "malformed $container_case container retains text context"
  fi
done
CFG4="$HOME4/config/discord-workspace.json"
make_config "$HOME4" "$CFG4"
pe "$HOME4" register discord-workspace discord-workspace -- \
  "$ROOT/bin/fm-procevent-discord-workspace.sh" source --config "$CFG4" >/dev/null
MALFORMED_SEQUENCE="$TMP_ROOT/malformed-sequence.json"
cat > "$MALFORMED_SEQUENCE" <<'JSON'
{"messages":[
  {"id":"999999999999999991","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"444444444444444444"},"attachments":{},"content":"Retain malformed attachment context."},
  {"id":"999999999999999992","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"Message after malformed metadata."}
]}
JSON
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$MALFORMED_SEQUENCE" pe "$HOME4" start discord-workspace)
assert_contains "$out" "autohandled" "generic metadata rejection is autohandled"
NOTE4=$(first_note "$HOME4") || fail "generic metadata rejection did not create an inbox note"
assert_grep "message rejected" "$NOTE4" "invalid general metadata creates a generic rejection note"
assert_grep "context: Retain malformed attachment context." "$NOTE4" "generic rejection note retains safe text context"
assert_not_contains "$(cat "$NOTE4")" "audio rejected" "generic rejection note does not claim an audio failure"
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$MALFORMED_SEQUENCE" pe "$HOME4" start discord-workspace)
assert_contains "$out" "autohandled" "intake advances beyond malformed message metadata"
[ "$(note_count "$HOME4")" = 2 ] || fail "malformed metadata prevented the following message from being captured"
grep -q "Message after malformed metadata." "$HOME4/state/inbox/"*.note \
  || fail "message following malformed metadata was not preserved"
pass "malformed message containers reject durably without wedging intake"

HIGH_CURSOR_FIXTURE="$TMP_ROOT/high-cursor.json"
LOW_CURSOR_FIXTURE="$TMP_ROOT/low-cursor.json"
python3 - "$HIGH_CURSOR_FIXTURE" "$LOW_CURSOR_FIXTURE" <<'PY'
import json, sys
def fixture(message_id):
    return {"messages": [{
        "id": message_id,
        "guild_id": "111111111111111111",
        "channel_id": "888888888888888881",
        "parent_id": "555555555555555552",
        "author": {"id": "333333333333333333", "bot": True},
        "content": "ignored bot fixture",
    }]}
for path, message_id in zip(sys.argv[1:], ("999999999999999995", "999999999999999994")):
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(fixture(message_id), stream)
PY
state_lock="$HOME4/state/discord-workspace/.state.lock"
mkdir -p "$(dirname "$state_lock")"
exec 9>"$state_lock"
flock -x 9
FM_DISCORD_WORKSPACE_FIXTURE="$HIGH_CURSOR_FIXTURE" ped "$HOME4" source --config "$CFG4" >"$TMP_ROOT/high-cursor.out" 2>&1 9>&- &
high_cursor_pid=$!
sleep 0.1
kill -0 "$high_cursor_pid" 2>/dev/null || fail "high cursor update did not wait for the state transaction"
FM_DISCORD_WORKSPACE_FIXTURE="$LOW_CURSOR_FIXTURE" ped "$HOME4" source --config "$CFG4" >"$TMP_ROOT/low-cursor.out" 2>&1 9>&- &
low_cursor_pid=$!
sleep 0.1
flock -u 9
exec 9>&-
high_cursor_status=0
low_cursor_status=0
wait "$high_cursor_pid" || high_cursor_status=$?
wait "$low_cursor_pid" || low_cursor_status=$?
[ "$high_cursor_status" -eq 75 ] && [ "$low_cursor_status" -eq 75 ] \
  || fail "ignored cursor fixtures returned unexpected statuses: $high_cursor_status $low_cursor_status"
cursor_value=$(cat "$HOME4/state/discord-workspace/cursors/proapplis/888888888888888881.cursor")
[ "$cursor_value" = 999999999999999995 ] || fail "concurrent cursor updates regressed to $cursor_value"
pass "concurrent cursor updates advance monotonically"

REQUEST_FIXTURE="$TMP_ROOT/concurrent-request.json"
cat > "$REQUEST_FIXTURE" <<'JSON'
{"messages":[{"id":"999999999999999999","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"Concurrent request binding."}]}
JSON
REASSIGNED_CFG="$TMP_ROOT/reassigned-request.json"
python3 - "$CFG4" "$REASSIGNED_CFG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["profiles"]["proapplis"]["thread_ids"]["exchange"] = []
data["profiles"]["folium"]["thread_ids"]["exchange"] = ["888888888888888881"]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
concurrent_request_id='discord:111111111111111111:888888888888888881:999999999999999999'
request_digest=$(python3 - "$concurrent_request_id" <<'PY'
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
PY
)
request_record="$HOME4/state/discord-workspace/requests/$request_digest.json"
baseline_note_count=$(note_count "$HOME4")
exec 9>"$state_lock"
flock -x 9
FM_HOME="$HOME4" "$ROOT/bin/fm-discord-workspace.sh" link-task concurrent-binding \
  --config "$REASSIGNED_CFG" --request-id "$concurrent_request_id" >"$TMP_ROOT/concurrent-link.out" 2>&1 9>&- &
concurrent_link_pid=$!
sleep 0.1
kill -0 "$concurrent_link_pid" 2>/dev/null || fail "concurrent task link did not wait for the state transaction"
FM_DISCORD_WORKSPACE_FIXTURE="$REQUEST_FIXTURE" pe "$HOME4" start discord-workspace >"$TMP_ROOT/concurrent-autohandle.out" 2>&1 9>&- &
autohandle_pid=$!
sleep 0.2
[ "$(note_count "$HOME4")" = "$baseline_note_count" ] \
  || fail "blocked autohandle exposed an inbox note before canonical request publication"
assert_absent "$request_record" "concurrent request publication waits for the state transaction"
flock -u 9
exec 9>&-
autohandle_status=0
concurrent_link_status=0
wait "$concurrent_link_pid" || concurrent_link_status=$?
wait "$autohandle_pid" || autohandle_status=$?
[ "$concurrent_link_status" -eq 0 ] \
  || fail "first concurrent request publisher did not win: link=$concurrent_link_status autohandle=$autohandle_status"
python3 - "$request_record" "$HOME4/state/discord-workspace/task-links/concurrent-binding.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    request = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    link = json.load(stream)
if request["profile"] != "folium" or request["profile"] != link["profile"] or request["request_id"] != link["request_id"]:
    raise SystemExit("canonical request and task link bindings disagree")
PY
[ "$(note_count "$HOME4")" = "$baseline_note_count" ] \
  || fail "losing autohandle exposed a misprofiled inbox note"
pass "concurrent request conflicts leave no misprofiled inbox note"

FIXTURE2="$TMP_ROOT/voice.json"
cat > "$FIXTURE2" <<'JSON'
{
  "messages": [
    {
      "id":"999999999999999998",
      "guild_id":"111111111111111111",
      "channel_id":"888888888888888881",
      "parent_id":"555555555555555552",
      "author":{"id":"444444444444444444"},
      "content":"Voice context.",
      "flags":8192,
      "attachments":[{"id":"101010101010101010","filename":"voice.ogg","content_type":"audio/ogg","size":1024,"duration_secs":12,"url":"https://cdn.discordapp.com/attachments/1/voice.ogg"}]
    }
  ]
}
JSON
pe "$HOME2" register discord-workspace discord-workspace -- \
  "$ROOT/bin/fm-procevent-discord-workspace.sh" source --config "$CFG2" >/dev/null
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE2" pe "$HOME2" start discord-workspace)
assert_contains "$out" "autohandled" "voice fixture is autohandled"
NOTE2=$(first_note "$HOME2") || fail "voice fixture did not create a note"
assert_grep "voice transcript" "$NOTE2" "voice note is identified as a transcript"
assert_grep "caption: Voice context." "$NOTE2" "voice note preserves its text caption"
assert_grep "transcribed voice fixture" "$NOTE2" "fake transcription is used for voice fixtures"
assert_grep "transcription: fake fixture, no secret" "$NOTE2" "voice note does not print provider secrets"
assert_not_contains "$(cat "$NOTE2")" "FIRSTMATE_DISCORD_GROQ_API_KEY" "voice note does not leak secret key names"
pass "voice-message fixtures validate audio and produce safe transcript notes"

CFG3="$HOME3/config/discord-workspace.json"
make_config "$HOME3" "$CFG3"
FIXTURE3="$TMP_ROOT/bad-audio.json"
cat > "$FIXTURE3" <<'JSON'
{
  "messages": [
    {
      "id":"999999999999999996",
      "guild_id":"111111111111111111",
      "channel_id":"888888888888888881",
      "parent_id":"555555555555555552",
      "author":{"id":"444444444444444444"},
      "content":"Keep this rejected audio caption.",
      "flags":8192,
      "attachments":[{"id":"202020202020202020","filename":"voice.ogg","content_type":"audio/ogg","size":1024,"duration_secs":12,"url":"https://evil.example.invalid/voice.ogg"}]
    }
  ]
}
JSON
pe "$HOME3" register discord-workspace discord-workspace -- \
  "$ROOT/bin/fm-procevent-discord-workspace.sh" source --config "$CFG3" >/dev/null
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE3" pe "$HOME3" start discord-workspace)
assert_contains "$out" "autohandled" "bad audio rejection is autohandled"
NOTE3=$(first_note "$HOME3") || fail "bad audio fixture did not create an error note"
assert_grep "audio rejected" "$NOTE3" "bad audio creates a durable rejection note"
assert_grep "Discord CDN allowlist" "$NOTE3" "bad audio refusal names the failed check"
assert_grep "caption: Keep this rejected audio caption." "$NOTE3" "rejected audio note preserves its text caption"
assert_not_contains "$(cat "$NOTE3")" "do-not-print" "bad audio note does not leak secret material"
pass "audio intake rejects non-Discord CDN URLs with a durable non-secret note"

# --- forum child threads route through their verified configured parent ----
CFG5="$HOME5/config/discord-workspace.json"
make_config "$HOME5" "$CFG5"
python3 - "$CFG5" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
# Empty thread allowlists: forum posts must still enter via their parent forum.
data["profiles"]["proapplis"]["thread_ids"]["exchange"] = []
data["profiles"]["proapplis"]["thread_ids"]["artifacts"] = []
json.dump(data, open(p, "w"), indent=2, sort_keys=True)
PY

FIXTURE5="$TMP_ROOT/forum-childs.json"
cat > "$FIXTURE5" <<'JSON'
{
  "messages": [
    {"id":"888888888888888771","guild_id":"111111111111111111","channel_id":"777777777777777771","parent_id":"777777777777777772","author":{"id":"444444444444444444"},"content":"Forum child exchange request."},
    {"id":"888888888888888772","guild_id":"111111111111111111","channel_id":"777777777777777772","author":{"id":"444444444444444444"},"content":"forum root input"},
    {"id":"888888888888888773","guild_id":"111111111111111111","channel_id":"777777777777777775","parent_id":"777777777777777772","author":{"id":"444444444444444444"},"content":"wrong-forum parent"},
    {"id":"888888888888888774","guild_id":"111111111111111111","channel_id":"777777777777777776","parent_id":"777777777777777773","author":{"id":"444444444444444444"},"content":"artifact forum child"}
  ]
}
JSON
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE5" ped "$HOME5" source --config "$CFG5")
assert_contains "$out" "Forum child exchange request." \
  "a verified forum child thread enters its exchange lane without a pre-allowlisted id"
assert_not_contains "$out" "forum root input" "the forum channel itself is not accepted as a lane"
assert_not_contains "$out" "wrong-forum parent" "a child of another profile's forum stays out"
assert_not_contains "$out" "artifact forum child" "artifact forum children stay out of exchange intake"
pass "forum child threads route by their verified configured parent forum"
