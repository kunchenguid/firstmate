#!/usr/bin/env bash
# Regression tests for self-hosted Discord connector (poll, reply, bootstrap opt-in, collision filter).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
NODE_DIR=$(command -v node 2>/dev/null) && NODE_DIR=$(dirname "$NODE_DIR") || NODE_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
[ -n "$NODE_DIR" ] && BASE_PATH="$NODE_DIR:$BASE_PATH"

TMP_ROOT=$(fm_test_tmproot fm-discord-selfhosted-tests)

test_poll_no_token_is_hard_noop() {
  local home out rc
  home="$TMP_ROOT/poll-noop"; mkdir -p "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_DISCORD_BOT_TOKEN='' FM_STATE_OVERRIDE='' \
    "$ROOT/bin/fm-discord-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-token exit"
  [ -z "$out" ] || fail "poll no-token must be silent (got: $out)"
  assert_absent "$home/state/x-inbox" "poll no-token must not create an inbox"
  pass "fm-discord-poll is a hard no-op without a token"
}

test_ingestion_payload_shape_and_wake() {
  local home inbox_file ctx_file wake_out wake_next wake_third platform source port server_pid cursor_file dm_cursor_file
  home="$TMP_ROOT/ingestion-test"
  mkdir -p "$home/state"
  chmod 700 "$home/state"

  node -e '
    const http = require("node:http");
    const messages = {
      "1000000000000000001": [
        { id: "1352000000000000102", channel_id: "1000000000000000001", guild_id: "1000000000000000000", author: { username: "captain" }, content: "<@999> second request", mentions: [{ id: "999" }] },
        { id: "1352000000000000099", channel_id: "1000000000000000001", guild_id: "1000000000000000000", author: { username: "captain" }, content: "<@999> add login fix to backlog", mentions: [{ id: "999" }] }
      ],
      "2000000000000000001": [{ id: "1352000000000000100", channel_id: "2000000000000000001", author: { username: "captain" }, content: "<@999> private request", mentions: [{ id: "999" }] }],
      "1551134713727426570": [{ id: "1352000000000000101", channel_id: "1551134713727426570", guild_id: "1000000000000000000", author: { username: "captain" }, content: "<@999> collision request", mentions: [{ id: "999" }] }]
    };
    http.createServer((req, res) => {
      let body = { id: "999" };
      const match = req.url.match(/^\/channels\/([^/]+)\/messages/);
      if (match) {
        body = messages[match[1]] || [];
        const after = new URL(req.url, "http://localhost").searchParams.get("after");
        if (after) body = body.filter((message) => BigInt(message.id) > BigInt(after));
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    }).listen(0, "127.0.0.1", function () { console.log(this.address().port); });
  ' > "$home/server.port" 2>"$home/server.err" &
  server_pid=$!
  while [ ! -s "$home/server.port" ]; do sleep 0.01; done
  port=$(head -n 1 "$home/server.port")

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN="fake-test-token" \
  FM_DISCORD_ALLOWED_CHANNELS="1000000000000000001,2000000000000000001,1551134713727426570" \
  FM_DISCORD_EXCLUDES="1551134713727426570" FM_DISCORD_ALLOW_DMS=false \
  FM_DISCORD_API_BASE="http://127.0.0.1:$port" "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log"
  wake_out=$(cat "$home/wake.log")
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN="fake-test-token" \
  FM_DISCORD_ALLOWED_CHANNELS="1000000000000000001,2000000000000000001,1551134713727426570" \
  FM_DISCORD_EXCLUDES="1551134713727426570" FM_DISCORD_ALLOW_DMS=false \
  FM_DISCORD_API_BASE="http://127.0.0.1:$port" "$ROOT/bin/fm-discord-poll.sh" > "$home/wake-next.log"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN="fake-test-token" \
  FM_DISCORD_ALLOWED_CHANNELS="1000000000000000001,2000000000000000001,1551134713727426570" \
  FM_DISCORD_EXCLUDES="1551134713727426570" FM_DISCORD_ALLOW_DMS=false \
  FM_DISCORD_API_BASE="http://127.0.0.1:$port" "$ROOT/bin/fm-discord-poll.sh" > "$home/wake-third.log"
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  assert_equals "x-mention discord-sh-1352000000000000099" "$wake_out" "wake line emitted"
  wake_next=$(cat "$home/wake-next.log")
  assert_equals "x-mention discord-sh-1352000000000000102" "$wake_next" "one wake per poll"
  wake_third=$(cat "$home/wake-third.log")
  assert_equals "" "$wake_third" "disabled DM produces no wake"

  inbox_file="$home/state/x-inbox/discord-sh-1352000000000000099.json"
  ctx_file="$home/state/x-context/discord-sh-1352000000000000099.json"
  assert_present "$inbox_file" "inbox payload exists"
  assert_present "$ctx_file" "context record exists"

  platform=$(jq -r '.platform' "$inbox_file")
  source=$(jq -r '.source' "$inbox_file")
  assert_equals "discord" "$platform" "inbox platform"
  assert_equals "discord-selfhosted" "$source" "inbox source"
  assert_absent "$home/state/x-inbox/discord-sh-1352000000000000100.json" "DM is ignored when disabled"
  assert_absent "$home/state/x-inbox/discord-sh-1352000000000000101.json" "excluded collision channel is ignored"
  cursor_file="$home/state/x-discord/1000000000000000001.json"
  assert_equals "1352000000000000102" "$(jq -r '.message_id' "$cursor_file")" "channel cursor advances durably"
  dm_cursor_file="$home/state/x-discord/2000000000000000001.json"
  assert_equals "1352000000000000100" "$(jq -r '.message_id' "$dm_cursor_file")" "disabled DM advances cursor"

  pass "self-hosted Discord ingestion writes x-inbox payload shape and fires x-mention wake"
}

test_reply_dry_run_routing() {
  local home req_id outbox_file out rc platform source
  home="$TMP_ROOT/reply-test"
  mkdir -p "$home/state/x-inbox" "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-inbox" "$home/state/x-context"
  req_id="discord-sh-1352000000000000099"
  printf 'FMX_DRY_RUN=1\n' > "$home/.env"

  printf '{"request_id":"%s","platform":"discord","source":"discord-selfhosted","channel_id":"1000000000000000001","message_id":"1352000000000000099"}' "$req_id" \
    > "$home/state/x-context/$req_id.json"
  chmod 600 "$home/state/x-context/$req_id.json"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN="fake-token" \
    "$ROOT/bin/fm-x-reply.sh" "$req_id" "aye captain, work is underway"); rc=$?

  expect_code 0 "$rc" "reply exit code"
  assert_equals "$req_id" "$out" "reply outputs request_id"

  outbox_file="$home/state/x-outbox/$req_id.json"
  assert_present "$outbox_file" "dry run outbox record written"

  platform=$(jq -r '.platform' "$outbox_file")
  source=$(jq -r '.source' "$outbox_file")
  assert_equals "discord" "$platform" "outbox platform"
  assert_equals "discord-selfhosted" "$source" "outbox source"

  pass "fm-x-reply routes self-hosted Discord requests to self-hosted reply adapter"
}

