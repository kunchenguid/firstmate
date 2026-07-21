#!/usr/bin/env bash
# Deterministic end-to-end tests for the private AI Department portal connector.
# Every home is isolated, and all HTTP reaches only tests/fixtures/fake-portal.py
# on an ephemeral loopback port. The live portal and live credential are never read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-portal-connector-tests)
SERVER_DIR="$TMP_ROOT/server"
mkdir -p "$SERVER_DIR"
TOKEN_FILE="$SERVER_DIR/token"
PORT_FILE="$SERVER_DIR/port"
printf 'fixture-token-that-is-never-logged\n' > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
python3 "$ROOT/tests/fixtures/fake-portal.py" "$TOKEN_FILE" "$PORT_FILE" >/dev/null 2>&1 &
SERVER_PID=$!
cleanup_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup || true
  rm -rf "$TMP_ROOT"
}
trap cleanup_server EXIT
for _i in $(seq 1 200); do
  [ -s "$PORT_FILE" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || fail "fake portal exited before publishing its port"
  sleep 0.02
done
[ -s "$PORT_FILE" ] || fail "fake portal did not publish its port"
PORT=$(cat "$PORT_FILE")
BASE_URL="http://127.0.0.1:$PORT"

path_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

server_reset() {
  curl -fsS -X POST -H 'content-type: application/json' --data-binary '{}' "$BASE_URL/_test/reset" >/dev/null
}

server_control() {
  local file=$1
  curl -fsS -X POST -H 'content-type: application/json' --data-binary "@$file" "$BASE_URL/_test/control" >/dev/null
}

server_message() {
  local body_file=$1 payload="$TMP_ROOT/admin-message.json"
  jq -cn --rawfile body "$body_file" '{body:$body}' > "$payload"
  curl -fsS -X POST -H 'content-type: application/json' --data-binary "@$payload" "$BASE_URL/_test/message" | jq -r '.id'
}

server_stats() {
  curl -fsS "$BASE_URL/_test/stats"
}

install_home() {
  local home=$1
  mkdir -p "$home"
  FM_HOME="$home" "$ROOT/bin/fm-portal-config.sh" install --token-stdin --base-url "$BASE_URL" < "$TOKEN_FILE" >/dev/null
}

activate_home() {
  local home=$1
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
}

poll_home() {
  FM_HOME="$1" "$ROOT/bin/fm-portal-poll.sh"
}

inject_text() {
  local text=$1 file="$TMP_ROOT/message-body.txt"
  printf '%s' "$text" > "$file"
  server_message "$file"
}

prepare_request() {
  local home=$1 text=$2 id out
  install_home "$home"
  id=$(inject_text "$text")
  out=$(poll_home "$home")
  [ "$out" = "portal-message $id" ] || fail "poll did not offer request $id (got: $out)"
  FM_HOME="$home" "$ROOT/bin/fm-portal-request.sh" read "$id" >/dev/null
  printf '%s\n' "$id"
}

assert_stats() {
  local field=$1 expected=$2 label=$3 actual
  actual=$(server_stats | jq -r "$field")
  [ "$actual" = "$expected" ] || fail "$label: expected $expected, got $actual"
}

# ---------------------------------------------------------------------------

test_absent_config_is_inert() {
  local home="$TMP_ROOT/absent" out
  out=$(FM_HOME="$home" "$ROOT/bin/fm-portal-poll.sh")
  [ -z "$out" ] || fail "absent connector poll must be silent"
  assert_absent "$home" "absent connector poll must not create FM_HOME"
  pass "portal connector is a hard no-op until explicitly configured"
}

test_config_helper_and_permissions() {
  local home="$TMP_ROOT/config" out err
  install_home "$home"
  [ "$(path_mode "$home/config/portal-connector.json")" = 600 ] || fail "connector config must be mode 0600"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-portal-config.sh" status)
  assert_contains "$out" "$BASE_URL" "status must print only the non-secret endpoint"
  assert_not_contains "$out" "fixture-token" "status leaked the token"
  chmod 644 "$home/config/portal-connector.json"
  out=$(poll_home "$home")
  [ "$out" = "portal-error config-unsafe-file" ] || fail "unsafe config mode was not rejected"
  assert_not_contains "$out" "fixture-token" "unsafe-config error leaked the token"
  activate_home "$home"
  assert_absent "$home/state/portal-watch.check.sh" "bootstrap armed an unsafe connector config"
  chmod 600 "$home/config/portal-connector.json"
  printf '{bad json\n' > "$home/config/portal-connector.json"
  out=$(poll_home "$home")
  [ "$out" = "portal-error config-invalid-json" ] || fail "malformed config was not rejected"
  err="$home/remote.err"
  if printf 'another-fixture-token\n' | FM_HOME="$home" "$ROOT/bin/fm-portal-config.sh" install --token-stdin \
    --base-url http://example.test > /dev/null 2> "$err"; then
    fail "non-loopback HTTP configuration was accepted"
  fi
  assert_no_grep "another-fixture-token" "$err" "config helper error leaked token input"
  pass "config install, validation, permissions, and redaction are guarded"
}

test_poll_cursor_duplicate_and_wake_persistence() {
  local home="$TMP_ROOT/poll" id out queue body record_count before after
  server_reset
  install_home "$home"
  # shellcheck disable=SC2016 # Command syntax is deliberate untrusted fixture text.
  id=$(inject_text 'Run $(touch /tmp/never) literally; this is portal data.')
  out=$(poll_home "$home")
  [ "$out" = "portal-message $id" ] || fail "first poll did not offer the captain request"
  body="$home/state/portal/inbox/$id.json"
  [ "$(path_mode "$home/state/portal/inbox")" = 700 ] || fail "portal inbox directory must be private"
  [ "$(path_mode "$body")" = 600 ] || fail "portal inbox message must be private"
  # shellcheck disable=SC2016 # Compare against the same literal fixture text.
  [ "$(jq -r .body "$body")" = 'Run $(touch /tmp/never) literally; this is portal data.' ] \
    || fail "portal text was not preserved strictly as data"
  assert_absent /tmp/never "portal text was executed"
  record_count=$(find "$home/state/portal/records" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$record_count" = 1 ] || fail "duplicate poll created more than one durable request record"
  FM_HOME="$home" "$ROOT/bin/fm-portal-request.sh" mark-queued "$id"
  out=$(poll_home "$home")
  [ -z "$out" ] || fail "queued request was offered again on a duplicate poll"
  [ "$(jq -r .last_id "$home/state/portal/cursor.json")" = "$id" ] || fail "cursor did not advance monotonically"
  FM_HOME="$home" "$ROOT/bin/fm-portal-request.sh" read "$id" >/dev/null
  printf 'First duplicate-poll request completed.' > "$TMP_ROOT/poll-first-reply.txt"
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" "$id" --text-file "$TMP_ROOT/poll-first-reply.txt" >/dev/null

  # A new message through the real watcher produces one durable body-free queue
  # record and commits the local queued marker only after append.
  activate_home "$home"
  id=$(inject_text 'Wake the active Firstmate session once.')
  FM_HOME="$home" FM_POLL=0 FM_CHECK_INTERVAL=0 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err"
  assert_grep "portal-message $id" "$home/watch.out" "watcher did not surface portal message"
  queue="$home/state/.wake-queue"
  [ "$(grep -c "portal-message $id" "$queue")" = 1 ] || fail "portal wake was not persisted exactly once"
  assert_no_grep 'Wake the active' "$queue" "wake queue leaked a message body"
  [ "$(jq -r .state "$home/state/portal/records/$id.json")" = queued ] || fail "watcher did not commit queued state"
  before=$(wc -l < "$queue" | tr -d ' ')
  rm -f "$home/state/.last-check"
  set +e
  FM_HOME="$home" FM_POLL=0.1 FM_CHECK_INTERVAL=0 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    timeout 1 "$ROOT/bin/fm-watch.sh" > "$home/watch-2.out" 2> "$home/watch-2.err"
  set -e
  after=$(wc -l < "$queue" | tr -d ' ')
  [ "$after" = "$before" ] || fail "watcher restart duplicated an already queued portal notification"
  pass "poll, cursor, duplicate, restart, and durable wake behavior converge"
}

test_poll_errors_timeout_bounds_and_batch() {
  local home="$TMP_ROOT/poll-errors" controls out i id count
  server_reset
  install_home "$home"
  id=$(inject_text 'Recover after malformed polling.')
  controls="$TMP_ROOT/controls.json"
  printf '{"poll_malformed":2}\n' > "$controls"
  server_control "$controls"
  out=$(poll_home "$home")
  [ "$out" = 'portal-error poll-invalid-response' ] || fail "malformed poll response was not reported"
  out=$(poll_home "$home")
  [ -z "$out" ] || fail "unchanged malformed response error was not deduplicated"
  out=$(poll_home "$home")
  [ "$out" = "portal-message $id" ] || fail "poll did not recover after malformed responses"
  FM_HOME="$home" "$ROOT/bin/fm-portal-request.sh" mark-queued "$id"

  server_reset
  home="$TMP_ROOT/poll-timeout"
  install_home "$home"
  id=$(inject_text 'Retry a transient timeout safely.')
  printf '{"poll_timeout":1}\n' > "$controls"
  server_control "$controls"
  out=$(poll_home "$home")
  [ "$out" = "portal-message $id" ] || fail "bounded poll retry did not recover after timeout"

  server_reset
  home="$TMP_ROOT/poll-batch"
  install_home "$home"
  for i in $(seq 1 21); do inject_text "bounded message $i" >/dev/null; done
  out=$(FM_HOME="$home" FM_PORTAL_BATCH_SIZE=999 "$ROOT/bin/fm-portal-poll.sh")
  count=$(printf '%s' "$out" | awk '{print NF-1}')
  [ "$count" = 1 ] || fail "oldest-first notification emitted more than one request"
  [ "$(find "$home/state/portal/records" -type f -name '*.json' | wc -l | tr -d ' ')" = 20 ] \
    || fail "poll batch did not clamp durable fetches to 20"
  id=$(printf '%s' "$out" | awk '{print $2}')
  FM_HOME="$home" "$ROOT/bin/fm-portal-request.sh" mark-queued "$id"
  out=$(poll_home "$home")
  [ -z "$out" ] || fail "later request bypassed the oldest queued request"
  [ "$(find "$home/state/portal/records" -type f -name '*.json' | wc -l | tr -d ' ')" = 21 ] \
    || fail "second bounded poll did not durably fetch the remaining message"

  server_reset
  home="$TMP_ROOT/poll-oversize"
  install_home "$home"
  printf '{"poll_oversized":1}\n' > "$controls"
  server_control "$controls"
  out=$(poll_home "$home")
  case "$out" in portal-error\ poll-network|portal-error\ poll-oversized-response) ;; *) fail "oversized API response was not rejected (got: $out)" ;; esac
  pass "poll errors, retries, response bounds, and batch bounds are deterministic"
}

