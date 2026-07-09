#!/usr/bin/env bash
# tests/fm-backend-codex-app.test.sh - fake Codex app-server and fake bridge
# tests for the codex-app runtime backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-codex-app-tests)

make_fake_codex_bin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$dir/fake-codex-app-server.js" <<'NODE'
const fs = require("node:fs");
const readline = require("node:readline");
const log = process.env.FM_FAKE_CODEX_LOG;
const threadId = process.env.FM_FAKE_CODEX_THREAD_ID || "thread-123";
const turnId = process.env.FM_FAKE_CODEX_TURN_ID || "turn-456";
const forcedCwd = process.env.FM_FAKE_CODEX_CWD || "";
const omitCwd = process.env.FM_FAKE_CODEX_OMIT_CWD === "1";
const statusFile = process.env.FM_FAKE_CODEX_STATUS_FILE || "";
const statusDelayMs = Number(process.env.FM_FAKE_CODEX_STATUS_DELAY_MS || "0");
const initializeDelayMs = Number(process.env.FM_FAKE_CODEX_INITIALIZE_DELAY_MS || "0");
const resumeDelayMs = Number(process.env.FM_FAKE_CODEX_RESUME_DELAY_MS || "0");
const turnStartDelayMs = Number(process.env.FM_FAKE_CODEX_TURN_START_DELAY_MS || "0");
const substantiveFile = process.env.FM_FAKE_CODEX_SUBSTANTIVE_FILE || "";
const substantiveDelayMs = Number(process.env.FM_FAKE_CODEX_SUBSTANTIVE_DELAY_MS || "0");
const holdActiveUntilSubstantive = process.env.FM_FAKE_CODEX_HOLD_ACTIVE_UNTIL_SUBSTANTIVE === "1";
const metadataFail = process.env.FM_FAKE_CODEX_METADATA_FAIL === "1";
let substantiveDone = false;
function write(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}
function respond(msg, delayMs = 0, after = null) {
  const send = () => {
    write(msg);
    if (after) after();
  };
  if (delayMs > 0) setTimeout(send, delayMs);
  else send();
}
function record(msg) {
  fs.appendFileSync(log, "request\t" + (msg.method || "") + "\t" + JSON.stringify(msg.params || {}) + "\n");
}
function thread(cwd, status = "idle") {
  const value = {
    id: threadId,
    sessionId: threadId,
    preview: "fake preview",
    ephemeral: false,
    modelProvider: "openai",
    cliVersion: "fake",
    createdAt: 1,
    updatedAt: 2,
    source: { kind: "appServer" },
    status: { type: status },
    turns: []
  };
  if (!omitCwd) value.cwd = cwd;
  return value;
}
function hasSchemaNativeTextInput(params) {
  return Array.isArray(params.input) && params.input.some(item =>
    item && item.type === "text" && typeof item.text === "string" && Array.isArray(item.text_elements)
  );
}
function currentTurnStatus() {
  if (holdActiveUntilSubstantive && !substantiveDone) return "inProgress";
  return process.env.FM_FAKE_CODEX_TURN_STATUS || "completed";
}
const rl = readline.createInterface({ input: process.stdin });
rl.on("line", line => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  record(msg);
  const id = msg.id;
  const params = msg.params || {};
  const cwd = forcedCwd || params.cwd || "/tmp/fake-cwd";
  if (msg.method === "initialize") {
    respond({ id, result: { userAgent: "Codex Desktop/fake", codexHome: "/tmp/fake-codex-home", platformFamily: "unix", platformOs: "macos" } }, initializeDelayMs);
  } else if (msg.method === "thread/start") {
    const result = { thread: thread(cwd), model: params.model || "gpt-5", modelProvider: "openai", approvalPolicy: "never", approvalsReviewer: "user", sandbox: { mode: "danger-full-access" } };
    if (!omitCwd) result.cwd = cwd;
    write({ id, result });
  } else if (msg.method === "thread/resume") {
    const result = { thread: thread(cwd), model: params.model || "gpt-5", modelProvider: "openai", approvalPolicy: "never", approvalsReviewer: "user", sandbox: { mode: "danger-full-access" } };
    if (!omitCwd) result.cwd = cwd;
    respond({ id, result }, resumeDelayMs);
  } else if (msg.method === "thread/name/set" || msg.method === "thread/goal/set") {
    if (metadataFail) write({ id, error: { code: -32000, message: "metadata failed" } });
    else write({ id, result: {} });
  } else if (msg.method === "thread/archive") {
    write({ id, result: {} });
  } else if (msg.method === "turn/start") {
    if (!hasSchemaNativeTextInput(params)) {
      write({ id, error: { code: -32602, message: "turn/start text input missing text_elements" } });
      return;
    }
    respond({ id, result: { turn: { id: turnId, status: "inProgress", input: params.input || [] } } }, turnStartDelayMs, () => {
      if (statusFile) {
        setTimeout(() => {
          fs.appendFileSync(statusFile, "working: Codex thread started\n");
        }, statusDelayMs);
      }
      if (substantiveFile) {
        setTimeout(() => {
          fs.appendFileSync(substantiveFile, "substantive: bridge still alive\n");
          substantiveDone = true;
        }, substantiveDelayMs);
      }
    });
  } else if (msg.method === "thread/read") {
    const status = holdActiveUntilSubstantive && !substantiveDone ? "active" : (process.env.FM_FAKE_CODEX_STATUS || "idle");
    write({ id, result: { thread: thread(cwd, status) } });
  } else if (msg.method === "thread/turns/list") {
    if (process.env.FM_FAKE_CODEX_DESC_TURNS === "1") {
      write({ id, result: { data: [
        { id: "turn-new", status: "completed", items: [{ type: "agentMessage", text: "newest line" }] },
        { id: "turn-old", status: "completed", items: [{ type: "agentMessage", text: "older line" }] }
      ], nextCursor: null, backwardsCursor: null } });
    } else {
      write({ id, result: { data: [{ id: turnId, status: currentTurnStatus(), items: [{ type: "userMessage", content: [{ type: "text", text: "hello captain" }] }, { type: "agentMessage", text: "aye captain" }] }], nextCursor: null, backwardsCursor: null } });
    }
  } else if (msg.method === "thread/list") {
    write({ id, result: { data: [thread(cwd, process.env.FM_FAKE_CODEX_STATUS || "idle")], nextCursor: null } });
  } else {
    write({ id, error: { code: -32601, message: "unknown method " + msg.method } });
  }
});
NODE
  cat > "$fb/codex" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_FAKE_CODEX_LOG:?}"
{
  printf 'codex'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = app-server ] && [ "${2:-}" = --help ]; then
  printf 'codex app-server help\n'
  exit 0
