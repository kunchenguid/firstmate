#!/usr/bin/env bash
# Behavior tests for the ChatGPT worker loop (bin/fm-chatgpt-loop.sh).
#
# A stubbed loopback endpoint stands in for the codex-chatgpt-web bridge and
# a stub fm-spawn.sh stands in for worker dispatch, so normal CI spends no
# live ChatGPT dependency and launches no worker. Every case drives the
# loop's executable interface and asserts recorded state and stub traffic,
# never source bytes. bin/fm-lint.sh owns the lint gate; shellcheck-cleanliness
# is proven there, not here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOOP="$ROOT/bin/fm-chatgpt-loop.sh"
TMP_ROOT=$(fm_test_tmproot fm-chatgpt-loop)
STUB_PORT=17911
export CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:$STUB_PORT/v1"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
export FM_HOME="$HOME_DIR"
export FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_STATE_OVERRIDE="$HOME_DIR/state"

# Stub consult: serves the real openai-responses shape through the stub
# bridge port by delegating to the real consult script. The stub records the
# prompt it was asked to consult.
start_stub() {
  local dir=$1 status=${2:-200} mode_text=${3:-stubbed consultation answer}
  cat > "$dir/stub.py" <<PY
import http.server, json
d = "$dir"
status = $status
answer = """$mode_text"""
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        open(d + "/request.json", "wb").write(self.rfile.read(n))
        if status != 200:
            body = json.dumps({"error": {"message": "stub failure"}}).encode()
            self.send_response(status)
        else:
            body = json.dumps({"output": [{"type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": answer}]}]}).encode()
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

# make_spawn_stub <dir>: writes a stub spawn that records its argv and
# environment, then exits 0, plus a stub fm-send that records the steering
# target and delivered message, then exits 0. Exports FM_CHATGPT_LOOP_SPAWN
# and FM_CHATGPT_LOOP_SEND at them.
make_spawn_stub() {
  local dir=$1
  cat > "$dir/fm-spawn-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_SPAWN_DIR/argv.txt"
env > "$STUB_SPAWN_DIR/env.txt"
exit "${STUB_SPAWN_EXIT:-0}"
SH
  chmod +x "$dir/fm-spawn-stub.sh"
  cat > "$dir/fm-send-stub.sh" <<'SH'
#!/usr/bin/env bash
target=$1
shift
{
  printf 'home: %s\n' "${FM_HOME:-}"
  printf 'state: %s\n' "${FM_STATE_OVERRIDE:-}"
} > "$STUB_SEND_DIR/send-env.txt"
{
  printf 'target: %s\n' "$target"
  printf 'message:\n%s\n' "$*"
} > "$STUB_SEND_DIR/send.txt"
exit "${STUB_SEND_EXIT:-0}"
SH
  chmod +x "$dir/fm-send-stub.sh"
  export FM_CHATGPT_LOOP_SPAWN="$dir/fm-spawn-stub.sh"
  export STUB_SPAWN_DIR="$dir"
  export FM_CHATGPT_LOOP_SEND="$dir/fm-send-stub.sh"
  export STUB_SEND_DIR="$dir"
}

new_task_files() {
  printf 'Fix the two failing CI checks.\n' > "$TMP_ROOT/objective.txt"
  printf 'repo at /tmp/demo, main branch green\n' > "$TMP_ROOT/context.txt"
}

loop_phase() {
  jq -r '.phase' "$HOME_DIR/data/$1/chatgpt-loop.json"
}

