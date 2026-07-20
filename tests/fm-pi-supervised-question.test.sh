#!/usr/bin/env bash
# End-to-end behavior tests for the Firstmate-owned Pi supervised-question bridge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-supervised-question.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
BRIDGE="$ROOT/bin/fm-pi-ask-bridge.sh"
ANSWER="$ROOT/bin/fm-pi-answer.sh"
RECOVER="$ROOT/bin/fm-pi-question-recover.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"
LIVE_PIDS=()

cleanup_processes() {
  local pid command
  for pid in "${LIVE_PIDS[@]:-}"; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    command=$(ps -o command= -p "$pid" 2>/dev/null || true)
    case "$command" in
      *fm-pi-ask-bridge.sh*|*owner-wrapper.sh*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
  fm_test_cleanup
}
trap cleanup_processes EXIT

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

forget_pid() {
  local forgotten=$1 pid existing
  existing="${LIVE_PIDS[*]:-}"
  LIVE_PIDS=()
  for pid in $existing; do
    [ "$pid" = "$forgotten" ] || LIVE_PIDS+=("$pid")
  done
}

make_home() {
  local name=$1 task_id=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf 'harness=pi\n' > "$home/state/$task_id.meta"
  printf '%s\n' "$home"
}

make_request() {
  local destination=$1 task_id=$2 call_id=$3 deadline_offset=${4:-30} created deadline
  created=$(jq -nr 'now | floor | todateiso8601')
  deadline=$(jq -nr --argjson offset "$deadline_offset" 'now + $offset | floor | todateiso8601')
  jq -cnS \
    --arg taskId "$task_id" \
    --arg callId "$call_id" \
    --arg createdAt "$created" \
    --arg deadline "$deadline" \
    '{
      protocolVersion: 1,
      taskId: $taskId,
      callId: $callId,
      createdAt: $createdAt,
      deadline: $deadline,
      questions: [
        {
          id: "route",
          header: "Route",
          question: "Which route should continue?",
          options: [
            {label: "Direct PR", description: "Open a direct pull request."},
            {label: "No mistakes", description: "Run the full validation pipeline."}
          ]
        }
      ]
    }' > "$destination"
}

wait_for_file() {
  local file=$1 attempts=${2:-200} count=0
  while [ "$count" -lt "$attempts" ]; do
    [ -f "$file" ] && return 0
    sleep 0.02
    count=$((count + 1))
  done
  fail "timed out waiting for $file"
}

wait_for_grep() {
  local needle=$1 file=$2 attempts=${3:-200} count=0
  while [ "$count" -lt "$attempts" ]; do
    if [ -f "$file" ] && grep -F -- "$needle" "$file" >/dev/null; then
      return 0
    fi
    sleep 0.02
    count=$((count + 1))
  done
  fail "timed out waiting for '$needle' in $file"
}

wait_for_process() {
  local pid=$1 timeout_steps=${2:-250} count=0 status
  while kill -0 "$pid" 2>/dev/null; do
    [ "$count" -lt "$timeout_steps" ] || fail "process $pid did not exit"
    sleep 0.02
    count=$((count + 1))
  done
  wait "$pid" 2>/dev/null
  status=$?
  forget_pid "$pid"
  return "$status"
}

start_bridge() {
  local home=$1 task_id=$2 input=$3 output=$4 error=$5
  FM_HOME="$home" \
    FM_TASK_ID="$task_id" \
    FM_INTERACTION_MODE=supervised \
    FM_ASK_BRIDGE="$BRIDGE" \
    FM_PI_ASK_POLL_SECONDS=0.02 \
    "$BRIDGE" < "$input" > "$output" 2> "$error" &
  BRIDGE_PID=$!
  LIVE_PIDS+=("$BRIDGE_PID")
}

answer_json() {
  local label=$1
  jq -cn --arg label "$label" '{answers: [{questionId: "route", selectedLabel: $label}]}'
}

