#!/usr/bin/env bash
# Behavior tests for the ChatGPT consultation client (bin/fm-chatgpt-consult.sh
# and bin/fm-chatgpt-bridge-lib.sh).
#
# A stubbed loopback endpoint stands in for the codex-chatgpt-web bridge, so
# normal CI spends no live ChatGPT dependency. Every case drives the scripts'
# executable interface and asserts the recorded request shape, never source
# bytes. bin/fm-lint.sh owns the lint gate; shellcheck-cleanliness is proven
# there, not here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSULT="$ROOT/bin/fm-chatgpt-consult.sh"
# shellcheck source=bin/fm-chatgpt-bridge-lib.sh
. "$ROOT/bin/fm-chatgpt-bridge-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chatgpt-consult)
STUB_PORT=17899
export CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:$STUB_PORT/v1"

# start_stub <case-dir>: serves one canned Responses payload and records the
# request body at <case-dir>/request.json. Prints the server pid.
start_stub() {
  local dir=$1 status=${2:-200}
  cat > "$dir/stub.py" <<PY
import http.server, json, sys
d = "$dir"
status = $status
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        open(d + "/request.json", "wb").write(self.rfile.read(n))
        if status != 200:
            body = json.dumps({"error": {"message": "stub failure"}}).encode()
            self.send_response(status)
        else:
            body = json.dumps({"output": [{"type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "stubbed consultation answer"}]}]}).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", $STUB_PORT), H).serve_forever()
PY
  python3 "$dir/stub.py" >"$dir/stub.log" 2>&1 &
  printf '%s' "$!"
  for _ in $(seq 1 50); do
    curl -s -m 1 -X POST "http://127.0.0.1:$STUB_PORT/v1" -d '{}' >/dev/null 2>&1 && break
    sleep 0.1
  done
}

stop_stub() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

new_prompt() {
  printf 'Review the login handler for auth gaps.\n' > "$TMP_ROOT/prompt.txt"
}

request_meta() {
  jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | "\(.thread_id) \(.turn_id)"' "$TMP_ROOT/$1/request.json"
}

test_audit_request_shape() {
  local dir=$TMP_ROOT/audit pid out rc
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread thread-audit-1 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "an audit consult against the stub should succeed"
  [ "$out" = "stubbed consultation answer" ] || fail "stdout must carry only the response text, got: $out"
  assert_contains "$(jq -r '.instructions' "$dir/request.json")" "audit" "an audit request must frame the auditor role"
  assert_contains "$(jq -r '.input[0].content' "$dir/request.json")" "login handler" "the request must carry the prompt file text"
  pass "an audit consult posts the auditor framing with the prompt text and prints only the answer"
}

test_plan_request_shape() {
  local dir=$TMP_ROOT/plan pid out rc
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode plan --thread thread-plan-1 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "a plan consult against the stub should succeed"
  assert_contains "$(jq -r '.instructions' "$dir/request.json")" "execution plan" "a plan request must frame the planner role"
  pass "a plan consult posts the planner framing with the prompt text"
}

test_metadata_stamping() {
  local dir=$TMP_ROOT/stamp pid
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread thread-stamp-9 >/dev/null 2>&1
  stop_stub "$pid"
  [ "$(request_meta stamp | cut -d' ' -f1)" = "thread-stamp-9" ] || fail "the stamp must carry the supplied thread id"
  grep -Eq "^turn_[0-9a-f]{32}$" <(request_meta stamp | cut -d' ' -f2) || fail "the stamp must carry a stable turn id"
  grep -Eq "^msg_[0-9a-f]{32}$" <(jq -r '.input[0].id' "$dir/request.json") || fail "input messages must carry stable item ids"
  [ "$(jq -r '.input[0].type' "$dir/request.json")" = "message" ] || fail "role-only items must gain the message type"
  pass "consultation turns carry the Codex turn stamp and stable item ids"
}

test_model_slug() {
  local dir=$TMP_ROOT/slug pid
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread t1 >/dev/null 2>&1
  stop_stub "$pid"
  [ "$(jq -r '.model' "$dir/request.json")" = "chatgpt-web/gpt-5.6-luna" ] || fail "the request must ride the default qualified Luna slug"
  local slug rc
  slug=$(fm_chatgpt_model_slug "gpt-5.6-luna"); rc=$?
  expect_code 0 "$rc" "the lib should accept a bare model id"
  [ "$slug" = "chatgpt-web/gpt-5.6-luna" ] || fail "the lib must qualify the bare id, got: $slug"
  fm_chatgpt_model_slug "chatgpt-web/chatgpt-web/gpt-5.6-luna" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "the lib must refuse the doubled selector"
  pass "bare model ids ride the bridge slug and doubled selectors refuse"
}

test_thread_propagation() {
  local dir=$TMP_ROOT/thread pid out rc
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode plan --thread thread-keep-7 2>"$dir/stderr.txt")
  stop_stub "$pid"
  [ "$(request_meta thread | cut -d' ' -f1)" = "thread-keep-7" ] || fail "the request must propagate the supplied thread id"
  [ ! -s "$dir/stderr.txt" ] || fail "a supplied thread must not be re-reported, got: $(cat "$dir/stderr.txt")"
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode plan 2>&1); rc=$?
  expect_code 2 "$rc" "a missing --thread must fail closed"
  assert_contains "$out" "--thread" "the failure must name the missing option"
  pass "supplied thread ids propagate and a missing thread fails closed"
}

test_bridge_unavailable_fails_closed() {
  local out rc
  new_prompt
  out=$(CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:1/v1" bash "$CONSULT" \
    --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread t-down 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable bridge must fail closed"
  assert_contains "$out" "bridge" "the failure must name the bridge prerequisite"
  pass "an unreachable bridge fails closed with a prerequisite report"
}

test_bridge_failure_fails_closed() {
  local dir=$TMP_ROOT/fail pid out rc
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir" 500)
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread t-fail 2>&1); rc=$?
  stop_stub "$pid"
  [ "$rc" -ne 0 ] || fail "a failing bridge must fail closed"
  assert_contains "$out" "HTTP 500" "the failure must report the bridge status"
  pass "a failing bridge fails closed with its status"
}

test_audit_request_shape
test_plan_request_shape
test_metadata_stamping
test_model_slug
test_thread_propagation
test_bridge_unavailable_fails_closed
test_bridge_failure_fails_closed