test_full_loop_happy_path() {
  local dir=$TMP_ROOT/happy pid
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  pid=$(start_stub "$dir")
  bash "$LOOP" init --task happy --objective-file "$TMP_ROOT/objective.txt" --context-file "$TMP_ROOT/context.txt" >/dev/null
  [ "$(loop_phase happy)" = "audit-consult" ] || fail "init must land in audit-consult"
  bash "$LOOP" consult --stage audit --task happy >/dev/null
  [ "$(loop_phase happy)" = "audit-dispatch" ] || fail "an audit consult must advance to audit-dispatch"
  assert_contains "$(jq -r '.input[0].content' "$dir/request.json")" "Fix the two failing CI checks" "the audit consultation must carry the user objective"
  stop_stub "$pid"
  bash "$LOOP" dispatch --stage audit --task happy -- mytask myproj --mode local-only --yolo off >/dev/null
  [ "$(loop_phase happy)" = "audit-worker" ] || fail "an audit dispatch must advance to audit-worker"
  assert_contains "$(cat "$dir/argv.txt")" "--effort low" "the audit stage must dispatch a low-thinking worker"
  assert_contains "$(cat "$dir/send.txt")" "target: mytask" "the audit prompt must be steered to the spawn's first positional task id"
  assert_contains "$(cat "$dir/send.txt")" "User objective:" "the delivered audit prompt must be the stored stage prompt"
  assert_contains "$(cat "$dir/send.txt")" "Fix the two failing CI checks" "the audit prompt must reach the worker's input"
  grep -Eiq 'CHATGPT_WEB_BRIDGE_URL|codex-chatgpt-web|17841|17911|fm-chatgpt|127\.0\.0\.1' "$dir/send.txt" && fail "the delivered audit prompt must carry no bridge reference"
  printf 'worker found two flaky tests\n' > "$dir/findings.txt"
  pid=$(start_stub "$dir")
  bash "$LOOP" record-findings --task happy --file "$dir/findings.txt" >/dev/null
  [ "$(loop_phase happy)" = "plan-consult" ] || fail "recorded findings must advance to plan-consult"
  bash "$LOOP" consult --stage plan --task happy >/dev/null
  [ "$(loop_phase happy)" = "plan-dispatch" ] || fail "a plan consult must advance to plan-dispatch"
  stop_stub "$pid"
  bash "$LOOP" dispatch --stage plan --task happy -- mytask myproj --mode local-only --yolo off >/dev/null
  [ "$(loop_phase happy)" = "plan-worker" ] || fail "a plan dispatch must advance to plan-worker"
  assert_contains "$(cat "$dir/argv.txt")" "--effort low" "the plan stage must dispatch a low-thinking worker"
  assert_contains "$(cat "$dir/send.txt")" "target: mytask" "the plan must be steered to the spawn's first positional task id"
  assert_contains "$(cat "$dir/send.txt")" "stubbed consultation answer" "the execution plan must reach the worker's input"
  grep -Eiq 'CHATGPT_WEB_BRIDGE_URL|codex-chatgpt-web|17841|17911|fm-chatgpt|127\.0\.0\.1' "$dir/send.txt" && fail "the delivered plan must carry no bridge reference"
  printf 'worker fixed both checks\n' > "$dir/result.txt"
  bash "$LOOP" record-result --task happy --file "$dir/result.txt" >/dev/null
  [ "$(loop_phase happy)" = "complete" ] || fail "a recorded result must complete the task"
  [ "$(jq -r '.worker_result' "$HOME_DIR/data/happy/chatgpt-loop.json")" = "worker fixed both checks" ] || fail "the completion must keep the worker result"
  pass "objective to audit to worker to plan to worker to completion flows through every phase"
}

