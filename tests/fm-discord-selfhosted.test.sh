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

make_fake_discord_node() {
  local home=$1
  mkdir -p "$home/fake-bin"
  cat > "$home/fake-bin/node" <<'SH'
#!/usr/bin/env bash
set -u
exec "$FM_TEST_REAL_NODE" --input-type=module -e '
  import { pathToFileURL } from "node:url";
  const script = process.argv[1];
  const messages = JSON.parse(process.env.FM_DISCORD_FAKE_MESSAGES || "[]");
  const channels = JSON.parse(process.env.FM_DISCORD_FAKE_CHANNELS || "[]");
  const log = process.env.FM_DISCORD_FAKE_FETCH_LOG;
  globalThis.fetch = async (url) => {
    if (log) {
      const channel = url.match(/\/channels\/([^/]+)\/messages/);
      if (channel) {
        await import("node:fs/promises").then(({ appendFile }) => appendFile(log, channel[1] + "\\n"));
      }
    }
    if (url === "https://discord.com/api/v10/users/@me") return Response.json({ id: "9000000000000000001" });
    if (url === "https://discord.com/api/v10/users/@me/channels") return Response.json(channels);
    if (url.includes("/channels/")) return Response.json(messages);
    return new Response("not found", { status: 404 });
  };
  await import(pathToFileURL(script).href);
' "$1"
SH
  chmod +x "$home/fake-bin/node"
}

test_ingestion_payload_shape_and_wake() {
  local home inbox_file ctx_file wake_out platform source cursor
  home="$TMP_ROOT/ingestion-test"
  mkdir -p "$home/state/x-inbox" "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-inbox" "$home/state/x-context"
  make_fake_discord_node "$home"

  FM_TEST_REAL_NODE=$(command -v node) \
  FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000000099","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"username":"captain"},"mentions":[{"id":"9000000000000000001"}],"content":"<@9000000000000000001> add login fix to backlog","attachments":[]}]' \
  PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN="fake-test-token" \
  FM_DISCORD_CHANNEL_ID="1000000000000000001" FM_DISCORD_EXCLUDE_CHANNELS="1551134713727426570" \
  "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log"

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

  cursor="$home/state/x-context/discord-cursor-1000000000000000001.json"
  assert_present "$cursor" "poll cursor exists after ingestion"
  assert_equals "1352000000000000099" "$(jq -r '.last_id' "$cursor")" "poll cursor advances after ingestion"

  pass "self-hosted Discord ingestion writes x-inbox payload shape and fires x-mention wake"
}

test_default_dm_discovery() {
  local home wake_out
  home="$TMP_ROOT/default-dm-test"
  mkdir -p "$home/state"
  make_fake_discord_node "$home"
  wake_out=$(FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_CHANNELS='[{"id":"1000000000000000003","type":1}]' \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000000101","channel_id":"1000000000000000003","author":{"username":"captain"},"content":"hello from DM","attachments":[]}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN="fake-test-token" \
    "$ROOT/bin/fm-discord-poll.sh")
  assert_equals "x-mention discord-sh-1352000000000000101" "$wake_out" "default DM wake emitted"
  assert_present "$home/state/x-inbox/discord-sh-1352000000000000101.json" "default DM inbox exists"
  pass "self-hosted Discord default polling discovers permitted DMs"
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
  local home wake_out
  home="$TMP_ROOT/exclusion-test"
  mkdir -p "$home/state"
  make_fake_discord_node "$home"
  wake_out=$(FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000000100","channel_id":"1000000000000000002","guild_id":"1000000000000000000","author":{"username":"captain"},"mentions":[{"id":"9000000000000000001"}],"content":"<@9000000000000000001> allowed","attachments":[]}]' \
    FM_DISCORD_FAKE_FETCH_LOG="$home/fetch.log" PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN="fake-test-token" FM_DISCORD_CHANNEL_ID="1551134713727426570,1000000000000000002" \
    FM_DISCORD_EXCLUDE_CHANNELS="1551134713727426570" "$ROOT/bin/fm-discord-poll.sh" 2>"$home/warnings.log")
  assert_equals "x-mention discord-sh-1352000000000000100" "$wake_out" "allowed channel wake emitted"
  ! grep -Fxq "1551134713727426570" "$home/fetch.log" || fail "excluded channel was fetched"
  assert_present "$home/state/x-inbox/discord-sh-1352000000000000100.json" "allowed channel inbox exists"
  assert_contains "$(cat "$home/warnings.log")" "channel 1551134713727426570 is allowlisted and explicitly excluded; exclusion wins" "explicit exclusion conflict is reported"

  pass "collision handling excludes gajae-way channel 1551134713727426570"
}

test_allowlist_overrides_default_exclusion() {
  local home wake_out
  home="$TMP_ROOT/default-exclusion-override"
  mkdir -p "$home/state"
  make_fake_discord_node "$home"
  wake_out=$(FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000000103","channel_id":"1551134713727426570","guild_id":"1000000000000000000","author":{"username":"captain"},"mentions":[{"id":"9000000000000000001"}],"content":"<@9000000000000000001> hello","attachments":[]}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1551134713727426570 \
    FM_DISCORD_EXCLUDE_CHANNELS='' "$ROOT/bin/fm-discord-poll.sh" 2>"$home/warnings.log") \
    || fail "poll with explicit channel allowlist failed"
  assert_equals "x-mention discord-sh-1352000000000000103" "$wake_out" "explicit allowlist defeats only the built-in exclusion"
  assert_contains "$(cat "$home/warnings.log")" "allowlisted Discord channel 1551134713727426570 overrides the built-in exclusion" "default exclusion collision is reported"
  assert_present "$home/state/x-inbox/discord-sh-1352000000000000103.json" "allowlisted channel mention reaches inbox"
  pass "explicit allowlist takes precedence over the default Discord collision exclusion with a warning"
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
test_default_dm_discovery
test_reply_dry_run_routing
test_collision_exclusion_filter
test_allowlist_overrides_default_exclusion
test_bootstrap_activation
