#!/usr/bin/env bash
# tests/fm-slack-dm.test.sh - Slack DM helper config, API, and redaction tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-slack-dm.mjs"
TMP_ROOT=$(fm_test_tmproot fm-slack-dm-tests)
SLACK_SERVER_PIDS=()

cleanup_slack_dm_tests() {
  local pid
  for pid in "${SLACK_SERVER_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_slack_dm_tests EXIT

make_slack_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/config"
  printf '%s\n' "$dir"
}

write_dm_config() {  # <dir> <destination> <token-source>
  local dir=$1 dest=$2 source=$3
  {
    printf 'destination=%s\n' "$dest"
    printf 'sender=slack-api\n'
    printf 'token-source=%s\n' "$source"
  } > "$dir/config/afk-slack-dm"
}

write_dm_message() {  # <dir> [body]
  local dir=$1 body=${2:-"AI agent for Tim here — update from your fleet:"$'\n'"- done: ready"}
  printf '%s\n' "$body" > "$dir/message.txt"
}

start_fake_slack() {  # <dir> <mode>
  local dir=$1 mode=$2 port_file req_file script pid
  port_file="$dir/port"
  req_file="$dir/requests.jsonl"
  script="$dir/fake-slack.mjs"
  cat > "$script" <<'JS'
import http from "node:http";
import fs from "node:fs";

const [portFile, reqFile, mode] = process.argv.slice(2);
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => { body += chunk; });
  req.on("end", () => {
    const auth = req.headers.authorization ? "present" : "absent";
    fs.appendFileSync(reqFile, JSON.stringify({ method: req.method, url: req.url, auth, body }) + "\n");
    res.setHeader("Content-Type", "application/json");
    if (mode === "api-error") {
      res.end(JSON.stringify({ ok: false, error: process.env.FAKE_SLACK_ERROR || "invalid_auth" }));
      return;
    }
    if (mode === "slow-success") {
      setTimeout(() => {
        res.end(JSON.stringify({ ok: true, ts: "123.456" }));
      }, 1000);
      return;
    }
    res.end(JSON.stringify({ ok: true, ts: "123.456" }));
  });
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
JS
  FAKE_SLACK_ERROR="${FAKE_SLACK_ERROR:-}" node "$script" "$port_file" "$req_file" "$mode" >/dev/null 2>&1 &
  pid=$!
  SLACK_SERVER_PIDS+=("$pid")
  while [ ! -s "$port_file" ]; do sleep 0.05; done
  printf 'http://127.0.0.1:%s/api/chat.postMessage\n' "$(cat "$port_file")"
}