run_crash_case() {
  local seam=$1 home="$TMP_ROOT/crash-$1" id reply="$TMP_ROOT/reply-$1.txt" rc stats
  server_reset
  id=$(prepare_request "$home" "captain request for $seam")
  printf 'Completed portal outcome for %s.' "$seam" > "$reply"
  set +e
  env FM_HOME="$home" "$seam"=1 "$ROOT/bin/fm-portal-reply.sh" "$id" --text-file "$reply" >/dev/null 2> "$home/crash.err"
  rc=$?
  set -e
  [ "$rc" = 99 ] || fail "$seam crash seam returned $rc"
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" --resume "$id" >/dev/null
  stats=$(server_stats)
  [ "$(printf '%s' "$stats" | jq -r .reply_count)" = 1 ] || fail "$seam duplicated or lost the portal reply"
  [ "$(printf '%s' "$stats" | jq -r '.acknowledged_ids|length')" = 1 ] || fail "$seam lost the acknowledgement"
  [ "$(printf '%s' "$stats" | jq -r .idempotency_keys)" = 1 ] || fail "$seam changed the idempotency key"
  [ "$(jq -r .state "$home/state/portal/outbox/$id.json")" = complete ] || fail "$seam did not converge local outbox"
  [ "$(jq -r .state "$home/state/portal/records/$id.json")" = complete ] || fail "$seam did not converge request record"
}