test_plan_consult_carries_explicit_context() {
  local dir=$TMP_ROOT/ctxcarry pid
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  pid=$(start_stub "$dir")
  bash "$LOOP" init --task ctxcarry --objective-file "$TMP_ROOT/objective.txt" --context-file "$TMP_ROOT/context.txt" >/dev/null
  bash "$LOOP" consult --stage audit --task ctxcarry >/dev/null
  stop_stub "$pid"
  bash "$LOOP" dispatch --stage audit --task ctxcarry -- t p --mode local-only --yolo off >/dev/null
  printf 'worker finding: flaky retry logic\n' > "$dir/findings.txt"
  bash "$LOOP" record-findings --task ctxcarry --file "$dir/findings.txt" >/dev/null
  pid=$(start_stub "$dir")
  bash "$LOOP" consult --stage plan --task ctxcarry >/dev/null
  stop_stub "$pid"
  local plan_prompt
  plan_prompt=$(jq -r '.input[0].content' "$dir/request.json")
  assert_contains "$plan_prompt" "Fix the two failing CI checks" "the plan prompt must explicitly carry the objective"
  assert_contains "$plan_prompt" "repo at /tmp/demo" "the plan prompt must explicitly carry the Firstmate context"
  assert_contains "$plan_prompt" "stubbed consultation answer" "the plan prompt must explicitly carry the audit result"
  assert_contains "$plan_prompt" "flaky retry logic" "the plan prompt must explicitly carry the worker findings"
  pass "the plan consultation explicitly carries objective, context, audit result, and worker findings"
}