test_slack_dm_success_posts_chat_message() {
  local dir token_file api out status req body channel
  dir=$(make_slack_case success)
  token_file="$dir/token"
  printf 'xoxb-test-success\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file"
  write_dm_message "$dir"
  api=$(start_fake_slack "$dir" success)

  out=$(FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  expect_code 0 "$status" "helper success"
  assert_contains "$out" "slack-dm sent destination=U123ABC ts=123.456" "success output missing"
  req=$(tail -1 "$dir/requests.jsonl")
  assert_contains "$req" '"auth":"present"' "request did not include bearer auth"
  body=$(printf '%s' "$req" | node -e 'const fs=require("fs"); const r=JSON.parse(fs.readFileSync(0,"utf8")); console.log(JSON.parse(r.body).text)')
  channel=$(printf '%s' "$req" | node -e 'const fs=require("fs"); const r=JSON.parse(fs.readFileSync(0,"utf8")); console.log(JSON.parse(r.body).channel)')
  assert_contains "$body" "AI agent for Tim here —" "request body missing required prefix"
  [ "$channel" = U123ABC ] || fail "request body did not target the configured user: $channel"
  assert_not_contains "$out" "xoxb-test-success" "success output leaked token"
  pass "fm-slack-dm posts chat.postMessage payload on success"
}

test_slack_dm_api_error_fails_without_leaking_token() {
  local dir token_file api out status
  dir=$(make_slack_case api-error)
  token_file="$dir/token"
  printf 'xoxb-api-secret\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file"
  write_dm_message "$dir"
  FAKE_SLACK_ERROR='xoxb-api-secret'
  api=$(start_fake_slack "$dir" api-error)
  unset FAKE_SLACK_ERROR

  out=$(FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "helper should fail on Slack API ok:false"
  assert_contains "$out" "slack-api-error" "Slack API error was not classified"
  assert_not_contains "$out" "xoxb-api-secret" "API error output leaked token"
  pass "fm-slack-dm fails on Slack API error without token leakage"
}

test_slack_dm_network_error_fails() {
  local dir token_file out status
  dir=$(make_slack_case network-error)
  token_file="$dir/token"
  printf 'xoxb-network-secret\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file"
  write_dm_message "$dir"

  out=$(FM_SLACK_DM_API_URL="http://127.0.0.1:9/api/chat.postMessage" \
    "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "helper should fail on network error"
  assert_contains "$out" "network-error" "network error was not classified"
  assert_not_contains "$out" "xoxb-network-secret" "network error output leaked token"
  pass "fm-slack-dm fails closed on network errors"
}

test_slack_dm_missing_token_degrades_without_request() {
  local dir api out status
  dir=$(make_slack_case missing-token)
  write_dm_config "$dir" U123ABC "file:$dir/no-token-here"
  write_dm_message "$dir"
  api=$(start_fake_slack "$dir" success)

  out=$(FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "helper should fail when token source is empty"
  assert_contains "$out" "missing-token" "missing token was not classified"
  [ ! -e "$dir/requests.jsonl" ] || fail "helper called Slack despite missing token"
  pass "fm-slack-dm degrades gracefully when no token is available"
}

test_slack_dm_rejects_channel_destination() {
  local dir token_file api out status
  dir=$(make_slack_case invalid-destination)
  token_file="$dir/token"
  printf 'xoxb-invalid-secret\n' > "$token_file"
  write_dm_config "$dir" C123CHANNEL "file:$token_file"
  write_dm_message "$dir"
  api=$(start_fake_slack "$dir" success)

  out=$(FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "helper should reject channel destinations"
  assert_contains "$out" "destination must be a Slack user ID" "invalid destination error missing"
  [ ! -e "$dir/requests.jsonl" ] || fail "helper called Slack despite invalid destination"
  assert_not_contains "$out" "xoxb-invalid-secret" "invalid destination output leaked token"
  pass "fm-slack-dm rejects channel IDs before sending"
}

test_slack_dm_requires_message_prefix() {
  local dir token_file out status
  dir=$(make_slack_case prefix)
  token_file="$dir/token"
  printf 'xoxb-prefix-secret\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file"
  printf 'missing attribution\n' > "$dir/message.txt"

  out=$("$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "helper should reject unattributed messages"
  assert_contains "$out" "required AI agent attribution" "prefix rejection missing"
  assert_not_contains "$out" "xoxb-prefix-secret" "prefix error output leaked token"
  pass "fm-slack-dm requires the AI agent attribution prefix"
}

test_slack_dm_token_not_in_process_args() {
  local dir token_file api out pid args status
  dir=$(make_slack_case process-args)
  token_file="$dir/token"
  printf 'xoxb-argv-secret\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file"
  write_dm_message "$dir"
  api=$(start_fake_slack "$dir" slow-success)

  FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" >"$dir/helper.out" 2>&1 &
  pid=$!
  sleep 0.2
  args=$(ps -ww -o command= -p "$pid" 2>/dev/null || true)
  wait "$pid"
  status=$?
  out=$(cat "$dir/helper.out")

  expect_code 0 "$status" "helper slow success"
  assert_not_contains "$args" "xoxb-argv-secret" "helper process args leaked token"
  assert_not_contains "$out" "xoxb-argv-secret" "helper output leaked token"
  pass "fm-slack-dm keeps token out of process args"
}

test_slack_dm_command_token_not_in_process_args() {
  local dir api out pid args child status secret
  dir=$(make_slack_case command-process-args)
  secret=xoxb-command-argv-secret
  write_dm_config "$dir" U123ABC "command:sleep 1; printf '%s\\n' $secret"
  write_dm_message "$dir"
  api=$(start_fake_slack "$dir" success)

  FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" >"$dir/helper.out" 2>&1 &
  pid=$!
  sleep 0.2
  args=$(ps -ww -o command= -p "$pid" 2>/dev/null || true)
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    args="${args}"$'\n'"$(ps -ww -o command= -p "$child" 2>/dev/null || true)"
  done
  wait "$pid"
  status=$?
  out=$(cat "$dir/helper.out")

  expect_code 0 "$status" "helper command-token success"
  assert_not_contains "$args" "$secret" "command token source leaked token through process args"
  assert_not_contains "$out" "$secret" "command token source leaked token through output"
  pass "fm-slack-dm keeps command token output out of process args"
}

test_slack_dm_success_posts_chat_message
test_slack_dm_api_error_fails_without_leaking_token
test_slack_dm_network_error_fails
test_slack_dm_missing_token_degrades_without_request
test_slack_dm_rejects_channel_destination
test_slack_dm_requires_message_prefix
test_slack_dm_token_not_in_process_args
test_slack_dm_command_token_not_in_process_args