test_reply_crash_windows_and_idempotency() {
  local home id reply stats posts controls rc
  run_crash_case FM_PORTAL_TEST_CRASH_AFTER_OUTBOX
  run_crash_case FM_PORTAL_TEST_CRASH_AFTER_POST
  run_crash_case FM_PORTAL_TEST_CRASH_AFTER_POST_RECORD
  run_crash_case FM_PORTAL_TEST_CRASH_AFTER_ACK

  server_reset
  home="$TMP_ROOT/reply-malformed"
  id=$(prepare_request "$home" 'Handle an ambiguous malformed post response.')
  printf 'One durable response after malformed confirmation.' > "$TMP_ROOT/reply-malformed.txt"
  controls="$TMP_ROOT/reply-controls.json"
  printf '{"post_malformed_after_commit":1}\n' > "$controls"
  server_control "$controls"
  set +e
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" "$id" --text-file "$TMP_ROOT/reply-malformed.txt" >/dev/null 2> "$home/first.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed stored-message response unexpectedly succeeded"
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" --resume "$id" >/dev/null
  assert_stats '.reply_count' 1 "malformed-response retry duplicated reply"
  assert_stats '.acknowledged_ids|length' 1 "malformed-response retry lost ack"

  # A dropped HTTP connection after each server commit is safe because the
  # stable reply key and acknowledgement endpoint are both idempotent.
  server_reset
  home="$TMP_ROOT/reply-network-drop"
  id=$(prepare_request "$home" 'Recover from transient post and ack connection loss.')
  printf 'One response across dropped connections.' > "$TMP_ROOT/reply-network-drop.txt"
  printf '{"post_drop_after_commit":1,"ack_drop_after_commit":1}\n' > "$controls"
  server_control "$controls"
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" "$id" --text-file "$TMP_ROOT/reply-network-drop.txt" >/dev/null
  assert_stats '.reply_count' 1 "dropped connection duplicated reply"
  assert_stats '.acknowledged_ids|length' 1 "dropped connection lost acknowledgement"

  # Re-running a completed transaction is a local no-op.
  stats=$(server_stats)
  posts=$(printf '%s' "$stats" | jq -r '.request_counts.post')
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" --resume "$id" >/dev/null
  [ "$(server_stats | jq -r '.request_counts.post')" = "$posts" ] || fail "completed reply performed another POST"

  # A durable post result exists before acknowledgement is attempted.
  server_reset
  home="$TMP_ROOT/ack-order"
  id=$(prepare_request "$home" 'Prove acknowledgement ordering.')
  printf 'Ordered response result.' > "$TMP_ROOT/ack-order.txt"
  set +e
  FM_HOME="$home" FM_PORTAL_TEST_CRASH_AFTER_POST_RECORD=1 "$ROOT/bin/fm-portal-reply.sh" "$id" \
    --text-file "$TMP_ROOT/ack-order.txt" >/dev/null 2>/dev/null
  rc=$?
  set -e
  [ "$rc" = 99 ] || fail "ack-order seam did not stop after durable post"
  assert_stats '.reply_count' 1 "ack-order post missing"
  assert_stats '.acknowledged_ids|length' 0 "request was acknowledged before durable post confirmation"
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" --resume "$id" >/dev/null
  assert_stats '.acknowledged_ids|length' 1 "ack-order resume did not acknowledge"
  pass "reply idempotency, malformed responses, crash windows, and acknowledgement order converge"
}

