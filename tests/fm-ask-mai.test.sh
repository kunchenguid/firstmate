#!/usr/bin/env bash
# tests/fm-ask-mai.test.sh - hermetic contract tests for the MAI-Pro routing
# shim, its redaction wrapper, and the config/mai-routing wake helper.
#
# A per-case python3 one-shot HTTP listener stands in for the F2 stage
# gateway, so the suite exercises the real curl request path with no network.
# The fail-closed exit codes and the MAI-only model pin are the contract being
# pinned; a regression that lets another model through or masquerades an
# empty answer as success fails here.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null || { printf 'skip: python3 absent\n' >&2; exit 0; }

SHIM="$ROOT/bin/fm-ask-mai.sh"
WRAPPER="$ROOT/bin/fm-ask-mai-redacted.sh"
WAKE="$ROOT/bin/fm-ask-mai-wake.sh"
TMP_ROOT=$(fm_test_tmproot fm-ask-mai)

MOCK_PY="$TMP_ROOT/mock_gateway.py"
cat > "$MOCK_PY" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

plan_file, count_file = sys.argv[1], sys.argv[2]
with open(plan_file) as fh:
    script = json.load(fh)
calls = {"n": 0}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        calls["n"] += 1
        request = script["requests"][calls["n"] - 1] if calls["n"] <= len(script["requests"]) else {}
        if request.get("assert_model") and json.loads(body).get("model") != request["assert_model"]:
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"message": "wrong model"}}).encode())
            return
        response = script["responses"][min(calls["n"] - 1, len(script["responses"]) - 1)]
        self.send_response(response["status"])
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response["body"]).encode())

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(count_file, "w") as fh:
    fh.write(str(server.server_port))
server.serve_forever()
PY

# start_mock <name> <plan-json> - run one listener, set MOCK_PORT. Exactly one
# mock is live at a time; the previous one is killed first.
MOCK_PID=
MOCK_PORT=
stop_mock() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  wait "$MOCK_PID" 2>/dev/null
  MOCK_PID=
}
trap 'stop_mock' EXIT