test_consult_failure_is_retryable() {
  local dir=$TMP_ROOT/consultfail
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  rm -f "$dir/argv.txt"
  bash "$LOOP" init --task consultfail --objective-file "$TMP_ROOT/objective.txt" >/dev/null
  local out rc
  out=$(CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:1/v1" bash "$LOOP" consult --stage audit --task consultfail 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a bridge failure must exit nonzero"
  [ "$(loop_phase consultfail)" = "audit-consult" ] || fail "a failed consult must leave the phase unchanged for retry"
  assert_contains "$(jq -r '.last_error' "$HOME_DIR/data/consultfail/chatgpt-loop.json")" "bridge" "a failed consult must record last_error"
  [ ! -f "$dir/argv.txt" ] || fail "a failed consult must dispatch nothing"
  assert_contains "$out" "bridge" "a failed consult must report the bridge prerequisite"
  pass "a ChatGPT bridge failure exits nonzero, records last_error, keeps the phase, and dispatches nothing"
}

test_worker_failure_recorded() {
  local dir=$TMP_ROOT/workerfail
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  local pid
  pid=$(start_stub "$dir")
  bash "$LOOP" init --task workerfail --objective-file "$TMP_ROOT/objective.txt" >/dev/null
  bash "$LOOP" consult --stage audit --task workerfail >/dev/null
  stop_stub "$pid"
  bash "$LOOP" dispatch --stage audit --task workerfail -- t p --mode local-only --yolo off >/dev/null
  local out rc
  out=$(bash "$LOOP" record-worker-failure --task workerfail --stage audit --reason "worker exited 1" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a worker failure record must exit nonzero"
  [ "$(loop_phase workerfail)" = "audit-dispatch" ] || fail "a worker failure must return to the failed stage's dispatch phase with no advance to the next consultation"
  assert_contains "$(jq -r '.last_error' "$HOME_DIR/data/workerfail/chatgpt-loop.json")" "worker exited 1" "a worker failure must record its reason"
  assert_contains "$out" "audit-dispatch" "a worker failure must surface the returned dispatch phase"
  rm -f "$dir/argv.txt" "$dir/send.txt"
  bash "$LOOP" dispatch --stage audit --task workerfail -- t p --mode local-only --yolo off >/dev/null; rc=$?
  [ "$rc" -eq 0 ] || fail "a recorded worker failure must leave the same stage re-dispatchable"
  [ "$(loop_phase workerfail)" = "audit-worker" ] || fail "the retry dispatch must advance to audit-worker"
  pass "a worker failure returns to dispatch, records last_error, and the stage retries"
}

test_spawn_failure_recorded() {
  local dir=$TMP_ROOT/spawnfail
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  local pid rc
  pid=$(start_stub "$dir")
  bash "$LOOP" init --task spawnfail --objective-file "$TMP_ROOT/objective.txt" >/dev/null
  bash "$LOOP" consult --stage audit --task spawnfail >/dev/null
  stop_stub "$pid"
  STUB_SPAWN_EXIT=7 bash "$LOOP" dispatch --stage audit --task spawnfail -- t p --mode local-only --yolo off >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed spawn must exit nonzero"
  [ "$(loop_phase spawnfail)" = "audit-dispatch" ] || fail "a failed spawn must leave the phase at audit-dispatch with no advance"
  assert_contains "$(jq -r '.last_error' "$HOME_DIR/data/spawnfail/chatgpt-loop.json")" "spawn failure" "a failed spawn must record last_error"
  [ ! -f "$dir/send.txt" ] || fail "a failed spawn must deliver no prompt"
  bash "$LOOP" dispatch --stage audit --task spawnfail -- t p --mode local-only --yolo off >/dev/null; rc=$?
  [ "$rc" -eq 0 ] || fail "a failed spawn must leave the same stage re-dispatchable"
  [ "$(loop_phase spawnfail)" = "audit-worker" ] || fail "the retry dispatch must advance to audit-worker"
  pass "a failed spawn records last_error, holds the dispatch phase, and the stage retries"
}

test_dispatch_requires_plain_task_id() {
  local dir=$TMP_ROOT/plainid
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  local pid rc out
  pid=$(start_stub "$dir")
  bash "$LOOP" init --task plainid --objective-file "$TMP_ROOT/objective.txt" >/dev/null
  bash "$LOOP" consult --stage audit --task plainid >/dev/null
  stop_stub "$pid"
  out=$(bash "$LOOP" dispatch --stage audit --task plainid -- --mode local-only mytask myproj 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a flags-first dispatch must refuse before launch"
  assert_contains "$out" "plain task id" "a non-plain first arg must be refused with a clear error"
  out=$(bash "$LOOP" dispatch --stage audit --task plainid -- plainid=repo myproj 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a batch-pair first arg must refuse before launch"
  assert_contains "$out" "plain task id" "a batch first arg must be refused with a clear error"
  [ "$(loop_phase plainid)" = "audit-dispatch" ] || fail "a refused dispatch must change no state"
  [ ! -f "$dir/argv.txt" ] || fail "a refused dispatch must launch nothing"
  [ ! -f "$dir/send.txt" ] || fail "a refused dispatch must deliver no prompt"
  env -u FM_HOME bash "$LOOP" dispatch --stage audit --task plainid -- plainid myproj --mode local-only --yolo off >/dev/null; rc=$?
  [ "$rc" -eq 0 ] || fail "a plain leading task id must dispatch"
  [ "$(loop_phase plainid)" = "audit-worker" ] || fail "the plain-id dispatch must advance to audit-worker"
  assert_contains "$(cat "$dir/send.txt")" "target: plainid" "the handoff must target the leading plain task id"
  assert_contains "$(cat "$dir/send-env.txt")" "home: $ROOT" "fm-send must receive an explicit FM_HOME even when the caller exports none"
  assert_contains "$(cat "$dir/send-env.txt")" "state: $HOME_DIR/state" "fm-send must receive the loop's state root"
  pass "dispatch refuses option-leading and batch first args, and hands off with an explicit FM_HOME"
}

test_wrong_phase_refuses() {
  local dir=$TMP_ROOT/wrongphase
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  bash "$LOOP" init --task wrongphase --objective-file "$TMP_ROOT/objective.txt" >/dev/null
  printf 'x\n' > "$dir/r.txt"
  local rc
  bash "$LOOP" record-result --task wrongphase --file "$dir/r.txt" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a wrong-phase record-result must refuse"
  [ "$(loop_phase wrongphase)" = "audit-consult" ] || fail "a wrong-phase call must change no state"
  bash "$LOOP" dispatch --stage plan --task wrongphase -- t p --mode local-only --yolo off >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a wrong-phase dispatch must refuse"
  [ "$(loop_phase wrongphase)" = "audit-consult" ] || fail "a refused dispatch must change no state"
  pass "wrong-phase calls refuse with no state change"
}

test_worker_never_touches_bridge() {
  local dir=$TMP_ROOT/boundary
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  local pid
  pid=$(start_stub "$dir")
  bash "$LOOP" init --task boundary --objective-file "$TMP_ROOT/objective.txt" >/dev/null
  bash "$LOOP" consult --stage audit --task boundary >/dev/null
  stop_stub "$pid"
  local out rc
  out=$(bash "$LOOP" dispatch --stage audit --task boundary -- t p codex-chatgpt-web 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a dispatch carrying a bridge reference must refuse"
  assert_contains "$out" "references the bridge" "the guard refusal must name the bridge reference"
  [ "$(loop_phase boundary)" = "audit-dispatch" ] || fail "a guard refusal must change no state"
  [ ! -f "$dir/argv.txt" ] || fail "a guard refusal must launch nothing"
  bash "$LOOP" dispatch --stage audit --task boundary -- t p --mode local-only --yolo off >/dev/null
  grep -Eiq 'CHATGPT_WEB_BRIDGE_URL|codex-chatgpt-web|17841|17911|fm-chatgpt-(consult|bridge)' "$dir/argv.txt" && fail "spawn argv must carry no bridge reference"
  grep -Ev '^(STUB_SPAWN_DIR|FM_CHATGPT_LOOP_SPAWN|FM_TASK_ID|FM_TASK_INBOX|GOTMPDIR|GIT_CONFIG_VALUE_)=' "$dir/env.txt" | grep -Eiq 'CHATGPT_WEB_BRIDGE_URL|codex-chatgpt-web|17841|17911|FM_CHATGPT_LOOP|fm-chatgpt-(consult|bridge)' && fail "spawn environment must carry no bridge reference"
  local out2 rc2
  out2=$(bash "$LOOP" bridge status 2>&1); rc2=$?
  [ "$rc2" -ne 0 ] || fail "bridge status must exit nonzero while no bridge is running"
  assert_contains "$out2" "bridge" "bridge status must report the bridge, not the worker"
  pass "bridge lifecycle stays Firstmate-owned: dispatch refuses a bridge-referencing arg before launch and reports the bridge itself"
}

test_task_id_validated_before_state_paths() {
  local dir=$TMP_ROOT/badid rc out
  mkdir -p "$dir"
  new_task_files
  make_spawn_stub "$dir"
  out=$(bash "$LOOP" init --task .. --objective-file "$TMP_ROOT/objective.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "init must refuse a path-escaping task id"
  assert_contains "$out" "invalid task id" "a path-escaping task id must be refused with a clear error"
  [ ! -f "$HOME_DIR/chatgpt-loop.json" ] || fail "a refused init must write no state outside the data root"
  printf 'x\n' > "$dir/r.txt"
  out=$(bash "$LOOP" record-result --task a/../victim --file "$dir/r.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "record-result must refuse a task id escaping into a sibling task"
  assert_contains "$out" "invalid task id" "an escaping task id must be refused at the state boundary"
  [ ! -f "$HOME_DIR/data/victim/chatgpt-loop.json" ] || fail "a refused record must touch no sibling task state"
  out=$(bash "$LOOP" status --task fm/x 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "status must refuse a nested non-task id"
  assert_contains "$out" "invalid task id" "a nested non-task id must be refused with a clear error"
  pass "every subcommand validates the task id before building state paths"
}

test_trailing_option_requires_value() {
  local dir=$TMP_ROOT/noval spec rc pid
  mkdir -p "$dir"
  for spec in "status --task" "consult --stage" "init --objective-file" "next-round --task" "record-findings --file" "record-result --file" "record-worker-failure --reason" "dispatch --stage"; do
    # shellcheck disable=SC2086
    bash "$LOOP" $spec >"$dir/noval.out" 2>&1 &
    pid=$!
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "a trailing valueless option must exit promptly instead of hanging: $spec"
    fi
    wait "$pid"; rc=$?
    [ "$rc" -ne 0 ] || fail "a trailing valueless option must exit nonzero: $spec"
    assert_contains "$(cat "$dir/noval.out")" "needs a value" "a trailing valueless option must name the missing value: $spec"
  done
  pass "a trailing valueless option refuses with a usage error instead of hanging"
}

test_bridge_pid_identity() {
  local daemon="$HOME_DIR/tools/codex-chatgpt-web"
  mkdir -p "$daemon/bin" "$HOME_DIR/state"
  cat > "$daemon/bin/codex-chatgpt-web" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
SH
  chmod +x "$daemon/bin/codex-chatgpt-web"
  local real_home=$HOME
  export HOME="$HOME_DIR"
  local out rc pid dead
  sleep 30 &
  local foreign=$!
  printf '%s\n' "$foreign" > "$HOME_DIR/state/chatgpt-loop-bridge.pid"
  out=$(bash "$LOOP" bridge stop 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge stop must refuse a foreign pid in the pidfile"
  assert_contains "$out" "foreign" "bridge stop must report the foreign pid"
  kill -0 "$foreign" 2>/dev/null || fail "bridge stop must never kill a foreign process"
  [ ! -f "$HOME_DIR/state/chatgpt-loop-bridge.pid" ] || fail "bridge stop must clear a foreign pidfile"
  bash -c 'trap "exit 0" TERM; while :; do sleep 0.1; done' src/cli.ts &
  local mentions=$!
  printf '%s\n' "$mentions" > "$HOME_DIR/state/chatgpt-loop-bridge.pid"
  out=$(bash "$LOOP" bridge stop 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge stop must refuse a pid whose command merely mentions src/cli.ts outside the daemon dir"
  assert_contains "$out" "foreign" "bridge stop must report the lookalike pid as foreign"
  kill -0 "$mentions" 2>/dev/null || fail "bridge stop must never kill a lookalike foreign process"
  [ ! -f "$HOME_DIR/state/chatgpt-loop-bridge.pid" ] || fail "bridge stop must clear a lookalike pidfile"
  kill "$mentions" 2>/dev/null || true
  out=$(bash "$LOOP" bridge start 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "bridge start must not be blocked by a live foreign pid: $out"
  pid=$(cat "$HOME_DIR/state/chatgpt-loop-bridge.pid")
  [ -n "$pid" ] && [ "$pid" != "$foreign" ] || fail "bridge start must record its own daemon pid"
  out=$(bash "$LOOP" bridge start 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge start must refuse while its own daemon runs"
  assert_contains "$out" "already started by this loop" "bridge start must name the loop-owned instance"
  out=$(bash "$LOOP" bridge stop 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "bridge stop must stop the loop-owned instance: $out"
  assert_contains "$out" "stopped" "bridge stop must report stopping the loop-owned instance"
  dead=0
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || { dead=1; break; }
    sleep 0.1
  done
  [ "$dead" -eq 1 ] || fail "bridge stop must kill the loop-owned instance"
  [ ! -f "$HOME_DIR/state/chatgpt-loop-bridge.pid" ] || fail "bridge stop must clear the pidfile"
  kill "$foreign" 2>/dev/null || true
  export HOME="$real_home"
  pass "bridge start and stop verify the recorded pid against the daemon-dir entrypoints before refusing or killing"
}

test_bridge_verbs_refused() {
  local out rc
  out=$(bash "$LOOP" bridge setup 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge setup must refuse"
  out=$(bash "$LOOP" bridge start login 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge start with setup verbs must refuse"
  out=$(bash "$LOOP" bridge start auth 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge start with an arbitrary extra argument must refuse"
  out=$(bash "$LOOP" bridge stop auth 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge stop with an arbitrary extra argument must refuse"
  pass "bridge install and setup verbs and any extra start/stop argument refuse"
}

test_full_loop_happy_path
test_plan_consult_carries_explicit_context
test_consult_failure_is_retryable
test_worker_failure_recorded
test_spawn_failure_recorded
test_dispatch_requires_plain_task_id
test_wrong_phase_refuses
test_task_id_validated_before_state_paths
test_trailing_option_requires_value
test_worker_never_touches_bridge
test_bridge_pid_identity
test_bridge_verbs_refused