test_cumulative_ack_order_is_serialized() {
  local home="$TMP_ROOT/ack-serial" first second out reply
  server_reset
  install_home "$home"
  first=$(inject_text 'First captain request must complete first.')
  second=$(inject_text 'Second captain request must not be acknowledged early.')
  out=$(poll_home "$home")
  [ "$out" = "portal-message $first" ] || fail "poll did not offer the oldest request first"
  if FM_HOME="$home" "$ROOT/bin/fm-portal-request.sh" read "$second" >/dev/null 2>&1; then
    fail "later request bypassed the oldest incomplete request"
  fi
  FM_HOME="$home" "$ROOT/bin/fm-portal-request.sh" read "$first" >/dev/null
  reply="$TMP_ROOT/ack-serial-first.txt"; printf 'First request completed.' > "$reply"
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" "$first" --text-file "$reply" >/dev/null
  [ "$(server_stats | jq -r '.acknowledged_ids|join(",")')" = "$first" ] \
    || fail "first completion acknowledged a later request"
  out=$(poll_home "$home")
  [ "$out" = "portal-message $second" ] || fail "second request was not offered after first completion"
  pass "cumulative portal acknowledgements are serialized oldest-first"
}

test_response_conflict_is_terminal() {
  local home="$TMP_ROOT/conflict" id outbox reply controls rc
  server_reset
  id=$(prepare_request "$home" 'Exercise idempotency conflict handling.')
  reply="$TMP_ROOT/conflict-reply.txt"
  printf 'Original response body.' > "$reply"
  set +e
  FM_HOME="$home" FM_PORTAL_TEST_CRASH_AFTER_POST_RECORD=1 "$ROOT/bin/fm-portal-reply.sh" "$id" --text-file "$reply" >/dev/null 2>/dev/null
  set -e
  outbox="$home/state/portal/outbox/$id.json"
  # Simulate local durable-state corruption while preserving schema validity.
  printf 'Different response body.' > "$TMP_ROOT/different.txt"
  hash=$(if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$TMP_ROOT/different.txt" | awk '{print $1}'; else sha256sum "$TMP_ROOT/different.txt" | awk '{print $1}'; fi)
  jq --rawfile body "$TMP_ROOT/different.txt" --arg hash "$hash" '.body=$body | .body_sha256=$hash | .state="pending" | .portal_message_id=null' \
    "$outbox" > "$outbox.tmp"
  chmod 600 "$outbox.tmp"
  mv "$outbox.tmp" "$outbox"
  set +e
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" --resume "$id" >/dev/null 2> "$home/conflict.err"
  rc=$?
  set -e
  [ "$rc" = 4 ] || fail "idempotency conflict did not use the terminal conflict exit"
  [ "$(jq -r .state "$outbox")" = conflict ] || fail "outbox conflict was not persisted"
  [ "$(jq -r .state "$home/state/portal/records/$id.json")" = conflict ] || fail "request conflict was not persisted"
  assert_stats '.reply_count' 1 "conflict inserted another reply"
  assert_stats '.acknowledged_ids|length' 0 "conflict acknowledged the originating request"
  assert_no_grep 'Original response body' "$home/conflict.err" "conflict error leaked response text"
  pass "idempotency-key conflicts stop without duplicate reply or acknowledgement"
}

test_task_link_and_channel_binding() {
  local home="$TMP_ROOT/link" id reply meta
  server_reset
  id=$(prepare_request "$home" 'Run longer work and answer only in this portal.')
  mkdir -p "$home/state"
  meta="$home/state/task-one.meta"
  printf 'window=test:fm-task-one\nkind=ship\n' > "$meta"
  FM_HOME="$home" "$ROOT/bin/fm-portal-link.sh" task-one "$id" >/dev/null
  [ "$(jq -r .state "$home/state/portal/records/$id.json")" = linked ] || fail "request was not linked"
  assert_grep "portal_request=$id" "$meta" "task metadata lost portal binding"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-portal-request.sh" list)" ] || fail "linked request remained in direct inbox drain"
  [ -z "$(poll_home "$home")" ] || fail "linked request was re-offered by polling"
  reply="$TMP_ROOT/linked-outcome.txt"
  printf 'The linked work completed successfully.' > "$reply"
  FM_HOME="$home" "$ROOT/bin/fm-portal-followup.sh" task-one --text-file "$reply" >/dev/null
  assert_no_grep 'portal_request=' "$meta" "completed portal task link was not cleared"
  assert_stats '.reply_count' 1 "task-linked response did not stay exactly once"
  assert_stats '.acknowledged_ids|length' 1 "task-linked response did not acknowledge origin"
  pass "long-running work returns exactly once to its originating portal channel"
}