start_mock() {
  stop_mock
  local plan=$2
  local plan_file=$TMP_ROOT/$1.plan.json port_file=$TMP_ROOT/$1.port
  printf '%s' "$plan" > "$plan_file"
  python3 "$MOCK_PY" "$plan_file" "$port_file" &
  MOCK_PID=$!
  local waited=0
  while [ ! -s "$port_file" ] && [ $waited -lt 50 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  [ -s "$port_file" ] || fail "mock $1 never bound a port"
  MOCK_PORT=$(cat "$port_file")
}

# run_shim <case> <script> [arg...] -- [VAR=val ...]; captures OUT/ERR/RC.
# Extra environment is applied via a `command env` invocation only when
# nonempty, because a literal expansion guard after an assignment list can
# synthesize an empty argument on macOS /usr/bin/env.
OUT='' ERR='' RC=0
apply_script() { # <script> [args...] -- ENVS_COUNT/ENVS_ONE from caller
  local script=$1
  shift
  if [ "$ENVS_COUNT" -gt 0 ]; then
    command env "F2_GATEWAY_TOKEN_CMD=true" \
        "F2_GATEWAY_URL=http://127.0.0.1:$MOCK_PORT/api/v1/gateway/v1" \
        "FM_MAI_TIMEOUT_SECS=10" "FM_MAI_RETRY_DELAY_SECS=0" \
        "$ENVS_ONE" \
        "$script" "$@" >"$RUN_OUT" 2>"$RUN_ERR" || RC=$?
  else
    command env "F2_GATEWAY_TOKEN_CMD=true" \
        "F2_GATEWAY_URL=http://127.0.0.1:$MOCK_PORT/api/v1/gateway/v1" \
        "FM_MAI_TIMEOUT_SECS=10" "FM_MAI_RETRY_DELAY_SECS=0" \
        "$script" "$@" >"$RUN_OUT" 2>"$RUN_ERR" || RC=$?
  fi
}
run_case() {
  local kasename=$1 script=$2
  shift 2
  local -a args=() envs=()
  local split=0 a
  for a in "$@"; do
    if [ "$split" -eq 0 ] && [ "$a" = -- ]; then split=1; continue; fi
    if [ "$split" -eq 0 ]; then args+=("$a"); else envs+=("$a"); fi
  done
  [ "${#envs[@]}" -le 1 ] || fail "run_case $kasename: at most one env pair is supported"
  ENVS_COUNT=${#envs[@]} ENVS_ONE=${envs[0]-}
  RUN_OUT=$TMP_ROOT/$kasename.out RUN_ERR=$TMP_ROOT/$kasename.err
  RC=0
  apply_script "$script" "${args[@]+"${args[@]}"}"
  OUT=$(cat "$RUN_OUT")
  ERR=$(cat "$RUN_ERR")
}

# plan_ok <content> <finish> - one-request plan asserting the fixed model and
# one recorded 200 response carrying <content> with <finish>.
plan_ok() {
  jq -nc --arg c "$1" --arg f "$2" \
    '{requests:[{assert_model:"marutai/MAI-Pro"}],responses:[{status:200,body:{choices:[{message:{content:$c},finish_reason:$f}]}}]}'
}
# plan_resp <status> <body-json> - plan with no request assertions and one
# recorded response as raw JSON.
plan_resp() {
  jq -nc --argjson s "$1" --argjson b "$2" \
    '{requests:[],responses:[{status:$s,body:$b}]}'
}

# --- shim contract -----------------------------------------------------------

test_200_ok_returns_answer_only() {
  start_mock ok "$(plan_ok absorb stop)"
  RC=0
  run_case ok "$SHIM" classify-this 64
  expect_code 0 "$RC" "200 with content must succeed (stderr: $ERR)"
  assert_equals "absorb" "$OUT" "stdout must be the answer text only"
  [ -z "$ERR" ] || fail "happy path must keep stderr clean: $ERR"
  pass "a 200 with content returns the answer text and nothing else"
}

test_model_is_fixed_to_mai_pro() {
  # The mock already asserts model=marutai/MAI-Pro on every request above; here
  # the seams that could re-point the model must be usage errors instead.
  start_mock fixed "$(plan_resp 200 '{}')"
  RC=0
  run_case fixed-env "$SHIM" hi -- "FM_MAI_MODEL=anthropic/claude-opus"
  expect_code 2 "$RC" "FM_MAI_MODEL must be a usage error"
  RC=0
  run_case fixed-arg "$SHIM" hi 512 anthropic/claude-opus
  expect_code 2 "$RC" "a model argument must be a usage error"
  pass "no env or argument can select anything other than marutai/MAI-Pro"
}

test_503_retries_then_fails_closed() {
  start_mock sat "$(plan_resp 503 '{"error":{"message":"Database session capacity is temporarily saturated"}}')"
  RC=0
  run_case sat "$SHIM" hi -- "FM_MAI_RETRIES=2"
  expect_code 3 "$RC" "persistent 503 must exit 3"
  case "$ERR" in
    "fm-ask-mai: transport: "*) : ;;
    *) fail "503 stderr must carry the transport class: $ERR" ;;
  esac
  pass "a 503 that never clears fails closed with the transport class after bounded retry"
}

test_empty_content_finish_stop_fails() {
  start_mock null "$(plan_resp 200 '{"choices":[{"message":{"content":null},"finish_reason":"stop"}]}')"
  RC=0
  run_case null "$SHIM" hi
  expect_code 4 "$RC" "null content must exit 4"
  [ -z "$OUT" ] || fail "a null content answer must print nothing on stdout: $OUT"
  pass "null content is a failed call, never a blank success"
}