fi
if [ "${1:-}" = app-server ] && [ "${2:-}" = --listen ] && [ "${3:-}" = stdio:// ]; then
  server_dir=$(cd "$(dirname "$0")/.." && pwd)
  node "$server_dir/fake-codex-app-server.js"
  exit $?
fi
echo "unexpected fake codex invocation: $*" >&2
exit 2
SH
  chmod +x "$fb/codex"
  printf '%s\n' "$fb"
}

make_fake_bridge() {  # <dir> -> echoes fake bridge path
  local dir=$1 bridge="$1/fm-codex-bridge"
  cat > "$bridge" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_FAKE_BRIDGE_LOG:?}"
verb=${1:-}
shift || true
{
  printf '%s' "$verb"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
case "$verb" in
  ensure-running)
    printf '{"ok":true,"mode":"direct-stdio"}\n'
    ;;
  start-thread)
    printf '{"ok":true,"thread_id":"thread-from-bridge","cwd":"%s","thread":{"id":"thread-from-bridge","status":{"type":"idle"}}}\n' "${FM_FAKE_BRIDGE_CWD:-/tmp/fake-wt}"
    ;;
  send-turn)
    printf '{"ok":true,"turn":{"id":"turn-from-bridge","status":"inProgress"}}\n'
    ;;
  turns-list)
    if [ "${FM_FAKE_BRIDGE_EMPTY_TEXT:-0}" = 1 ]; then
      printf '{"ok":true,"text":"","turns":[{"id":"turn-from-bridge","status":"completed"}]}\n'
      exit 0
    fi
    if [ "${FM_FAKE_BRIDGE_LONG_TEXT:-0}" = 1 ]; then
      printf '{"ok":true,"text":"line 1\\nline 2\\nline 3\\nline 4\\nline 5\\nline 6","turns":[{"id":"turn-from-bridge","status":"completed"}]}\n'
    else
      printf '{"ok":true,"text":"user: hello captain\\nassistant: aye captain","turns":[{"id":"turn-from-bridge","status":"completed"}]}\n'
    fi
    ;;
  read-thread)
    printf '{"ok":true,"thread":{"id":"thread-from-bridge","status":{"type":"%s"}}}\n' "${FM_FAKE_BRIDGE_STATUS:-idle}"
    ;;
  thread-status)
    printf '{"ok":true,"status":"%s","thread":{"id":"thread-from-bridge","status":{"type":"%s"}}}\n' "${FM_FAKE_BRIDGE_STATUS:-idle}" "${FM_FAKE_BRIDGE_STATUS:-idle}"
    ;;
  archive-thread)
    printf '{"ok":true,"archived":true}\n'
    ;;
  list-live)
    printf '{"ok":true,"threads":[{"id":"thread-from-bridge","cwd":"%s","status":{"type":"idle"}}]}\n' "${FM_FAKE_BRIDGE_CWD:-/tmp/fake-wt}"
    ;;
  *)
    echo "unexpected fake bridge verb: $verb" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$bridge"
  printf '%s\n' "$bridge"
}