test_token_and_body_redaction() {
  local home="$TMP_ROOT/redaction" id reply out err findings
  server_reset
  id=$(prepare_request "$home" 'SENSITIVE-FIXTURE-BODY must not enter wakes or logs.')
  reply="$TMP_ROOT/redaction-reply.txt"
  printf 'SENSITIVE-FIXTURE-REPLY' > "$reply"
  out="$home/out"; err="$home/err"
  FM_HOME="$home" FM_PORTAL_TEST_CRASH_AFTER_POST_RECORD=1 "$ROOT/bin/fm-portal-reply.sh" "$id" --text-file "$reply" > "$out" 2> "$err" || true
  findings=$(grep -R -l -E 'fixture-token-that-is-never-logged|SENSITIVE-FIXTURE-(BODY|REPLY)' \
    "$home/state" "$out" "$err" 2>/dev/null \
    | grep -v "/portal/inbox/$id.json" \
    | grep -v "/portal/outbox/$id.json" || true)
  [ -z "$findings" ] || fail "secret or message text leaked outside private inbox/outbox: $findings"
  if [ -s "$home/state/.wake-queue" ]; then
    assert_no_grep 'SENSITIVE-FIXTURE' "$home/state/.wake-queue" "wake payload leaked message text"
    assert_no_grep 'fixture-token' "$home/state/.wake-queue" "wake payload leaked token"
  fi
  assert_no_grep 'SENSITIVE-FIXTURE' "$out" "reply stdout leaked response text"
  assert_no_grep 'fixture-token' "$err" "reply stderr leaked token"
  pass "credentials and message bodies stay out of output, wakes, and logs"
}