test_length_cutoff_fails() {
  start_mock len "$(plan_resp 200 '{"choices":[{"message":{"content":null},"finish_reason":"length"}]}')"
  RC=0
  run_case len "$SHIM" hi
  expect_code 5 "$RC" "finish_reason=length must exit 5"
  pass "a reasoning-budget length cutoff fails closed"
}

# --- redaction wrapper -------------------------------------------------------

run_wrapper() { # <case> [VAR=val ...] -- < input
  local kasename=$1; shift
  local -a envs=()
  local a split=0
  for a in "$@"; do
    if [ "$split" -eq 0 ] && [ "$a" = -- ]; then split=1; continue; fi
    if [ "$split" -eq 0 ]; then fail "run_wrapper $kasename: env pairs must follow the -- separator (got '$a')"; fi
    envs+=("$a")
  done
  [ "${#envs[@]}" -le 1 ] || fail "run_wrapper $kasename: at most one env pair is supported"
  ENVS_COUNT=${#envs[@]} ENVS_ONE=${envs[0]-}
  RUN_OUT=$TMP_ROOT/$kasename.out RUN_ERR=$TMP_ROOT/$kasename.err
  RC=0
  if [ "$ENVS_COUNT" -gt 0 ]; then
    command env "F2_GATEWAY_TOKEN_CMD=true" \
        "F2_GATEWAY_URL=http://127.0.0.1:$MOCK_PORT/api/v1/gateway/v1" \
        "FM_MAI_TIMEOUT_SECS=10" "FM_MAI_RETRY_DELAY_SECS=0" \
        "$ENVS_ONE" \
        "$WRAPPER" >"$RUN_OUT" 2>"$RUN_ERR"
    RC=$?
  else
    command env "F2_GATEWAY_TOKEN_CMD=true" \
        "F2_GATEWAY_URL=http://127.0.0.1:$MOCK_PORT/api/v1/gateway/v1" \
        "FM_MAI_TIMEOUT_SECS=10" "FM_MAI_RETRY_DELAY_SECS=0" \
        "$WRAPPER" >"$RUN_OUT" 2>"$RUN_ERR"
    RC=$?
  fi
  OUT=$(cat "$RUN_OUT")
  ERR=$(cat "$RUN_ERR")
}

# Capture the request body via a record plan: the mock asserts the model and
# replies with fixed text; the prompt reaches it through curl. To observe the
# redacted prompt, use a proxy that saves the body.
RECORDER_PY="$TMP_ROOT/recorder.py"
cat > "$RECORDER_PY" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

body_file, port_file = sys.argv[1], sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        with open(body_file, "wb") as fh:
            fh.write(self.rfile.read(length))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"choices": [{"message": {"content": "absorb"}, "finish_reason": "stop"}]}).encode())

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as fh:
    fh.write(str(server.server_port))
server.serve_forever()
PY

