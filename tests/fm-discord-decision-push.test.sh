#!/usr/bin/env bash
# Regression tests for proactive Discord decisions and their reply inbox route.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
NODE_DIR=$(command -v node 2>/dev/null) && NODE_DIR=$(dirname "$NODE_DIR") || NODE_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
[ -n "$NODE_DIR" ] && BASE_PATH="$NODE_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-discord-decision-push)
make_fake_node() {
  local home=$1
  mkdir -p "$home/fake-bin"
  cat > "$home/fake-bin/node" <<'SH'
#!/usr/bin/env bash
set -u
script=$1
shift
exec "$FM_TEST_REAL_NODE" --input-type=module -e '
  import { pathToFileURL } from "node:url";
  const [script, ...args] = process.argv.slice(1);
  process.argv = [process.argv[0], script, ...args];
  const messages = JSON.parse(process.env.FM_DISCORD_FAKE_MESSAGES || "[]");
  const log = process.env.FM_DISCORD_FAKE_POST_LOG;
  globalThis.fetch = async (url, options = {}) => {
    if (url === "https://discord.com/api/v10/users/@me") {
      if (process.env.FM_DISCORD_FAKE_PROFILE_STATUS) return new Response("failed", { status: Number(process.env.FM_DISCORD_FAKE_PROFILE_STATUS) });
      return Response.json({ id: "9000000000000000001" });
    }
    if (url.includes("/messages") && options.method === "POST") {
      const payload = JSON.parse(options.body);
      if (log) await import("node:fs/promises").then(({ appendFile }) => appendFile(log, JSON.stringify({ url, payload }) + "\n"));
      if (process.env.FM_DISCORD_FAKE_POST_STATUS) return new Response("failed", { status: Number(process.env.FM_DISCORD_FAKE_POST_STATUS) });
      return Response.json({ id: "1352000000000000999", channel_id: "1000000000000000001" });
    }
    if (url.includes("/channels/") && url.includes("/messages")) return Response.json(messages);
    return new Response("not found", { status: 404 });
  };
  await import(pathToFileURL(script).href);
' "$script" "$@"
SH
  chmod +x "$home/fake-bin/node"
}
test_no_token_is_inert() {
  local home out rc
  home="$TMP_ROOT/no-token"
  mkdir -p "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_DISCORD_BOT_TOKEN='' \
    "$ROOT/bin/fm-discord-notify.sh" captain-hold task-a captain-hold-task-a-1 "Needs a decision" "Continue|Pause")
  rc=$?
  expect_code 0 "$rc" "missing token is inert"
  [ -z "$out" ] || fail "missing token printed output: $out"
  assert_absent "$home/state/x-context" "missing token creates no notification record"
  pass "proactive Discord notification is inert without the self-hosted token"
}
test_notify_records_reply_binding() {
  local home log record body
  home="$TMP_ROOT/notify"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" captain-hold task-a captain-hold-task-a-1 \
      "Choose how to proceed" "Continue|Pause" >/dev/null \
    || fail "notification post failed"
  record=$(find "$home/state/x-context" -maxdepth 1 -name 'discord-notify-*.json' -print -quit)
  assert_present "$record" "notification binding is persisted"
  assert_equals "task-a" "$(jq -r '.task_id' "$record")" "notification task id"
  assert_equals "captain-hold-task-a-1" "$(jq -r '.key' "$record")" "notification decision key"
  assert_equals "1352000000000000999" "$(jq -r '.message_id' "$record")" "Discord message id"
  assert_equals "true" "$(jq -r '.payload.enforce_nonce' "$log")" "Discord send enforces the event nonce"
  body=$(jq -r '.payload.content' "$log")
  assert_contains "$body" "task-a" "message includes task id"
  assert_contains "$body" "Choose how to proceed" "message includes summary"
  assert_contains "$body" "Continue" "message includes options"
  assert_contains "$body" "Pause" "message includes all options"
  pass "proactive Discord post stores the task and reply binding"
}