test_away_harness_and_backend_contracts() {
  local harness out home backend id
  for harness in claude codex opencode pi grok; do
    home="$TMP_ROOT/harness-$harness"
    mkdir -p "$home/config"
    : > "$home/config/portal-mode.env"
    out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness" --portal-mode 1)
    assert_contains "$out" "$home/config/portal-mode.env" "$harness protocol omitted portal cadence"
    assert_not_contains "$out" '__FM_PORTAL_MODE_ENV' "$harness protocol leaked a placeholder"
  done
  assert_grep 'portal-mode.env' "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "Pi extension does not source portal cadence"
  assert_grep 'portal-mode.env' "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "OpenCode plugin does not source portal cadence"

  # Portal check execution occurs before any task backend integration surface.
  for backend in tmux herdr zellij orca cmux; do
    server_reset
    home="$TMP_ROOT/backend-$backend"
    install_home "$home"
    activate_home "$home"
    id=$(inject_text "backend-independent request for $backend")
    FM_HOME="$home" FM_BACKEND="$backend" FM_POLL=0 FM_CHECK_INTERVAL=0 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err"
    assert_grep "portal-message $id" "$home/watch.out" "$backend watcher did not dispatch portal check"
  done

  server_reset
  home="$TMP_ROOT/away"
  install_home "$home"
  activate_home "$home"
  id=$(inject_text 'away-mode portal request')
  : > "$home/state/.afk"
  FM_HOME="$home" FM_BACKEND=tmux FM_POLL=0 FM_CHECK_INTERVAL=0 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err"
  assert_grep "portal-message $id" "$home/watch.out" "away-owned watcher did not surface portal request"
  assert_grep "portal-message $id" "$home/state/.wake-queue" "away-owned watcher did not persist portal request"
  pass "portal wake integration is shared across all harnesses, backends, and away mode"
}

test_disable_and_retention() {
  local home="$TMP_ROOT/disable" id reply old out
  server_reset
  id=$(prepare_request "$home" 'Complete then retain privately.')
  reply="$TMP_ROOT/disable-reply.txt"
  printf 'Completed before disable.' > "$reply"
  FM_HOME="$home" "$ROOT/bin/fm-portal-reply.sh" "$id" --text-file "$reply" >/dev/null
  old=$(( $(date +%s) - 1000 ))
  if [ "$(uname)" = Darwin ]; then touch -t "$(date -r "$old" +%Y%m%d%H%M.%S)" "$home/state/portal/records/$id.json"; else touch -d "@$old" "$home/state/portal/records/$id.json"; fi
  FM_HOME="$home" FM_PORTAL_RETENTION_SECS=10 "$ROOT/bin/fm-portal-poll.sh" >/dev/null
  assert_absent "$home/state/portal/records/$id.json" "expired completed record was not pruned"
  FM_HOME="$home" "$ROOT/bin/fm-portal-config.sh" disable >/dev/null
  out=$(poll_home "$home")
  [ -z "$out" ] || fail "disabled connector poll was not inert"
  activate_home "$home"
  assert_absent "$home/state/portal-watch.check.sh" "disable cleanup left portal check armed"
  assert_absent "$home/config/portal-mode.env" "disable cleanup left portal cadence active"
  pass "completed retention is bounded and disablement returns to inert behavior"
}

# Run in dependency order so server resets do not race.
test_absent_config_is_inert
test_config_helper_and_permissions
test_poll_cursor_duplicate_and_wake_persistence
test_poll_errors_timeout_bounds_and_batch
test_reply_crash_windows_and_idempotency
test_cumulative_ack_order_is_serialized
test_response_conflict_is_terminal
test_task_link_and_channel_binding
test_token_and_body_redaction
test_away_harness_and_backend_contracts
test_disable_and_retention
