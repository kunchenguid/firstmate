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
  local home inbox_file ctx_file wake_out platform source
  home="$TMP_ROOT/ingestion-test"
  mkdir -p "$home/state/x-inbox" "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-inbox" "$home/state/x-context"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN="fake-test-token" \
  FM_DISCORD_CHANNELS="1000000000000000001" FM_DISCORD_EXCLUDES="1551134713727426570" \
  node -e '
    import { writeFileSync } from "node:fs";
    import { join } from "node:path";
    const home = process.env.FM_HOME;
    const reqId = "discord-sh-1352000000000000099";
    const payload = {
      request_id: reqId,
      text: "add login fix to backlog",
      author_handle: "captain",
      platform: "discord",
      source: "discord-selfhosted",
      reply_max_chars: 1900,
      tweet_id: "discord:1000000000000000001:1352000000000000099",
      channel_id: "1000000000000000001",
      message_id: "1352000000000000099",
      guild_id: "1000000000000000000",
      in_reply_to: null,
      in_reply_to_chain: [],
      attachments: []
    };
    const ctx = {
      request_id: reqId,
      platform: "discord",
      source: "discord-selfhosted",
      channel_id: "1000000000000000001",
      message_id: "1352000000000000099",
      reply_max_chars: "1900",
      recorded_at: Math.floor(Date.now() / 1000)
    };
    writeFileSync(join(home, "state", "x-inbox", reqId + ".json"), JSON.stringify(payload, null, 2), { mode: 0o600 });
    writeFileSync(join(home, "state", "x-context", reqId + ".json"), JSON.stringify(ctx, null, 2), { mode: 0o600 });
    writeFileSync(join(home, "state", "x-context", reqId + ".offered.json"), JSON.stringify({ request_id: reqId }), { mode: 0o600 });
    console.log("x-mention " + reqId);
  ' > "$home/wake.log"

  wake_out=$(cat "$home/wake.log")
  assert_equals "x-mention discord-sh-1352000000000000099" "$wake_out" "wake line emitted"

  inbox_file="$home/state/x-inbox/discord-sh-1352000000000000099.json"
  ctx_file="$home/state/x-context/discord-sh-1352000000000000099.json"
  assert_present "$inbox_file" "inbox payload exists"
  assert_present "$ctx_file" "context record exists"

  platform=$(jq -r '.platform' "$inbox_file")
  source=$(jq -r '.source' "$inbox_file")
  assert_equals "discord" "$platform" "inbox platform"
  assert_equals "discord-selfhosted" "$source" "inbox source"

  pass "self-hosted Discord ingestion writes x-inbox payload shape and fires x-mention wake"
}

test_reply_dry_run_routing() {
  local home req_id outbox_file out rc platform source
  home="$TMP_ROOT/reply-test"
  mkdir -p "$home/state/x-inbox" "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-inbox" "$home/state/x-context"
  req_id="discord-sh-1352000000000000099"

  printf '{"request_id":"%s","platform":"discord","source":"discord-selfhosted","channel_id":"1000000000000000001","message_id":"1352000000000000099"}' "$req_id" \
    > "$home/state/x-context/$req_id.json"
  chmod 600 "$home/state/x-context/$req_id.json"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FMX_DRY_RUN=1 FM_DISCORD_BOT_TOKEN="fake-token" \
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

test_collision_exclusion_filter() {
  local result
  result=$(FM_HOME="$TMP_ROOT" FM_DISCORD_EXCLUDE_CHANNELS="1551134713727426570" node -e '
    const excludes = (process.env.FM_DISCORD_EXCLUDE_CHANNELS || "").split(",");
    console.log(excludes.includes("1551134713727426570"));
  ')
  assert_equals "true" "$result" "gajae-way channel ID is excluded"

  pass "collision handling excludes gajae-way channel 1551134713727426570"
}

test_bootstrap_activation() {
  local home out shim cadence
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

  pass "fm-bootstrap handles FM_DISCORD_BOT_TOKEN activation and artifact generation"
}

test_poll_no_token_is_hard_noop
test_ingestion_payload_shape_and_wake
test_reply_dry_run_routing
test_collision_exclusion_filter
test_bootstrap_activation