json_field() {  # <field> <json>
  local field=$1
  node -e '
const field = process.argv[1];
let data = "";
process.stdin.on("data", chunk => data += chunk);
process.stdin.on("end", () => {
  const obj = JSON.parse(data);
  const value = field.split(".").reduce((acc, key) => acc == null ? undefined : acc[key], obj);
  if (value == null) process.exit(1);
  process.stdout.write(String(value));
});
' "$field"
}

test_bridge_start_thread_uses_app_server_stdio() {
  local dir fb log prompt out thread_id cwd status log_before resume_line turn_line
  dir="$TMP_ROOT/bridge-start"
  mkdir -p "$dir/wt"
  log="$dir/codex.log"
  prompt="$dir/prompt.txt"
  printf 'Do the thing, captain.\n' > "$prompt"
  fb=$(make_fake_codex_bin "$dir")

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" \
    "$ROOT/bin/fm-codex-bridge" start-thread --cwd "$dir/wt" --name "fm-task" --goal "ship it" --model gpt-5)
  status=$?
  expect_code 0 "$status" "bridge start-thread should succeed against fake app-server"
  thread_id=$(printf '%s' "$out" | json_field thread_id)
  cwd=$(printf '%s' "$out" | json_field cwd)
  [ "$thread_id" = thread-123 ] || fail "bridge should print normalized thread_id, got '$thread_id'"
  [ "$cwd" = "$dir/wt" ] || fail "bridge should print normalized cwd, got '$cwd'"
  assert_contains "$(cat "$log")" $'request\tinitialize\t' "bridge did not initialize app-server"
  assert_contains "$(cat "$log")" $'request\tthread/start\t' "bridge did not start a thread"
  assert_contains "$(cat "$log")" $'request\tthread/name/set\t' "bridge did not set the thread name"
  assert_contains "$(cat "$log")" $'request\tthread/goal/set\t' "bridge did not set the thread goal"
  log_before=$(cat "$log")
  assert_not_contains "$log_before" $'request\tturn/start\t' "bridge start-thread should not start the initial turn before cwd validation"

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" FM_CODEX_APP_TURN_LIFECYCLE_POLLS=3 FM_CODEX_APP_TURN_LIFECYCLE_SLEEP=0.01 \
    "$ROOT/bin/fm-codex-bridge" send-turn --thread-id "$thread_id" --prompt-file "$prompt" --cwd "$dir/wt" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "bridge send-turn should start the initial turn after validation"
  assert_contains "$(cat "$log")" $'request\tthread/resume\t' "bridge should resume one-shot threads before turn/start"
  assert_contains "$(cat "$log")" $'request\tturn/start\t' "bridge did not start the initial turn"
  resume_line=$(grep -n $'request\tthread/resume\t' "$log" | head -1 | cut -d: -f1)
  turn_line=$(grep -n $'request\tturn/start\t' "$log" | head -1 | cut -d: -f1)
  [ "$resume_line" -lt "$turn_line" ] || fail "bridge should resume the thread before turn/start"
  assert_contains "$(cat "$log")" '"excludeTurns":true' "bridge resume should avoid loading full turns before send"
  assert_contains "$(cat "$log")" '"sandbox":"danger-full-access"' "bridge resume should use the app-server sandbox string shape"
  assert_contains "$(cat "$log")" '"text_elements":[]' "bridge should send schema-native text input"
  pass "fm-codex-bridge: start-thread normalizes thread cwd before send-turn starts the first turn"
}