test_failed_notification_retries_from_durable_outbox() {
  local home record log state
  home="$TMP_ROOT/retry-failed"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  if FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" FM_DISCORD_FAKE_POST_STATUS=503 \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" ask-user task-retry nm-run42-review \
      "A decision is needed" "Approve|Decline" >/dev/null 2>&1; then
    fail "a rejected Discord send reported success"
  fi
  record=$(find "$home/state/x-context" -maxdepth 1 -name 'discord-notify-*.json' -print -quit)
  assert_equals "failed" "$(jq -r '.state' "$record")" "failed send remains pending"
  jq '.summary = "A proposed change needs your decision." | .options = ["Approve the proposed change", "Keep the current behavior"]' \
    "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" FM_DISCORD_FAKE_MESSAGES='[]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" --retry-pending >/dev/null \
    || fail "durable notification retry failed"
  state=$(jq -r '.state' "$record")
  assert_equals "sent" "$state" "retry completes the retained notification"
  assert_equals "2" "$(wc -l < "$log" | tr -d ' ')" "one initial failed POST and one retry POST"
  assert_contains "$(sed -n '2p' "$log" | jq -r '.payload.content')" "제안된 변경 사항 승인 / 현재 동작 유지" "legacy retry options are localized"
  assert_contains "$(sed -n '2p' "$log" | jq -r '.payload.content')" "제안된 변경 사항에 대한 결정이 필요합니다." "legacy retry summary is localized"
  pass "failed decision notifications retry after their source cursor advances"
}

test_profile_failure_keeps_retryable_intent() {
  local home record log
  home="$TMP_ROOT/profile-failure"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  if FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_PROFILE_STATUS=503 \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" ask-user task-profile nm-run43-review \
      "A decision is needed" "Approve|Decline" >/dev/null 2>&1; then
    fail "a rejected profile lookup reported success"
  fi
  record=$(find "$home/state/x-context" -maxdepth 1 -name 'discord-notify-*.json' -print -quit)
  assert_present "$record" "profile failure leaves a durable notification intent"
  assert_equals "pending" "$(jq -r '.state' "$record")" "profile failure leaves intent retryable"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" FM_DISCORD_FAKE_MESSAGES='[]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" --retry-pending >/dev/null \
    || fail "profile-failed notification was not retried"
  assert_equals "sent" "$(jq -r '.state' "$record")" "profile-failed intent reaches sent state"
  assert_equals "1" "$(wc -l < "$log" | tr -d ' ')" "retry posts exactly once"
  pass "profile lookup failure preserves and retries the notification intent"
}

test_stale_sending_notification_recovers_without_duplicate_post() {
  local home record nonce
  home="$TMP_ROOT/retry-stale-sending"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-stale.json"
  nonce=0123456789abcdef012345678
  cat > "$record" <<EOF
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sending","task_id":"task-stale","key":"nm-stale-review","trigger":"ask-user","channel_id":"1000000000000000001","nonce":"$nonce","summary":"Review needed","options":["Approve","Decline"],"recorded_at":1700000000,"attempted_at":1700000000}
EOF
  chmod 600 "$record"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_MESSAGES="[{\"id\":\"1352000000000001200\",\"channel_id\":\"1000000000000000001\",\"author\":{\"id\":\"9000000000000000001\"},\"nonce\":\"$nonce\",\"timestamp\":\"2026-09-25T00:00:00.000Z\"}]" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" --retry-pending >/dev/null \
    || fail "stale sending notification did not reconcile from channel history"
  assert_equals "sent" "$(jq -r '.state' "$record")" "stale notification is marked sent"
  assert_equals "1352000000000001200" "$(jq -r '.message_id' "$record")" "existing message receipt is adopted"
  assert_absent "$home/posts.jsonl" "history reconciliation does not post a duplicate"
  pass "stale sending records recover from Discord history without reposting"
}

test_captain_hold_triggers_push() {
  local home record
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "captain-hold trigger integration skipped because tasks-axi is unavailable"
    return 0
  fi
  home="$TMP_ROOT/captain-hold-trigger"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  make_fake_node "$home"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH:$(dirname "$(command -v tasks-axi)")" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-captain-hold.sh" hold task-hold \
      --title "Choose the next step" --reason "Choose how the change should proceed" \
      >/dev/null || fail "captain hold failed"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_equals "captain-hold" "$(jq -r '.trigger' "$record")" "captain-hold trigger type"
  assert_equals "task-hold" "$(jq -r '.task_id' "$record")" "captain-hold task id"
  assert_equals "Choose how the change should proceed" "$(jq -r '.summary' "$record")" \
    "hold summary carries the caller's actual reason, not generic filler"
  pass "a durable captain hold triggers a Discord decision push with the real reason text"
}