test_reply_rejects_untrusted_context_link() {
  local home req_id target payload_file out reply_stderr
  home="$TMP_ROOT/reply-identity-test"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  req_id="discord-sh-1352000000000000110"
  target="$home/untrusted.json"
  payload_file="$home/payload.json"
  reply_stderr="$home/reply.err"
  printf '{"channel_id":"private-channel","message_id":"private-message"}' > "$target"
  ln -s "$target" "$home/state/x-context/$req_id.json"
  printf '{"request_id":"%s","text":"preview"}' "$req_id" > "$payload_file"
  printf 'FMX_DRY_RUN=1\n' > "$home/.env"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-discord-reply.js" "$req_id" "$payload_file" 2>"$reply_stderr")
  assert_equals "$req_id" "$out" "untrusted context still completes dry run"
  assert_present "$home/state/x-outbox/$req_id.json" "dry run outbox exists"
  grep -q 'dry-run-channel' "$reply_stderr" || fail "untrusted context must not supply channel identity"

  pass "self-hosted reply rejects symlinked context identity"
}

test_bootstrap_activation() {
  local home out shim cadence failed_home failed_target failed_out
  home="$TMP_ROOT/bootstrap-test"
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state" "$home/config"

  # 1. No token -> silent
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DISCORD_BOT_TOKEN='' \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_absent "$home/state/discord-watch.check.sh" "no token -> no shim"

  # 2. Token present -> writes shim and cadence
  printf 'FM_DISCORD_BOT_TOKEN=fake-token\n' > "$home/.env"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-bootstrap.sh")
  shim="$home/state/discord-watch.check.sh"
  cadence="$home/config/discord-mode.env"
  assert_present "$shim" "token -> shim written"
  assert_present "$cadence" "token -> cadence written"

  failed_home="$TMP_ROOT/bootstrap-failure-test"
  mkdir -p "$failed_home/state" "$failed_home/config"
  chmod 700 "$failed_home/state" "$failed_home/config"
  printf 'FM_DISCORD_BOT_TOKEN=fake-token\n' > "$failed_home/.env"
  failed_target="$failed_home/cadence-target"
  printf 'sentinel\n' > "$failed_target"
  ln -s "$failed_target" "$failed_home/config/discord-mode.env"
  failed_out=$(PATH="$BASE_PATH" FM_HOME="$failed_home" FM_STATE_OVERRIDE="$failed_home/state" FM_CONFIG_OVERRIDE="$failed_home/config" \
    "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$failed_out" | grep -q 'FM_DISCORD: self-hosted Discord mode inactive - failed to publish cadence' \
    || fail "bootstrap must report inactive when cadence publication fails"

  pass "fm-bootstrap handles FM_DISCORD_BOT_TOKEN activation and artifact generation"
}

test_poll_no_token_is_hard_noop
test_ingestion_payload_shape_and_wake
test_reply_dry_run_routing
test_reply_rejects_untrusted_context_link
test_bootstrap_activation