test_bridge_send_turn_keeps_app_server_alive_until_return_channel() {
  local dir fb log prompt status_file substantive_file out status i
  dir="$TMP_ROOT/bridge-turn-lifecycle"
  mkdir -p "$dir/wt"
  log="$dir/codex.log"
  prompt="$dir/prompt.txt"
  status_file="$dir/status.log"
  substantive_file="$dir/substantive.log"
  printf 'Write the return-channel line, captain.\n' > "$prompt"
  fb=$(make_fake_codex_bin "$dir")

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" FM_FAKE_CODEX_STATUS_FILE="$status_file" FM_FAKE_CODEX_STATUS_DELAY_MS=200 FM_FAKE_CODEX_SUBSTANTIVE_FILE="$substantive_file" FM_FAKE_CODEX_SUBSTANTIVE_DELAY_MS=500 FM_FAKE_CODEX_HOLD_ACTIVE_UNTIL_SUBSTANTIVE=1 FM_CODEX_APP_RETURN_CHANNEL_POLLS=40 FM_CODEX_APP_RETURN_CHANNEL_SLEEP=0.05 FM_CODEX_APP_TURN_LIFECYCLE_POLLS=40 FM_CODEX_APP_TURN_LIFECYCLE_SLEEP=0.05 \
    "$ROOT/bin/fm-codex-bridge" send-turn --thread-id thread-123 --prompt-file "$prompt" --cwd "$dir/wt" --model gpt-5 --wait-status-file "$status_file" --wait-status-line 'working: Codex thread started' 2>&1)
  status=$?
  expect_code 0 "$status" "bridge send-turn should keep app-server alive until the status file handshake: $out"
  assert_grep "working: Codex thread started" "$status_file" "bridge should wait for the app-server-driven status write"
  for ((i = 0; i < 40; i += 1)); do
    [ -f "$substantive_file" ] && break
    sleep 0.05
  done
  assert_grep "substantive: bridge still alive" "$substantive_file" "bridge should keep app-server alive after the startup status line"
  assert_contains "$(cat "$log")" $'request\tthread/resume\t' "bridge should resume the thread before startup turn"
  assert_contains "$(cat "$log")" $'request\tturn/start\t' "bridge did not start the turn"
  assert_contains "$(cat "$log")" '"text_elements":[]' "bridge should send schema-native text input while waiting for handshake"
  pass "fm-codex-bridge: send-turn keeps app-server alive through startup return-channel verification"
}