start_recorder() { # <name>
  stop_mock
  local rec_body=$TMP_ROOT/$1.body rec_port=$TMP_ROOT/$1.port
  python3 "$RECORDER_PY" "$rec_body" "$rec_port" &
  MOCK_PID=$!
  local waited=0
  while [ ! -s "$rec_port" ] && [ $waited -lt 50 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  [ -s "$rec_port" ] || fail "recorder $1 never bound a port"
  MOCK_PORT=$(cat "$rec_port")
  MOCK_BODY_FILE=$rec_body
}


test_redaction_refuses_private_material() {
  local marker
  for marker in '@captain' '@private' '@secret'; do
    start_recorder "refuse-${marker#@}"
    printf 'note %s: expand capacity' "$marker" | run_wrapper "refuse-${marker#@}" --
    expect_code 2 "$RC" "a $marker line must be refused"
    [ ! -s "$MOCK_BODY_FILE" ] && : || fail "a $marker line must never reach the gateway"
    rm -f "$MOCK_BODY_FILE"
  done
  for body in 'see data/captain.md for the preference' 'per data/learnings.md line 9' 'from data/fm-foo/brief.md intent' 'token is in .env now'; do
    start_recorder "refuse-body"
    printf '%s' "$body" | run_wrapper refuse-body --
    expect_code 2 "$RC" "'$body' must be refused"
    [ ! -s "$MOCK_BODY_FILE" ] && : || fail "'$body' must never reach the gateway"
    rm -f "$MOCK_BODY_FILE"
  done
  pass "tier-1 material and @captain/@private/@secret markers are refused before any call"
}

test_wrapper_forwards_shim_failures() {
  start_mock wsat "$(plan_resp 503 '{"error":{"message":"saturated"}}')"
  printf 'plain wake text' | run_wrapper wsat -- "FM_MAI_RETRIES=1"
  [ "$RC" -ne 0 ] || fail "a failed shim call must fail through the wrapper"
  pass "shim failure exit codes pass through the wrapper"
}

# --- config/mai-routing wake helper ------------------------------------------

run_wake() { # <case> <home> <reason...>
  local kasename=$1 where=$2
  shift 2
  local out_file=$TMP_ROOT/$kasename.out
  RC=0
  env "F2_GATEWAY_TOKEN_CMD=true" \
      "F2_GATEWAY_URL=http://127.0.0.1:$MOCK_PORT/api/v1/gateway/v1" \
      "FM_MAI_TIMEOUT_SECS=10" "FM_MAI_RETRY_DELAY_SECS=0" \
      "$WAKE" "$where" "$@" >"$out_file" 2>/dev/null || RC=$?
  RC=${RC:-0}
  OUT=$(cat "$out_file")
}

test_wake_helper_flag_off_is_inert() {
  local home=$TMP_ROOT/home-off
  mkdir -p "$home/config"
  start_recorder flag-off
  run_wake flag-off "$home" "done: PR opened"
  expect_code 2 "$RC" "absent config/mai-routing must leave wake handling untouched"
  [ ! -s "$MOCK_BODY_FILE" ] || fail "flag off must place no gateway call"
  stop_mock
  run_wake still-off "$home" "done: PR opened"
  expect_code 2 "$RC" "flag off stays a refusal with no backend at all"
  pass "without config/mai-routing the helper exits 2 and never calls out"
}

test_wake_helper_failures_and_out_of_set_escalate() {
  local home=$TMP_ROOT/home-on
  mkdir -p "$home/config"
  : > "$home/config/mai-routing"
  start_mock wok "$(plan_resp 200 "$(jq -nc '{choices:[{message:{content:"surface"},finish_reason:"stop"}]}')")"
  run_wake wok "$home" "done: PR https://github.com/jubin-marut/firstmate/pull/108 opened"
  expect_code 0 "$RC" "an in-set answer must succeed"
  assert_equals "surface" "$OUT" "an in-set answer passes through"

  start_mock junk "$(plan_resp 200 "$(jq -nc '{choices:[{message:{content:"probably absorb-ish"},finish_reason:"stop"}]}')")"
  run_wake junk "$home" "working: implementing"
  expect_code 0 "$RC" "an out-of-set answer still resolves to a word"
  assert_equals "escalate" "$OUT" "an out-of-set answer must become escalate"

  start_mock wsat2 "$(plan_resp 503 '{"error":{"message":"saturated"}}')"
  run_wake wsat2 "$home" "working: implementing" 
  expect_code 0 "$RC" "a failed call still resolves to a word"
  assert_equals "escalate" "$OUT" "a failed call must become escalate"
  pass "the wake helper maps out-of-set and failed calls to escalate"
}

# --- runner ------------------------------------------------------------------

tests=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
count=0
for t in $tests; do
  "$t"
  count=$((count + 1))
done
stop_mock
printf 'ok - %d/%d fm-ask-mai tests passed\n' "$count" "$count"