test_captain_hold_truncates_long_reason_for_discord() {
  local home record long_reason summary
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "captain-hold Discord truncation skipped because tasks-axi is unavailable"
    return 0
  fi
  home="$TMP_ROOT/captain-hold-long-reason"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  make_fake_node "$home"
  long_reason=$(printf 'word %.0s' $(seq 1 500))
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH:$(dirname "$(command -v tasks-axi)")" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-captain-hold.sh" hold task-hold-long \
      --title "Choose the next step" --reason "$long_reason" \
      >/dev/null || fail "captain hold with a long reason failed"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  summary=$(jq -r '.summary' "$record")
  [ "${#summary}" -le 1801 ] || fail "Discord summary was not truncated: ${#summary} chars"
  [ "${#summary}" -lt "${#long_reason}" ] || fail "Discord summary was not shortened from the full reason"
  pass "a captain hold with a reason near Discord's message limit gets truncated before sending"
}

test_ask_user_escalation_hold_carries_finding_text() {
  local home record reason
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "ask-user escalation content integration skipped because tasks-axi is unavailable"
    return 0
  fi
  home="$TMP_ROOT/ask-user-escalation-hold"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  make_fake_node "$home"
  reason="allow the migration to drop the legacy column now, or keep it for one more release"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH:$(dirname "$(command -v tasks-axi)")" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-captain-hold.sh" hold nm-task \
      --title "ask-user gate" --reason "$reason" \
      >/dev/null || fail "captain hold for an escalated ask-user gate failed"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_equals "$reason" "$(jq -r '.summary' "$record")" \
    "escalated ask-user gate's Discord push carries the real finding text"
  pass "a genuinely escalated ask-user gate pushes a Discord decision with the real finding text"
}
test_reply_to_notification_enters_existing_inbox() {
  local home record wake req inbox
  home="$TMP_ROOT/reply"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  chmod 600 "$record"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001000","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  wake=$(cat "$home/wake.log")
  req=discord-sh-1352000000000001000
  assert_equals "x-mention $req" "$wake" "reply wakes existing responder"
  inbox="$home/state/x-inbox/$req.json"
  assert_present "$inbox" "reply is captured in existing inbox"
  assert_equals "discord-selfhosted-decision" "$(jq -r '.source' "$inbox")" "decision reply source"
  assert_equals "task-a" "$(jq -r '.decision.task_id' "$inbox")" "decision task id routed"
  assert_equals "captain-hold-task-a-1" "$(jq -r '.decision.key' "$inbox")" "decision key routed"
  assert_equals "Continue" "$(jq -r '.text' "$inbox")" "captain reply preserved"
  assert_equals "1352000000000001000" "$(jq -r '.replied_to.message_id' "$record")" "notification accepts only one reply"
  pass "reply to a pushed decision enters x-inbox with keyed answer context"
}
test_captured_reply_without_offer_recovers_one_wake() {
  local home record req inbox offered wake
  home="$TMP_ROOT/recover-reply-wake"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  req=discord-sh-1352000000000001001
  inbox="$home/state/x-inbox/$req.json"
  jq -n --arg req "$req" --arg msg "1352000000000001001" \
    '{request_id:$req,text:"Continue",source:"discord-selfhosted-decision",message_id:$msg,channel_id:"1000000000000000001",decision:{task_id:"task-a",key:"captain-hold-task-a-1"}}' \
    > "$inbox"
  chmod 600 "$record" "$inbox"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001001","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "recovery poll failed"
  wake=$(cat "$home/wake.log")
  assert_equals "x-mention $req" "$wake" "captured reply is woken after replay"
  offered="$home/state/x-context/$req.offered.json"
  assert_present "$offered" "recovery records the one-wake marker"
  assert_present "$home/state/x-context/$req.json" "recovery restores reply context"
  assert_equals "1352000000000001001" "$(jq -r '.replied_to.message_id' "$record")" "recovery completes notification binding"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001001","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/replay.log" || fail "second recovery poll failed"
  assert_equals "" "$(cat "$home/replay.log")" "an offered reply is not woken twice"
  pass "a captured decision reply recovers its missing wake once"
}
test_unauthorized_decision_reply_is_ignored() {
  local home record wake
  home="$TMP_ROOT/unauthorized-reply"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  chmod 600 "$record"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001002","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000002","username":"member"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  wake=$(cat "$home/wake.log")
  [ -z "$wake" ] || fail "unauthorized reply woke responder: $wake"
  assert_absent "$home/state/x-inbox/discord-sh-1352000000000001002.json" "unauthorized decision reply is not captured"
  assert_equals "null" "$(jq -r '.replied_to // "null"' "$record")" "unauthorized reply does not mark the notification answered"
  pass "Discord decision replies require an authorized user ID"
}
test_no_unrelated_reply_is_captured() {
  local home wake
  home="$TMP_ROOT/unrelated"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001100","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"ordinary chat","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  wake=$(cat "$home/wake.log")
  [ -z "$wake" ] || fail "unbound reply woke responder: $wake"
  assert_absent "$home/state/x-inbox/discord-sh-1352000000000001100.json" "unrelated reply is not captured"
  pass "ordinary Discord replies do not enter the decision inbox"
}