test_bridge_send_turn_tracks_turn_status_when_thread_is_not_loaded() {
  local dir fb log prompt substantive_file out status i
  dir="$TMP_ROOT/bridge-turn-not-loaded"
  mkdir -p "$dir/wt"
  log="$dir/codex.log"
  prompt="$dir/prompt.txt"
  substantive_file="$dir/substantive.log"
  printf 'Keep the turn alive even when the shell thread status is notLoaded, captain.\n' > "$prompt"
  fb=$(make_fake_codex_bin "$dir")

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" FM_FAKE_CODEX_STATUS=notLoaded FM_FAKE_CODEX_SUBSTANTIVE_FILE="$substantive_file" FM_FAKE_CODEX_SUBSTANTIVE_DELAY_MS=350 FM_FAKE_CODEX_HOLD_ACTIVE_UNTIL_SUBSTANTIVE=1 FM_CODEX_APP_TURN_LIFECYCLE_POLLS=40 FM_CODEX_APP_TURN_LIFECYCLE_SLEEP=0.02 \
    "$ROOT/bin/fm-codex-bridge" send-turn --thread-id thread-123 --prompt-file "$prompt" --cwd "$dir/wt" --model gpt-5 2>&1)
  status=$?
  expect_code 0 "$status" "bridge send-turn should accept a turn whose thread shell status is notLoaded: $out"
  for ((i = 0; i < 40; i += 1)); do
    [ -f "$substantive_file" ] && break
    sleep 0.02
  done
  assert_grep "substantive: bridge still alive" "$substantive_file" "bridge should keep the app-server alive until the turn reports completed"
  assert_contains "$(cat "$log")" $'request\tthread/turns/list\t' "bridge should poll the turn lifecycle instead of treating thread notLoaded as completion"
  pass "fm-codex-bridge: send-turn tracks turn status when the thread shell status is notLoaded"
}

test_bridge_send_turn_ready_timeout_covers_slow_pre_ready_requests() {
  local dir fb log prompt status_file out status
  dir="$TMP_ROOT/bridge-turn-ready-timeout"
  mkdir -p "$dir/wt"
  log="$dir/codex.log"
  prompt="$dir/prompt.txt"
  status_file="$dir/status.log"
  printf 'Start slowly but within budget, captain.\n' > "$prompt"
  fb=$(make_fake_codex_bin "$dir")

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" FM_FAKE_CODEX_STATUS_FILE="$status_file" FM_FAKE_CODEX_INITIALIZE_DELAY_MS=6400 FM_FAKE_CODEX_RESUME_DELAY_MS=6400 FM_FAKE_CODEX_TURN_START_DELAY_MS=6400 FM_FAKE_CODEX_STATUS_DELAY_MS=50 FM_CODEX_BRIDGE_TIMEOUT_MS=7000 FM_CODEX_APP_RETURN_CHANNEL_POLLS=2 FM_CODEX_APP_RETURN_CHANNEL_SLEEP=0.1 FM_CODEX_APP_TURN_LIFECYCLE_POLLS=1 \
    "$ROOT/bin/fm-codex-bridge" send-turn --thread-id thread-123 --prompt-file "$prompt" --cwd "$dir/wt" --model gpt-5 --wait-status-file "$status_file" --wait-status-line 'working: Codex thread started' 2>&1)
  status=$?
  expect_code 0 "$status" "bridge send-turn should wait for initialize, thread/resume, turn/start, and status-file budgets before worker ready: $out"
  assert_grep "working: Codex thread started" "$status_file" "bridge should see the delayed status-file handshake"
  assert_contains "$(cat "$log")" $'request\tinitialize\t' "bridge did not initialize before delayed ready"
  assert_contains "$(cat "$log")" $'request\tthread/resume\t' "bridge did not resume before delayed ready"
  assert_contains "$(cat "$log")" $'request\tturn/start\t' "bridge did not start turn before delayed ready"
  pass "fm-codex-bridge: send-turn ready timeout covers slow pre-ready requests"
}

