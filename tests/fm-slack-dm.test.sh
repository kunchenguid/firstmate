#!/usr/bin/env bash
# tests/fm-slack-dm.test.sh - Slack DM helper config, API, and redaction tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-slack-dm.mjs"
TMP_ROOT=$(fm_test_tmproot fm-slack-dm-tests)
SLACK_SERVER_PIDS=()
SLACK_API_URL=""  # set by start_fake_slack in the parent shell

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

write_dm_config() {  # <dir> <destination> <token-source> [name]
  local dir=$1 dest=$2 source=$3 name=${4:-}
  {
    printf 'destination=%s\n' "$dest"
    printf 'sender=slack-api\n'
    [ -n "$name" ] && printf 'name=%s\n' "$name"
    printf 'token-source=%s\n' "$source"
  } > "$dir/config/afk-slack-dm"
}

write_dm_message() {  # <dir> [body]
  local dir=$1 body=${2:-"AI agent here — update from your fleet:"$'\n'"- done: ready"}
  printf '%s\n' "$body" > "$dir/message.txt"
}

# Start the fake Slack server, record its PID in the PARENT shell's
# SLACK_SERVER_PIDS (so cleanup_slack_dm_tests reaps it), and set the parent-shell
# variable SLACK_API_URL for the caller. MUST NOT be called in a command
# substitution: `$(start_fake_slack ...)` runs it in a subshell, so the PID append
# is discarded and the backgrounded node reparents to PID 1 and leaks. Call as
# `start_fake_slack "$dir" <mode>; api=$SLACK_API_URL` instead.
start_fake_slack() {  # <dir> <mode> -> sets SLACK_API_URL in the caller's shell
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
  SLACK_API_URL="http://127.0.0.1:$(cat "$port_file")/api/chat.postMessage"
}