test_answer_resumes_same_tool_call() {
  local task_id=crew-question call_id=call-one home input output error request response resolution out open
  home=$(make_home answer "$task_id")
  input="$home/input.json"
  output="$home/output.json"
  error="$home/error.log"
  request="$home/state/questions/$task_id/$call_id.request.json"
  response="$home/state/questions/$task_id/$call_id.response.json"
  resolution="$home/state/questions/$task_id/$call_id.resolution.json"
  make_request "$input" "$task_id" "$call_id"

  start_bridge "$home" "$task_id" "$input" "$output" "$error"
  wait_for_file "$request"
  wait_for_file "$home/state/$task_id.status"
  assert_grep "needs-decision: Pi question request state/questions/$task_id/$call_id.request.json [key=ask-$call_id]" \
    "$home/state/$task_id.status" "bridge did not publish the bounded decision wake"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$home/state/$task_id.status")
  assert_contains "$open" "ask-$call_id" "status fold did not retain the Pi call identity"
  [ "$(file_mode "$home/state/questions")" = 700 ] || fail "question root is not mode 0700"
  [ "$(file_mode "$request")" = 600 ] || fail "request is not mode 0600"

  answer_json "No mistakes" | FM_HOME="$home" "$ANSWER" "$task_id" "$call_id" >/dev/null \
    || fail "guarded Firstmate answer failed"
  wait_for_process "$BRIDGE_PID" || fail "bridge did not complete after a valid answer"
  out=$(cat "$output")
  [ "$out" = '{"answers":[{"questionId":"route","selectedLabel":"No mistakes"}]}' ] || fail "bridge returned the wrong tool result: $out"
  [ ! -s "$error" ] || fail "successful bridge wrote an error: $(cat "$error")"
  assert_present "$response" "guarded helper did not publish the response"
  [ "$(jq -r '.status' "$resolution")" = answered ] || fail "bridge did not record answered resolution"
  assert_grep "resolved: Pi question answered [key=ask-$call_id]" \
    "$home/state/$task_id.status" "bridge did not append the matching resolved event"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$home/state/$task_id.status")
  [ -z "$open" ] || fail "matching Pi resolution did not close the keyed decision: $open"

  set +e
  out=$(answer_json "No mistakes" | FM_HOME="$home" "$ANSWER" "$task_id" "$call_id" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "guarded helper accepted a stale duplicate answer"
  assert_contains "$out" "already resolved" "stale duplicate answer lacked a clear refusal"
  grep -vF "resolved: Pi question answered [key=ask-$call_id]" "$home/state/$task_id.status" > "$home/status-without-resolution"
  mv "$home/status-without-resolution" "$home/state/$task_id.status"
  FM_HOME="$home" "$RECOVER" "$task_id" || fail "recovery could not repair a missing terminal status event"
  [ "$(grep -Fc "resolved: Pi question answered [key=ask-$call_id]" "$home/state/$task_id.status")" = 1 ] \
    || fail "recovery did not restore exactly one matching resolved event"
  set +e
  pass "Pi bridge publishes a crew question, accepts one guarded answer, returns exact tool JSON, and resolves once"
}

test_malformed_answers_fail_boundedly() {
  local task_id=malformed call_id=bad-direct home input output error request response out status
  home=$(make_home malformed "$task_id")
  input="$home/input.json"
  output="$home/output.json"
  error="$home/error.log"
  request="$home/state/questions/$task_id/$call_id.request.json"
  response="$home/state/questions/$task_id/$call_id.response.json"
  make_request "$input" "$task_id" "$call_id"
  start_bridge "$home" "$task_id" "$input" "$output" "$error"
  wait_for_file "$request"

  set +e
  out=$(answer_json "Missing label" | FM_HOME="$home" "$ANSWER" "$task_id" "$call_id" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "guarded helper accepted an unlisted option label"
  assert_contains "$out" "exactly one listed label" "malformed helper answer lacked a clear refusal"
  assert_absent "$response" "rejected helper answer still published a response"

  jq -cn '{protocolVersion: 1, taskId: "malformed", callId: "bad-direct", answeredAt: "not-a-time", answers: []}' > "$response"
  chmod 0600 "$response"
  set +e
  wait_for_process "$BRIDGE_PID"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "bridge accepted a malformed direct response"
  assert_grep "ASK_USER_MALFORMED_RESPONSE" "$error" "bridge did not fail with the malformed-response code"
  [ "$(jq -r '.status' "$home/state/questions/$task_id/$call_id.resolution.json")" = invalid-response ] || fail "bridge did not terminally resolve a malformed response"
  pass "guarded and direct malformed answers fail without leaving the tool call polling"
}

test_process_death_recovery_and_reissue() {
  local task_id=recovery old_call=old-call new_call=new-call home old_input old_output old_error old_request out status
  home=$(make_home recovery "$task_id")
  old_input="$home/old-input.json"
  old_output="$home/old-output.json"
  old_error="$home/old-error.log"
  old_request="$home/state/questions/$task_id/$old_call.request.json"
  make_request "$old_input" "$task_id" "$old_call" 60
  start_bridge "$home" "$task_id" "$old_input" "$old_output" "$old_error"
  wait_for_file "$old_request"

  kill -KILL "$BRIDGE_PID"
  wait "$BRIDGE_PID" 2>/dev/null || true
  forget_pid "$BRIDGE_PID"
  FM_HOME="$home" "$RECOVER" "$task_id" || fail "recovery helper could not abandon a dead bridge"
  [ "$(jq -r '.status' "$home/state/questions/$task_id/$old_call.resolution.json")" = abandoned ] || fail "dead bridge request was not marked abandoned"
  set +e
  out=$(answer_json "Direct PR" | FM_HOME="$home" "$ANSWER" "$task_id" "$old_call" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "late answer was accepted after process death"
  assert_contains "$out" "already resolved" "late answer refusal did not identify stale resolution"

  make_request "$home/new-input.json" "$task_id" "$new_call" 60
  start_bridge "$home" "$task_id" "$home/new-input.json" "$home/new-output.json" "$home/new-error.log"
  wait_for_file "$home/state/questions/$task_id/$new_call.request.json"
  answer_json "Direct PR" | FM_HOME="$home" "$ANSWER" "$task_id" "$new_call" >/dev/null \
    || fail "reissued question under a new call ID was not answerable"
  wait_for_process "$BRIDGE_PID" || fail "reissued question did not resume"
  [ "$(cat "$home/new-output.json")" = '{"answers":[{"questionId":"route","selectedLabel":"Direct PR"}]}' ] || fail "reissued question returned the wrong tool result"

  set +e
  FM_HOME="$home" FM_TASK_ID="$task_id" FM_INTERACTION_MODE=supervised FM_ASK_BRIDGE="$BRIDGE" \
    "$BRIDGE" < "$home/new-input.json" > "$home/reused-output" 2> "$home/reused-error"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "bridge accepted a reused call ID"
  assert_grep "ASK_USER_STALE_CALL" "$home/reused-error" "reused call ID lacked a stable refusal"
  pass "process death abandons the old call, rejects late answers, and permits only a new-call reissue"
}

test_owner_death_timeout_and_cancellation() {
  local task_id=terminal home wrapper owner_pid bridge_pid status count
  home=$(make_home terminal "$task_id")

  make_request "$home/owner-input.json" "$task_id" owner-death 30
  wrapper="$home/owner-wrapper.sh"
  cat > "$wrapper" <<'SH'
#!/usr/bin/env bash
"$BRIDGE" < "$INPUT" > "$OUTPUT" 2> "$ERROR" &
child=$!
printf '%s\n' "$child" > "$BRIDGE_PID_FILE"
wait "$child"
SH
  chmod +x "$wrapper"
  env FM_HOME="$home" FM_TASK_ID="$task_id" FM_INTERACTION_MODE=supervised FM_ASK_BRIDGE="$BRIDGE" \
    FM_PI_ASK_POLL_SECONDS=0.02 BRIDGE="$BRIDGE" INPUT="$home/owner-input.json" \
    OUTPUT="$home/owner-output" ERROR="$home/owner-error" BRIDGE_PID_FILE="$home/owner-bridge.pid" \
    "$wrapper" &
  owner_pid=$!
  LIVE_PIDS+=("$owner_pid")
  wait_for_file "$home/state/questions/$task_id/owner-death.request.json"
  wait_for_file "$home/owner-bridge.pid"
  bridge_pid=$(cat "$home/owner-bridge.pid")
  LIVE_PIDS+=("$bridge_pid")
  kill -TERM "$owner_pid"
  wait "$owner_pid" 2>/dev/null || true
  forget_pid "$owner_pid"
  wait_for_file "$home/state/questions/$task_id/owner-death.resolution.json"
  count=0
  while kill -0 "$bridge_pid" 2>/dev/null && [ "$count" -lt 200 ]; do
    sleep 0.02
    count=$((count + 1))
  done
  forget_pid "$bridge_pid"
  [ "$(jq -r '.status' "$home/state/questions/$task_id/owner-death.resolution.json")" = abandoned ] || fail "owner process death did not abandon the pending request"
  assert_grep "ASK_USER_ABANDONED" "$home/owner-error" "owner death lacked the stable abandoned error"

  make_request "$home/timeout-input.json" "$task_id" timeout-call 1
  start_bridge "$home" "$task_id" "$home/timeout-input.json" "$home/timeout-output" "$home/timeout-error"
  set +e
  wait_for_process "$BRIDGE_PID" 300
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expired question exited successfully"
  [ "$(jq -r '.status' "$home/state/questions/$task_id/timeout-call.resolution.json")" = timed-out ] || fail "expired question did not record timed-out resolution"

  make_request "$home/cancel-input.json" "$task_id" cancel-call 30
  start_bridge "$home" "$task_id" "$home/cancel-input.json" "$home/cancel-output" "$home/cancel-error"
  wait_for_file "$home/state/questions/$task_id/cancel-call.request.json"
  wait_for_grep "needs-decision: Pi question request state/questions/$task_id/cancel-call.request.json [key=ask-cancel-call]" "$home/state/$task_id.status"
  kill -TERM "$BRIDGE_PID"
  set +e
  wait_for_process "$BRIDGE_PID"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "cancelled question exited successfully"
  [ "$(jq -r '.status' "$home/state/questions/$task_id/cancel-call.resolution.json")" = cancelled ] || fail "abort signal did not record cancelled resolution"
  assert_grep "resolved: Pi question was cancelled [key=ask-cancel-call]" \
    "$home/state/$task_id.status" "cancelled question did not close its keyed status"

  make_request "$home/teardown-input.json" "$task_id" teardown-call 30
  start_bridge "$home" "$task_id" "$home/teardown-input.json" "$home/teardown-output" "$home/teardown-error"
  wait_for_file "$home/state/questions/$task_id/teardown-call.request.json"
  wait_for_grep "needs-decision: Pi question request state/questions/$task_id/teardown-call.request.json [key=ask-teardown-call]" "$home/state/$task_id.status"
  FM_HOME="$home" "$RECOVER" --cancel "$task_id" || fail "teardown cancellation could not publish resolution"
  set +e
  wait_for_process "$BRIDGE_PID"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "teardown-cancelled bridge exited successfully"
  assert_grep "ASK_USER_CANCELLED" "$home/teardown-error" "teardown cancellation did not stop the blocked bridge"
  pass "owner death, timeout, and cancellation all terminate with durable resolution"
}

test_startup_recovery_respects_read_only_mode() {
  local task_id=startup call_id=startup-call home input output error request
  home=$(make_home startup "$task_id")
  input="$home/input.json"
  output="$home/output"
  error="$home/error"
  request="$home/state/questions/$task_id/$call_id.request.json"
  make_request "$input" "$task_id" "$call_id" 60
  start_bridge "$home" "$task_id" "$input" "$output" "$error"
  wait_for_file "$request"
  kill -KILL "$BRIDGE_PID"
  wait "$BRIDGE_PID" 2>/dev/null || true
  forget_pid "$BRIDGE_PID"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_absent "$home/state/questions/$task_id/$call_id.resolution.json" \
    "detect-only bootstrap mutated a pending Pi question"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  [ "$(jq -r '.status' "$home/state/questions/$task_id/$call_id.resolution.json")" = abandoned ] \
    || fail "lock-owning bootstrap did not recover a dead pending Pi question"
  pass "startup recovery abandons dead Pi calls only in the mutating lock-owning path"
}

test_recovery_honors_state_override() {
  local task_id=override call_id=override-call home state request resolution
  home="$TMP_ROOT/override-home"
  state="$TMP_ROOT/override-state"
  request="$state/questions/$task_id/$call_id.request.json"
  resolution="$state/questions/$task_id/$call_id.resolution.json"
  mkdir -p "$home" "$state/questions/$task_id"
  printf 'harness=pi\n' > "$state/$task_id.meta"
  make_request "$request" "$task_id" "$call_id"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$RECOVER" --cancel "$task_id" \
    || fail "recovery ignored the effective state override"
  [ "$(jq -r '.status' "$resolution")" = cancelled ] \
    || fail "state-override recovery did not cancel the pending request"
  assert_grep "resolved: Pi question was cancelled [key=ask-$call_id]" \
    "$state/$task_id.status" "state-override recovery did not append the matching resolution"
  assert_absent "$home/state" "state-override recovery wrote to the default home state"
  pass "recovery and teardown use the effective state directory"
}

test_launch_envelope_wiring() {
  local source teardown
  source=$(cat "$ROOT/bin/fm-spawn.sh")
  teardown=$(cat "$ROOT/bin/fm-teardown.sh")
  assert_contains "$source" "FM_INTERACTION_MODE=supervised FM_HOME=" "Pi crew launch lacks supervised mode and home"
  assert_contains "$source" "FM_TASK_ID=\$sq_task_id" "Pi crew launch lacks the task ID"
  assert_contains "$source" "FM_ASK_BRIDGE=\$sq_ask_bridge" "Pi crew launch lacks the absolute bridge helper"
  # shellcheck disable=SC2016
  assert_contains "$source" '"$HARNESS" = pi ] && [ "$KIND" != secondmate' "Phase 5 launch variables escaped Pi crew scope"
  # shellcheck disable=SC2016
  assert_contains "$teardown" 'fm-pi-question-recover.sh" --cancel "$ID"' "teardown does not cancel a pending Pi question"
  # shellcheck disable=SC2016
  assert_contains "$teardown" '[ "$HARNESS" = pi ]' "teardown cancellation escaped Pi crew scope"
  # shellcheck disable=SC2016
  assert_contains "$teardown" 'rm -rf "$STATE/questions/$ID"' "teardown does not remove terminal Pi question state"
  pass "Pi launch, startup, and teardown wiring preserve the supervised-question lifecycle"
}

test_answer_resumes_same_tool_call
test_malformed_answers_fail_boundedly
test_process_death_recovery_and_reissue
test_owner_death_timeout_and_cancellation
test_startup_recovery_respects_read_only_mode
test_recovery_honors_state_override
test_launch_envelope_wiring