test_bridge_send_turn_rejects_stale_status_line() {
  local dir fb log prompt status_file out status
  dir="$TMP_ROOT/bridge-turn-stale-status"
  mkdir -p "$dir/wt"
  log="$dir/codex.log"
  prompt="$dir/prompt.txt"
  status_file="$dir/status.log"
  printf 'Start from a stale status file, captain.\n' > "$prompt"
  printf 'working: Codex thread started\n' > "$status_file"
  fb=$(make_fake_codex_bin "$dir")

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" FM_CODEX_APP_RETURN_CHANNEL_POLLS=3 FM_CODEX_APP_RETURN_CHANNEL_SLEEP=0.01 FM_CODEX_APP_TURN_LIFECYCLE_POLLS=1 \
    "$ROOT/bin/fm-codex-bridge" send-turn --thread-id thread-123 --prompt-file "$prompt" --cwd "$dir/wt" --wait-status-file "$status_file" --wait-status-line 'working: Codex thread started' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "bridge send-turn should reject a status line that predates the current turn"
  assert_contains "$out" "did not write return-channel status" "stale status failure should name the missing fresh return-channel write"
  assert_contains "$(cat "$log")" $'request\tturn/start\t' "stale status case should still start the current turn"
  pass "fm-codex-bridge: send-turn ignores stale return-channel status lines"
}

test_bridge_start_thread_requires_reported_cwd() {
  local dir fb log out status
  dir="$TMP_ROOT/bridge-start-missing-cwd"
  mkdir -p "$dir/wt"
  log="$dir/codex.log"
  fb=$(make_fake_codex_bin "$dir")

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" FM_FAKE_CODEX_OMIT_CWD=1 \
    "$ROOT/bin/fm-codex-bridge" start-thread --cwd "$dir/wt" --name "fm-task" --goal "ship it" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "bridge start-thread should fail when Codex omits cwd"
  assert_contains "$out" "start-thread response did not include cwd" "missing cwd failure should explain the absent app-server cwd"
  assert_contains "$(cat "$log")" $'request\tthread/start\t' "missing cwd case should still start the thread before validating the response"
  assert_contains "$(cat "$log")" $'request\tthread/archive\t' "missing cwd case should archive the unsupervised thread"
  assert_not_contains "$(cat "$log")" $'request\tturn/start\t' "missing cwd case should not start the initial turn"
  pass "fm-codex-bridge: start-thread requires a reported thread cwd"
}

test_bridge_turns_list_renders_chronological_text_from_desc_response() {
  local dir fb log out status text
  dir="$TMP_ROOT/bridge-turn-order"
  mkdir -p "$dir/wt"
  log="$dir/codex.log"
  fb=$(make_fake_codex_bin "$dir")

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" FM_FAKE_CODEX_DESC_TURNS=1 \
    "$ROOT/bin/fm-codex-bridge" turns-list --thread-id thread-123 --limit 2 --items-view summary)
  status=$?
  expect_code 0 "$status" "bridge turns-list should succeed against fake app-server"
  text=$(printf '%s' "$out" | json_field text)
  case "$text" in
    *"older line"*"newest line"*) : ;;
    *) fail "turns-list text should render oldest-to-newest before backend tailing, got: $text" ;;
  esac
  pass "fm-codex-bridge: turns-list renders chronological text from desc Codex results"
}