test_slack_dm_success_posts_chat_message() {
  local dir token_file api out status req body channel
  dir=$(make_slack_case success)
  token_file="$dir/token"
  printf 'xoxb-test-success\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file"
  write_dm_message "$dir"
  start_fake_slack "$dir" success; api=$SLACK_API_URL

  out=$(FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  expect_code 0 "$status" "helper success"
  assert_contains "$out" "slack-dm sent destination=U123ABC ts=123.456" "success output missing"
  req=$(tail -1 "$dir/requests.jsonl")
  assert_contains "$req" '"auth":"present"' "request did not include bearer auth"
  body=$(printf '%s' "$req" | node -e 'const fs=require("fs"); const r=JSON.parse(fs.readFileSync(0,"utf8")); console.log(JSON.parse(r.body).text)')
  channel=$(printf '%s' "$req" | node -e 'const fs=require("fs"); const r=JSON.parse(fs.readFileSync(0,"utf8")); console.log(JSON.parse(r.body).channel)')
  assert_contains "$body" "AI agent here —" "request body missing generic required prefix"
  [ "$channel" = U123ABC ] || fail "request body did not target the configured user: $channel"
  assert_not_contains "$out" "xoxb-test-success" "success output leaked token"
  pass "fm-slack-dm posts chat.postMessage payload on success"
}

test_slack_dm_named_attribution_accepts_named_prefix() {
  local dir token_file api out status req body
  dir=$(make_slack_case named-attribution)
  token_file="$dir/token"
  printf 'xoxb-named-secret\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file" Tim
  write_dm_message "$dir" "AI agent for Tim here — update from your fleet:"$'\n'"- done: ready"
  start_fake_slack "$dir" success; api=$SLACK_API_URL

  out=$(FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  expect_code 0 "$status" "helper named-attribution success"
  req=$(tail -1 "$dir/requests.jsonl")
  body=$(printf '%s' "$req" | node -e 'const fs=require("fs"); const r=JSON.parse(fs.readFileSync(0,"utf8")); console.log(JSON.parse(r.body).text)')
  assert_contains "$body" "AI agent for Tim here —" "named config did not accept the named prefix"
  pass "fm-slack-dm derives the attribution prefix from config name"
}

test_slack_dm_named_config_rejects_generic_prefix() {
  local dir token_file out status
  dir=$(make_slack_case named-rejects-generic)
  token_file="$dir/token"
  printf 'xoxb-parity-secret\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file" Alex
  # A message carrying the generic prefix must be rejected when config names Alex,
  # proving the daemon and helper must agree on the config-derived attribution.
  write_dm_message "$dir" "AI agent here — update from your fleet:"$'\n'"- done: ready"

  out=$("$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "named config should reject a generic-prefixed message"
  assert_contains "$out" "required AI agent attribution" "attribution mismatch not classified"
  [ ! -e "$dir/requests.jsonl" ] || fail "helper called Slack despite attribution mismatch"
  assert_not_contains "$out" "xoxb-parity-secret" "attribution mismatch output leaked token"
  pass "fm-slack-dm rejects a message whose prefix disagrees with config name"
}

test_slack_dm_no_name_rejects_hardcoded_name_prefix() {
  local dir token_file out status
  dir=$(make_slack_case generic-rejects-named)
  token_file="$dir/token"
  printf 'xoxb-generic-secret\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file"
  # With no name in config the shared-default generic prefix is required; a
  # hardcoded "AI agent for Tim here —" must NOT be accepted.
  write_dm_message "$dir" "AI agent for Tim here — update from your fleet:"$'\n'"- done: ready"

  out=$("$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "generic config should reject a name-specific prefix"
  assert_contains "$out" "required AI agent attribution" "attribution mismatch not classified"
  pass "fm-slack-dm generic default does not accept a hardcoded personal name"
}

test_slack_dm_api_error_fails_without_leaking_token() {
  local dir token_file api out status
  dir=$(make_slack_case api-error)
  token_file="$dir/token"
  printf 'xoxb-api-secret\n' > "$token_file"
  write_dm_config "$dir" U123ABC "file:$token_file"
  write_dm_message "$dir"
  FAKE_SLACK_ERROR='xoxb-api-secret'
  start_fake_slack "$dir" api-error; api=$SLACK_API_URL
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
  start_fake_slack "$dir" success; api=$SLACK_API_URL

  out=$(FM_SLACK_DM_API_URL="$api" "$HELPER" --config "$dir/config/afk-slack-dm" --message-file "$dir/message.txt" 2>&1)
  status=$?

  # An absent token file must degrade gracefully as missing-token (exit 1), not
  # error out (exit 3). Assert the exact code and classification string: a plain
  # substring check for "missing-token" is a false positive here because the case
  # directory is itself named "missing-token", so an ENOENT config-error message
  # embeds that path and would match anyway.
  expect_code 1 "$status" "absent token file must degrade gracefully, not fail as a config error (got: $out)"
  assert_contains "$out" "slack-dm skipped: missing-token" "absent token file was not classified as a graceful missing-token degrade"
  assert_not_contains "$out" "config error" "absent token file was misclassified as a config error"
  [ ! -e "$dir/requests.jsonl" ] || fail "helper called Slack despite missing token"
  pass "fm-slack-dm degrades gracefully when the token file is absent"
}

test_slack_dm_rejects_channel_destination() {
  local dir token_file api out status
  dir=$(make_slack_case invalid-destination)
  token_file="$dir/token"
  printf 'xoxb-invalid-secret\n' > "$token_file"
  write_dm_config "$dir" C123CHANNEL "file:$token_file"
  write_dm_message "$dir"
  start_fake_slack "$dir" success; api=$SLACK_API_URL

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
  start_fake_slack "$dir" slow-success; api=$SLACK_API_URL

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
  start_fake_slack "$dir" success; api=$SLACK_API_URL

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

test_fake_slack_pid_recorded_in_parent_and_reaped() {
  # Regression for the fake-slack process leak. start_fake_slack must record its
  # server PID in the PARENT shell's SLACK_SERVER_PIDS and start the node as a
  # direct child of this shell. A command-substitution call site would run it in a
  # subshell, discard the PID append, and reparent the node to PID 1 (the leak the
  # cleanup trap can then never reap). Prove parent recording, direct parentage,
  # and reaping.
  local dir before after last_pid parent_pid
  dir=$(make_slack_case leak-regression)
  before=${#SLACK_SERVER_PIDS[@]}
  start_fake_slack "$dir" success
  after=${#SLACK_SERVER_PIDS[@]}
  [ -n "$SLACK_API_URL" ] || fail "start_fake_slack did not set SLACK_API_URL in the parent shell"
  [ "$after" -eq "$((before + 1))" ] || fail "server PID not recorded in parent SLACK_SERVER_PIDS (before=$before after=$after)"
  last_pid=${SLACK_SERVER_PIDS[$((after - 1))]}
  kill -0 "$last_pid" 2>/dev/null || fail "recorded fake-slack PID $last_pid is not a live process"
  parent_pid=$(ps -o ppid= -p "$last_pid" 2>/dev/null | tr -d ' ')
  [ "$parent_pid" = "$$" ] || fail "fake-slack node ppid=$parent_pid, expected this shell $$ (a command-substitution call site would reparent it to 1 and leak)"
  # Reap exactly this server the way the EXIT trap does, then prove it is gone and
  # drop it from the array so the trap does not double-wait a dead PID.
  kill "$last_pid" 2>/dev/null || true
  wait "$last_pid" 2>/dev/null || true
  kill -0 "$last_pid" 2>/dev/null && fail "fake-slack node $last_pid survived cleanup kill"
  unset "SLACK_SERVER_PIDS[$((after - 1))]"
  pass "start_fake_slack records its PID in the parent shell and is reaped by cleanup (no PID=1 leak)"
}

test_no_fake_slack_command_substitution_callsites() {
  # Static guard so the leak anti-pattern cannot silently return: no call site may
  # invoke start_fake_slack inside a command substitution. Callers use
  # `start_fake_slack "$dir" <mode>; api=$SLACK_API_URL`.
  local self hits
  self="$ROOT/tests/fm-slack-dm.test.sh"
  hits=$(grep -nE '=[[:space:]]*\$\([[:space:]]*start_fake_slack' "$self" || true)
  [ -z "$hits" ] || fail "command-substitution call site(s) of start_fake_slack (leak anti-pattern): $hits"
  pass "no start_fake_slack call site uses command substitution (leak anti-pattern absent)"
}

test_slack_dm_success_posts_chat_message
test_fake_slack_pid_recorded_in_parent_and_reaped
test_no_fake_slack_command_substitution_callsites
test_slack_dm_named_attribution_accepts_named_prefix
test_slack_dm_named_config_rejects_generic_prefix
test_slack_dm_no_name_rejects_hardcoded_name_prefix
test_slack_dm_api_error_fails_without_leaking_token
test_slack_dm_network_error_fails
test_slack_dm_missing_token_degrades_without_request
test_slack_dm_rejects_channel_destination
test_slack_dm_requires_message_prefix
test_slack_dm_token_not_in_process_args
test_slack_dm_command_token_not_in_process_args