test_ask_user_gate_alone_triggers_no_push() {
  local home posts
  home="$TMP_ROOT/ask-user-decided-in-scope"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  posts="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'needs-decision [key=nm-run42-review]: ask-user findings=f1 file=/private/findings.txt' \
    >/dev/null || fail "ask-user status classification failed"
  [ ! -s "$posts" ] || fail "a raw ask-user gate alone sent a Discord notification"
  [ -z "$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)" ] \
    || fail "a raw ask-user gate created a notification record"
  pass "a raw ask-user gate never pushes on its own - firstmate may still decide it in-scope"
}

test_pr_push_requires_yolo_off() {
  local home record posts
  home="$TMP_ROOT/pr-trigger"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  posts="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'needs-decision [key=pr-ready-task-a]: task=task-a pull request ready yolo=on' >/dev/null \
    || fail "yolo-on PR status classification failed"
  [ ! -s "$posts" ] || fail "yolo-on PR status sent a notification"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
    'needs-decision [key=pr-ready-task-a]: task=task-a yolo=off pull request ready: https://github.com/acme/app/pull/42 choose merge or leave open' >/dev/null \
    || fail "yolo-off PR status did not trigger a push"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_equals "pr-ready" "$(jq -r '.trigger' "$record")" "PR-ready trigger type"
  assert_equals "task-a" "$(jq -r '.task_id' "$record")" "PR-ready task id"
  assert_contains "$(jq -r '.summary' "$record")" "https://github.com/acme/app/pull/42" "PR summary includes review link"
  assert_contains "$(jq -r '.summary' "$record")" "app" "PR summary names the repo extracted from the PR URL"
  assert_equals "1" "$(wc -l < "$posts" | tr -d '[:space:]')" "one yolo-off notification sent"
  pass "PR-ready notifications require yolo=off"
}

test_pr_push_names_gitlab_project() {
  local home record
  home="$TMP_ROOT/pr-trigger-gitlab"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
    'needs-decision [key=pr-ready-task-a]: task=task-a yolo=off pull request ready: https://gitlab.example.com/some-group/widgets-service/-/merge_requests/7 choose merge or leave open' >/dev/null \
    || fail "yolo-off GitLab MR status did not trigger a push"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_contains "$(jq -r '.summary' "$record")" "widgets-service" \
    "PR summary names the project extracted from the GitLab MR URL, independent of the URL substring"
  pass "PR-ready notifications name the project for an accepted GitLab merge-request URL too"
}

test_no_token_is_inert
test_notify_records_reply_binding
test_failed_notification_retries_from_durable_outbox
test_profile_failure_keeps_retryable_intent
test_stale_sending_notification_recovers_without_duplicate_post
test_captain_hold_triggers_push
test_captain_hold_truncates_long_reason_for_discord
test_reply_to_notification_enters_existing_inbox
test_captured_reply_without_offer_recovers_one_wake
test_unauthorized_decision_reply_is_ignored
test_no_unrelated_reply_is_captured
test_ask_user_gate_alone_triggers_no_push
test_ask_user_escalation_hold_carries_finding_text
test_pr_push_requires_yolo_off
test_pr_push_names_gitlab_project