test_bridge_start_thread_returns_id_when_metadata_calls_fail() {
  local dir fb log out status thread_id cwd
  dir="$TMP_ROOT/bridge-metadata-fail"
  mkdir -p "$dir/wt"
  log="$dir/codex.log"
  fb=$(make_fake_codex_bin "$dir")

  out=$(PATH="$fb:$PATH" FM_FAKE_CODEX_LOG="$log" FM_FAKE_CODEX_METADATA_FAIL=1 \
    "$ROOT/bin/fm-codex-bridge" start-thread --cwd "$dir/wt" --name "fm-task" --goal "ship it")
  status=$?
  expect_code 0 "$status" "bridge start-thread should still return the thread id when name or goal metadata fails"
  thread_id=$(printf '%s' "$out" | json_field thread_id)
  cwd=$(printf '%s' "$out" | json_field cwd)
  [ "$thread_id" = thread-123 ] || fail "bridge should preserve thread_id after metadata failure, got '$thread_id'"
  [ "$cwd" = "$dir/wt" ] || fail "bridge should preserve cwd after metadata failure, got '$cwd'"
  assert_contains "$out" "metadata_errors" "bridge should report best-effort metadata failures without hiding the thread id"
  assert_contains "$(cat "$log")" $'request\tthread/name/set\t' "metadata-failure case should attempt to set the thread name"
  assert_contains "$(cat "$log")" $'request\tthread/goal/set\t' "metadata-failure case should attempt to set the thread goal"
  assert_not_contains "$(cat "$log")" $'request\tturn/start\t' "metadata-failure start-thread should not start the first turn before cwd validation"
  pass "fm-codex-bridge: start-thread returns the created thread id when metadata calls fail"
}

test_backend_dispatch_accepts_codex_app() {
  local dir bridge log out status
  dir="$TMP_ROOT/backend-dispatch"
  mkdir -p "$dir"
  log="$dir/bridge.log"
  bridge=$(make_fake_bridge "$dir")
  out=$(FM_CODEX_BRIDGE="$bridge" FM_FAKE_BRIDGE_LOG="$log" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_validate codex-app; fm_backend_validate_spawn codex-app; fm_backend_source codex-app' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app should be a known spawn-capable backend: $out"
  pass "fm-backend.sh: codex-app validates, spawn-validates, and sources its adapter"
}

test_backend_capture_send_busy_exists_and_kill_route_to_bridge() {
  local dir bridge log out status
  dir="$TMP_ROOT/backend-ops"
  mkdir -p "$dir"
  log="$dir/bridge.log"
  bridge=$(make_fake_bridge "$dir")
  out=$(FM_CODEX_BRIDGE="$bridge" FM_FAKE_BRIDGE_LOG="$log" FM_FAKE_BRIDGE_STATUS=active \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_capture codex-app thread-abc 5; fm_backend_send_text_submit codex-app thread-abc "hello captain" 2 0.01 0.01; fm_backend_busy_state codex-app thread-abc; fm_backend_target_exists codex-app thread-abc; fm_backend_kill codex-app thread-abc' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app backend operations should succeed: $out"
  assert_contains "$out" "hello captain" "capture should print bridge text"
  assert_contains "$out" "empty" "send_text_submit should report empty after accepted turn"
  assert_contains "$out" "busy" "active Codex thread should map to busy"
  assert_contains "$(cat "$log")" $'turns-list\x1f--thread-id\x1fthread-abc' "capture did not call bridge turns-list"
  assert_contains "$(cat "$log")" $'send-turn\x1f--thread-id\x1fthread-abc' "send did not call bridge send-turn"
  assert_contains "$(cat "$log")" $'thread-status\x1f--thread-id\x1fthread-abc' "busy/exists did not call bridge thread-status"
  assert_contains "$(cat "$log")" $'archive-thread\x1f--thread-id\x1fthread-abc' "kill did not archive the Codex thread"
  pass "codex-app adapter: capture, send, busy-state, target-exists, and kill route through the bridge"
}

test_backend_busy_state_maps_active_lifecycle_statuses() {
  local dir bridge log out status lifecycle_status
  dir="$TMP_ROOT/backend-busy-lifecycle"
  mkdir -p "$dir"
  log="$dir/bridge.log"
  bridge=$(make_fake_bridge "$dir")
  for lifecycle_status in active inProgress running; do
    out=$(FM_CODEX_BRIDGE="$bridge" FM_FAKE_BRIDGE_LOG="$log" FM_FAKE_BRIDGE_STATUS="$lifecycle_status" \
      bash -c '. "$0/bin/fm-backend.sh"; fm_backend_busy_state codex-app thread-abc' "$ROOT" 2>&1)
    status=$?
    expect_code 0 "$status" "codex-app busy-state should accept $lifecycle_status: $out"
    [ "$out" = busy ] || fail "$lifecycle_status Codex thread should map to busy, got '$out'"
  done
  pass "codex-app adapter: busy-state maps active lifecycle statuses to busy"
}

test_backend_capture_trims_to_requested_lines_with_separate_turn_limit() {
  local dir bridge log out status
  dir="$TMP_ROOT/backend-capture-limit"
  mkdir -p "$dir"
  log="$dir/bridge.log"
  bridge=$(make_fake_bridge "$dir")
  out=$(FM_CODEX_BRIDGE="$bridge" FM_FAKE_BRIDGE_LOG="$log" FM_FAKE_BRIDGE_LONG_TEXT=1 FM_CODEX_APP_CAPTURE_TURN_LIMIT=7 \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_capture codex-app thread-abc 3' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app capture should succeed with a line budget: $out"
  assert_not_contains "$out" "line 1" "capture should trim older transcript lines"
  assert_not_contains "$out" "line 3" "capture should trim to the requested line count"
  assert_contains "$out" "line 4" "capture should include the recent tail"
  assert_contains "$out" "line 6" "capture should include the newest line"
  assert_contains "$(cat "$log")" $'--limit\x1f7' "capture should use the separate Codex turn fetch limit"
  assert_not_contains "$(cat "$log")" $'--limit\x1f3' "capture should not use the line budget as the turn fetch limit"
  pass "codex-app adapter: capture trims output lines separately from turn fetch limit"
}

test_backend_capture_returns_empty_parsed_text() {
  local dir bridge log out status
  dir="$TMP_ROOT/backend-capture-empty-text"
  mkdir -p "$dir"
  log="$dir/bridge.log"
  bridge=$(make_fake_bridge "$dir")
  out=$(FM_CODEX_BRIDGE="$bridge" FM_FAKE_BRIDGE_LOG="$log" FM_FAKE_BRIDGE_EMPTY_TEXT=1 \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_capture codex-app thread-abc 3' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "codex-app capture should accept an empty transcript field: $out"
  [ -z "$out" ] || fail "capture should return empty parsed text instead of bridge JSON: $out"
  assert_contains "$(cat "$log")" $'turns-list\x1f--thread-id\x1fthread-abc' "capture did not call bridge turns-list"
  pass "codex-app adapter: capture returns empty parsed transcript text"
}

test_bridge_start_thread_uses_app_server_stdio
test_bridge_send_turn_keeps_app_server_alive_until_return_channel
test_bridge_send_turn_tracks_turn_status_when_thread_is_not_loaded
test_bridge_send_turn_ready_timeout_covers_slow_pre_ready_requests
test_bridge_send_turn_rejects_stale_status_line
test_bridge_start_thread_requires_reported_cwd
test_bridge_turns_list_renders_chronological_text_from_desc_response
test_bridge_start_thread_returns_id_when_metadata_calls_fail
test_backend_dispatch_accepts_codex_app
test_backend_capture_send_busy_exists_and_kill_route_to_bridge
test_backend_busy_state_maps_active_lifecycle_statuses
test_backend_capture_trims_to_requested_lines_with_separate_turn_limit
test_backend_capture_returns_empty_parsed_text
