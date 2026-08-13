#!/usr/bin/env bash
# Behavioral coverage for the AIME-only cloud research executor.
#
# Every provider interaction uses the fake bytedcli below. The suite drives the
# real dispatch, state, process-event, report, restart, and cancellation paths;
# it never creates a real AIME session or writes a Feishu document.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-aime-cloud-worker)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
BASE_PATH=$PATH
SPACE_ID=11111111-1111-4111-8111-111111111111
SESSION_ID=22222222-2222-4222-8222-222222222222
MESSAGE_ID=message-3333
AIME="$ROOT/bin/fm-cloud-research-aime.sh"
ADAPTER="$ROOT/bin/fm-procevent-aime.sh"
DISPATCH="$ROOT/bin/fm-task-dispatch.sh"

TRACKED_HOMES_FILE="$TMP_ROOT/tracked-homes"
: >"$TRACKED_HOMES_FILE"

cleanup_aime() {
  local home
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done <"$TRACKED_HOMES_FILE"
  fm_test_cleanup
}
trap cleanup_aime EXIT

new_home() { # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  printf '%s\n' "$home" >>"$TRACKED_HOMES_FILE"
  printf '%s\n' "$home"
}

write_config() { # <home> <enabled>
  cat >"$1/config/aime-cloud-worker" <<EOF
schema=fm-aime-cloud-worker-config.v1
enabled=$2
site=cn
space_id=$SPACE_ID
identity=user
sandbox_verified_version=0.124.0
sandbox_verified_at=2026-08-14T00:00:00Z
sandbox_verification=disposable-session-readback
EOF
  chmod 0600 "$1/config/aime-cloud-worker"
}

new_task() { # <home> <id> [instruction]
  local home=$1 id=$2 instruction=${3:-"Research the requested topic and return a cited report."}
  mkdir -p "$home/data/$id"
  printf '# Brief for %s\n' "$id" >"$home/data/$id/brief.md"
  printf '%s\n' "$instruction" >"$home/data/$id/instructions.txt"
  chmod 0600 "$home/data/$id/instructions.txt"
}

state_file() {
  printf '%s/state/cloud-tasks/%s/state.json\n' "$1" "$2"
}

phase_of() {
  jq -r '.phase' "$(state_file "$1" "$2")"
}

wait_phase() { # <home> <id> <phase>
  local home=$1 id=$2 expected=$3 tries=${4:-200} actual=''
  while [ "$tries" -gt 0 ]; do
    if [ -f "$(state_file "$home" "$id")" ]; then
      actual=$(phase_of "$home" "$id")
      [ "$actual" = "$expected" ] && return 0
    fi
    sleep 0.05
    tries=$((tries - 1))
  done
  fail "timed out waiting for $id phase=$expected (actual=${actual:-missing})"
}

wait_file() { # <path>
  local path=$1 tries=${2:-200}
  while [ "$tries" -gt 0 ]; do
    [ -s "$path" ] && return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

count_log() { # <log> <fixed-pattern>
  grep -F -c "$2" "$1" 2>/dev/null || true
}

make_fake_bytedcli() { # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat >"$fakebin/bytedcli" <<'SH'
#!/usr/bin/env bash
set -u

log=${FM_AIME_FAKE_LOG:?}
printf '%s\n' "$*" >>"$log"
failure=${FM_AIME_FAKE_FAILURE:-}
space=${FM_AIME_FAKE_SPACE_ID:?}
session=${FM_AIME_FAKE_SESSION_ID:?}
message=${FM_AIME_FAKE_MESSAGE_ID:?}
args=" $* "

success() {
  printf '{"status":"success","data":%s,"error":null}\n' "$1"
}

error() {
  printf '{"status":"error","data":null,"error":{"code":"%s","message":"%s"}}\n' "$1" "$2"
}

case "$args" in
  *" --version "*)
    [ "$failure" != version-unavailable ] || exit 1
    success "{\"version\":\"${FM_AIME_FAKE_VERSION:-0.124.0}\"}"
    ;;
  *" aime space list "*)
    case "$failure" in
      auth) error AUTH_REQUIRED "SSO authentication required"; exit 1 ;;
      unavailable) error HTTP_503 "service unavailable"; exit 1 ;;
      malformed-probe) printf '{'; exit 0 ;;
      unsupported)
        success "{\"spaces\":[{\"id\":\"$space\",\"status\":\"active\",\"permission_actions\":[\"space.read\"]}]}"
        ;;
      *)
        success "{\"spaces\":[{\"id\":\"$space\",\"status\":\"active\",\"permission_actions\":[\"space.read\",\"session.create\"]}]}"
        ;;
    esac
    ;;
  *" aime space get "*)
    success "{\"id\":\"$space\",\"name\":\"test-space\",\"status\":\"active\"}"
    ;;
  *" aime session create "*)
    case "$failure" in
      create-rate) error HTTP_429 "rate limit exceeded"; exit 1 ;;
      create-unavailable) error HTTP_503 "service unavailable"; exit 1 ;;
      create-timeout) exit 124 ;;
      create-malformed) printf '{'; exit 0 ;;
      create-empty) exit 0 ;;
      *) success "{\"id\":\"$session\",\"source_space_id\":\"$space\"}" ;;
    esac
    ;;
  *" aime session send "*)
    case "$failure" in
      send-rate) error HTTP_429 "rate limit exceeded"; exit 1 ;;
      send-timeout) exit 124 ;;
      send-malformed) printf '{'; exit 0 ;;
      *)
        success "{\"session_id\":\"$session\",\"auto_session_created\":false,\"message\":{\"message_id\":\"$message\"}}"
        ;;
    esac
    ;;
  *" aime session replay-events "*)
    case "${FM_AIME_FAKE_REPLAY:-terminal}" in
      block)
        trigger=${FM_AIME_FAKE_TRIGGER:?}
        while [ ! -e "$trigger" ]; do sleep 0.02; done
        ;;
      timeout) exit 124 ;;
      unavailable) error HTTP_503 "service unavailable"; exit 1 ;;
      malformed) printf '{'; exit 0 ;;
      recover)
        marker=${FM_AIME_FAKE_RECOVERY_MARKER:?}
        if [ ! -e "$marker" ]; then
          : >"$marker"
          error HTTP_503 "service unavailable"
          exit 1
        fi
        ;;
    esac
    if [ "${FM_AIME_FAKE_REPLAY:-terminal}" = nonterminal ]; then
      success "{\"session_id\":\"$session\",\"terminal\":false,\"last_event_offset\":4,\"events\":[{\"offset\":4,\"type\":\"progress\"}]}"
    else
      success "{\"session_id\":\"$session\",\"terminal\":true,\"last_event_offset\":9,\"events\":[{\"offset\":9,\"type\":\"terminal\"}]}"
    fi
    ;;
  *" aime session get-output "*)
    case "${FM_AIME_FAKE_OUTPUT_MODE:-success}" in
      unavailable) error HTTP_503 "output unavailable"; exit 1 ;;
      timeout) exit 124 ;;
      malformed) printf '{'; exit 0 ;;
      unfinished) success "{\"session_id\":\"$session\",\"message_id\":\"$message\",\"finished\":false,\"content\":\"\"}" ;;
      wrong-message) success "{\"session_id\":\"$session\",\"message_id\":\"other-message\",\"finished\":true,\"content\":\"wrong\"}" ;;
      *)
        jq -cn \
          --arg session "$session" \
          --arg message "$message" \
          --arg content "${FM_AIME_FAKE_CONTENT:-# Result\n\n- Evidence [1].}" \
          '{status:"success",data:{session_id:$session,message_id:$message,finished:true,content:$content},error:null}'
        ;;
    esac
    ;;
  *" aime session get "*)
    case "${FM_AIME_FAKE_SESSION_MODE:-success}" in
      unavailable) error HTTP_503 "session unavailable"; exit 1 ;;
      timeout) exit 124 ;;
      failed) success "{\"id\":\"$session\",\"status\":\"failed\"}" ;;
      *) success "{\"id\":\"$session\",\"status\":\"${FM_AIME_FAKE_SESSION_STATUS:-completed}\"}" ;;
    esac
    ;;
  *)
    error UNKNOWN_COMMAND "unsupported fake invocation: $*"
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/bytedcli"
  printf '%s\n' "$fakebin"
}

run_aime() { # <home> <fakebin> <args...>
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" \
  FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
  FM_AIME_FAKE_LOG="$home/bytedcli.log" \
  FM_AIME_FAKE_SPACE_ID="$SPACE_ID" \
  FM_AIME_FAKE_SESSION_ID="$SESSION_ID" \
  FM_AIME_FAKE_MESSAGE_ID="$MESSAGE_ID" \
  FM_AIME_FAKE_FAILURE="${FM_AIME_FAKE_FAILURE:-}" \
  FM_AIME_FAKE_REPLAY="${FM_AIME_FAKE_REPLAY:-terminal}" \
  FM_AIME_FAKE_TRIGGER="${FM_AIME_FAKE_TRIGGER:-}" \
  FM_AIME_FAKE_OUTPUT_MODE="${FM_AIME_FAKE_OUTPUT_MODE:-success}" \
  FM_AIME_FAKE_CONTENT="${FM_AIME_FAKE_CONTENT:-}" \
  FM_AIME_FAKE_SESSION_MODE="${FM_AIME_FAKE_SESSION_MODE:-success}" \
  FM_AIME_FAKE_SESSION_STATUS="${FM_AIME_FAKE_SESSION_STATUS:-completed}" \
  FM_AIME_FAKE_VERSION="${FM_AIME_FAKE_VERSION:-0.124.0}" \
  FM_AIME_FAKE_RECOVERY_MARKER="${FM_AIME_FAKE_RECOVERY_MARKER:-}" \
  PATH="$fakebin:$BASE_PATH" \
    "$AIME" "$@"
}

dispatch_aime() { # <home> <fakebin> <id> [extra args...]
  local home=$1 fakebin=$2 id=$3
  shift 3
  FM_HOME="$home" \
  FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
  FM_AIME_FAKE_LOG="$home/bytedcli.log" \
  FM_AIME_FAKE_SPACE_ID="$SPACE_ID" \
  FM_AIME_FAKE_SESSION_ID="$SESSION_ID" \
  FM_AIME_FAKE_MESSAGE_ID="$MESSAGE_ID" \
  FM_AIME_FAKE_FAILURE="${FM_AIME_FAKE_FAILURE:-}" \
  FM_AIME_FAKE_REPLAY="${FM_AIME_FAKE_REPLAY:-terminal}" \
  FM_AIME_FAKE_TRIGGER="${FM_AIME_FAKE_TRIGGER:-}" \
  FM_AIME_FAKE_OUTPUT_MODE="${FM_AIME_FAKE_OUTPUT_MODE:-success}" \
  FM_AIME_FAKE_CONTENT="${FM_AIME_FAKE_CONTENT:-}" \
  FM_AIME_FAKE_SESSION_MODE="${FM_AIME_FAKE_SESSION_MODE:-success}" \
  FM_AIME_FAKE_SESSION_STATUS="${FM_AIME_FAKE_SESSION_STATUS:-completed}" \
  FM_AIME_FAKE_VERSION="${FM_AIME_FAKE_VERSION:-0.124.0}" \
  FM_AIME_FAKE_RECOVERY_MARKER="${FM_AIME_FAKE_RECOVERY_MARKER:-}" \
  PATH="$fakebin:$BASE_PATH" \
    "$DISPATCH" cloud-worker/aime "$id" \
      --instructions "$home/data/$id/instructions.txt" "$@"
}

test_probe_and_disabled_gate() {
  local home fakebin out rc=0 long_id alias
  home=$(new_home probe-disabled)
  fakebin=$(make_fake_bytedcli "$home")
  : >"$home/bytedcli.log"

  out=$(run_aime "$home" "$fakebin" probe --site cn --space-id "$SPACE_ID") \
    || fail "read-only AIME probe should pass against the fixture"
  printf '%s' "$out" | jq -e '
    .outcome == "ready"
    and .provider == "aime"
    and .bytedcli_version == "0.124.0"
  ' >/dev/null || fail "probe did not return the bounded ready contract: $out"
  [ "$(count_log "$home/bytedcli.log" "aime session create")" -eq 0 ] \
    || fail "read-only probe issued a remote write"

  new_task "$home" disabled
  : >"$home/bytedcli.log"
  dispatch_aime "$home" "$fakebin" disabled >"$home/out" 2>"$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "missing config enabled AIME dispatch"
  [ ! -e "$home/state/disabled.meta" ] || fail "disabled dispatch created task metadata"
  [ ! -s "$home/bytedcli.log" ] || fail "disabled dispatch reached bytedcli"

  write_config "$home" false
  rc=0
  dispatch_aime "$home" "$fakebin" disabled >"$home/out" 2>"$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "enabled=false config allowed AIME dispatch"
  [ ! -s "$home/bytedcli.log" ] || fail "enabled=false dispatch reached bytedcli"

  write_config "$home" true
  alias="$home/config/aime-cloud-worker.alias"
  ln "$home/config/aime-cloud-worker" "$alias"
  rc=0
  dispatch_aime "$home" "$fakebin" disabled >"$home/hardlink.out" 2>"$home/hardlink.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked config enabled AIME dispatch"
  [ ! -s "$home/bytedcli.log" ] || fail "hardlinked config reached bytedcli"
  rm -f "$alias"

  write_config "$home" true
  alias="$home/data/disabled/instructions.alias"
  ln "$home/data/disabled/instructions.txt" "$alias"
  rc=0
  dispatch_aime "$home" "$fakebin" disabled >"$home/instruction-hardlink.out" 2>"$home/instruction-hardlink.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked instruction file enabled AIME dispatch"
  [ ! -s "$home/bytedcli.log" ] || fail "hardlinked instruction file reached bytedcli"
  rm -f "$alias"

  long_id=$(printf '%060d' 0)
  new_task "$home" "$long_id"
  rc=0
  dispatch_aime "$home" "$fakebin" "$long_id" >"$home/long-id.out" 2>"$home/long-id.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "task id too long for the canonical AIME source was accepted"
  [ ! -e "$home/state/$long_id.meta" ] || fail "oversized task id created metadata"
  pass "AIME probe is read-only and production dispatch is disabled by default"
}

test_probe_failures_are_distinct() {
  local home fakebin out rc
  home=$(new_home probe-failures)
  fakebin=$(make_fake_bytedcli "$home")
  : >"$home/bytedcli.log"

  rc=0
  out=$(FM_AIME_FAKE_FAILURE=auth run_aime "$home" "$fakebin" probe \
    --site cn --space-id "$SPACE_ID") || rc=$?
  [ "$rc" -ne 0 ] || fail "auth failure was reported ready"
  printf '%s' "$out" | jq -e '.outcome == "unavailable" and .error_class == "auth"' >/dev/null \
    || fail "auth failure classification drifted: $out"

  rc=0
  out=$(FM_AIME_FAKE_FAILURE=unsupported run_aime "$home" "$fakebin" probe \
    --site cn --space-id "$SPACE_ID") || rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported space was reported ready"
  printf '%s' "$out" | jq -e '.outcome == "unsupported" and .error_class == "space-capability"' >/dev/null \
    || fail "unsupported-capability classification drifted: $out"

  rc=0
  out=$(FM_AIME_FAKE_FAILURE=malformed-probe run_aime "$home" "$fakebin" probe \
    --site cn --space-id "$SPACE_ID") || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed probe output was reported ready"
  printf '%s' "$out" | jq -e '.outcome == "unavailable" and .error_class == "cli-failure"' >/dev/null \
    || fail "malformed probe classification drifted: $out"

  rc=0
  out=$(FM_AIME_FAKE_FAILURE=version-unavailable run_aime "$home" "$fakebin" probe \
    --site cn --space-id "$SPACE_ID") || rc=$?
  [ "$rc" -ne 0 ] || fail "unavailable CLI was reported ready"
  printf '%s' "$out" | jq -e '.outcome == "unavailable" and .error_class == "cli-unavailable"' >/dev/null \
    || fail "CLI-unavailable classification drifted: $out"
  pass "AIME probe distinguishes auth, unsupported capability, malformed output, and unavailable CLI"
}

test_sandbox_verification_is_explicit_and_stays_disabled() {
  local home fakebin out rc=0
  home=$(new_home sandbox-verification)
  fakebin=$(make_fake_bytedcli "$home")
  : >"$home/bytedcli.log"

  out=$(run_aime "$home" "$fakebin" sandbox-verify \
    --site cn --space-id "$SPACE_ID" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "sandbox verification ran without explicit disposable-session authorization"
  assert_contains "$out" "requires --authorize-disposable-session" \
    "sandbox verification refusal did not name the required authority"
  [ ! -s "$home/bytedcli.log" ] || fail "unauthorized sandbox verification reached bytedcli"
  [ ! -e "$home/config/aime-cloud-worker" ] \
    || fail "unauthorized sandbox verification wrote config"

  out=$(run_aime "$home" "$fakebin" sandbox-verify \
    --authorize-disposable-session --site cn --space-id "$SPACE_ID") \
    || fail "authorized fake sandbox verification failed"
  assert_contains "$out" "sandbox-verified: bytedcli=0.124.0" \
    "sandbox verification omitted its pinned bytedcli version"
  assert_contains "$out" "config-disabled=true" \
    "sandbox verification did not report its disabled result"
  grep -Fx 'enabled=false' "$home/config/aime-cloud-worker" >/dev/null \
    || fail "sandbox verification enabled production dispatch"
  grep -Fx 'sandbox_verified_version=0.124.0' "$home/config/aime-cloud-worker" >/dev/null \
    || fail "sandbox verification did not pin the installed bytedcli version"
  [ "$(count_log "$home/bytedcli.log" "aime session create")" -eq 1 ] \
    || fail "sandbox verification did not create exactly one disposable session"
  [ "$(count_log "$home/bytedcli.log" "aime session get")" -eq 1 ] \
    || fail "sandbox verification did not read back exactly one disposable session"
  pass "sandbox verification requires explicit authority, reads back one disposable session, and stays disabled"
}

test_dispatch_completion_and_duplicate_replay() {
  local home fakebin trigger out status_count result sequence
  home=$(new_home dispatch-success)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true
  new_task "$home" report-task "SECRET_INSTRUCTION_BYTES research with citations."
  : >"$home/bytedcli.log"
  trigger="$home/complete"

  out=$(FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    dispatch_aime "$home" "$fakebin" report-task) \
    || fail "AIME dispatch failed"
  assert_contains "$out" "submitted: report-task provider=aime session=$SESSION_ID" \
    "dispatch did not return the durable session identity"
  jq -e --arg session "$SESSION_ID" --arg message "$MESSAGE_ID" '
    .phase == "submitted"
    and .session_id == $session
    and .message_id == $message
    and .provider_checkpoint == "waiter-armed"
  ' "$(state_file "$home" report-task)" >/dev/null || fail "submitted state is not durably recoverable"
  grep -Fx 'executor=cloud-worker' "$home/state/report-task.meta" >/dev/null \
    || fail "cloud executor discriminator missing"
  grep -Fx 'provider=aime' "$home/state/report-task.meta" >/dev/null \
    || fail "AIME provider discriminator missing"
  ! grep -Eq '^(window|worktree|harness|backend|endpoint_task_id)=' "$home/state/report-task.meta" \
    || fail \
    "cloud task metadata faked a local endpoint field"
  assert_no_grep 'SECRET_INSTRUCTION_BYTES' "$home/bytedcli.log" \
    "instruction bytes leaked into bytedcli argv"
  grep -E -- '--content-file .*/data/report-task/instructions.txt' "$home/bytedcli.log" >/dev/null \
    || fail \
    "dispatch did not submit through the exact private instruction file"

  out=$(FM_AIME_FAKE_REPLAY=terminal FM_AIME_FAKE_CONTENT='# Live state result' \
    run_aime "$home" "$fakebin" state report-task) \
    || fail "provider-aware state read failed"
  assert_contains "$out" "source: cloud-readback" "cloud current state did not use provider readback"
  assert_contains "$out" "terminal=true" "cloud current state did not reconcile replay terminal truth"
  assert_contains "$out" "output-ready=true" "cloud current state did not reconcile output truth"

  touch "$trigger"
  wait_phase "$home" report-task terminal-success
  wait_file "$home/data/report-task/report.md" || fail "AIME completion did not create a report"
  assert_grep '## Provider Result' "$home/data/report-task/report.md" "provider result wrapper missing"
  assert_grep 'Evidence Boundary' "$home/data/report-task/report.md" "evidence boundary missing"
  assert_no_grep 'SECRET_INSTRUCTION_BYTES' "$home/data/report-task/report.md" \
    "private instruction bytes leaked into the result wrapper"
  wait_file "$home/state/.wake-queue" || fail "AIME completion did not wake Firstmate"
  assert_grep 'procevent aime aime-report-task' "$home/state/.wake-queue" \
    "AIME completion did not use the generic process-event wake"

  result=$(find "$home/state/procevent-inbox" -name 'aime-report-task.*.result' | head -1)
  [ -n "$result" ] || fail "AIME completion result was not durably captured"
  sequence=${result##*/}
  sequence=${sequence%.result}
  sequence=${sequence##*.}
  status_count=$(grep -F -c 'done: AIME cloud research complete' "$home/state/report-task.status")
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" handle report-task "$sequence" "$result" >/dev/null \
    || fail "duplicate AIME result was not safely replayable"
  [ "$(grep -F -c 'done: AIME cloud research complete' "$home/state/report-task.status")" -eq "$status_count" ] \
    || fail "duplicate AIME handling duplicated the terminal event"

  out=$(dispatch_aime "$home" "$fakebin" report-task 2>&1) && \
    fail "restart dispatch duplicated a submitted cloud task: $out"
  [ "$(count_log "$home/bytedcli.log" "aime session create")" -eq 1 ] \
    || fail "restart dispatch issued a second create"
  [ "$(count_log "$home/bytedcli.log" "aime session send")" -eq 1 ] \
    || fail "restart dispatch issued a second send"
  pass "AIME dispatch checkpoints identity, completes asynchronously, wakes once, and replays safely"
}

test_restart_adoption_and_cancellation() {
  local home fakebin trigger out rc=0 writes_before state staged
  home=$(new_home restart-adoption)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true
  new_task "$home" restart-task
  : >"$home/bytedcli.log"
  trigger="$home/never-complete"

  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    dispatch_aime "$home" "$fakebin" restart-task >/dev/null \
    || fail "restart fixture dispatch failed"
  run_aime "$home" "$fakebin" interrupt-wait restart-task >"$home/interrupt.out" \
    || fail "local waiter interrupt failed"
  assert_contains "$(cat "$home/interrupt.out")" "may still be running" \
    "waiter interrupt claimed cloud cancellation"
  [ "$(phase_of "$home" restart-task)" = submitted ] \
    || fail "waiter interrupt changed the submitted cloud phase"

  writes_before=$(grep -E -c 'aime session (create|send)' "$home/bytedcli.log")
  : >"$home/adopt.log"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    run_aime "$home" "$fakebin" adopt restart-task >"$home/adopt.out" \
    || fail "submitted task adoption failed"
  assert_contains "$(cat "$home/adopt.out")" "adopted: restart-task session=$SESSION_ID" \
    "adoption did not preserve the recorded session"
  [ "$(grep -E -c 'aime session (create|send)' "$home/bytedcli.log")" -eq "$writes_before" ] \
    || fail "restart adoption repeated create or send"

  : >"$home/cancel.log"
  run_aime "$home" "$fakebin" cancel restart-task >"$home/cancel.out" 2>"$home/cancel.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "unsupported cancellation must exit 3, got $rc"
  assert_contains "$(cat "$home/cancel.out")" "cancellation-unsupported" \
    "unsupported cancellation outcome missing"
  [ ! -s "$home/cancel.log" ] || fail "unsupported cancellation called bytedcli"
  run_aime "$home" "$fakebin" interrupt-wait restart-task >/dev/null \
    || fail "adopted waiter cleanup failed"

  new_task "$home" created-task
  write_config "$home" true
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    dispatch_aime "$home" "$fakebin" created-task >/dev/null \
    || fail "created-phase fixture dispatch failed"
  run_aime "$home" "$fakebin" interrupt-wait created-task >/dev/null \
    || fail "created-phase fixture waiter cleanup failed"
  state=$(state_file "$home" created-task)
  staged="$home/created-state.json"
  jq '
    .phase = "created"
    | .message_id = null
    | .provider_checkpoint = "create-accepted"
    | .waiter = "not-armed"
  ' "$state" >"$staged" || fail "could not stage the created-phase restart fixture"
  chmod 0600 "$staged"
  mv "$staged" "$state"
  rm -f "$home/config/aime-cloud-worker"
  : >"$home/bytedcli.log"
  rc=0
  FM_AIME_FAKE_VERSION=0.125.0 run_aime "$home" "$fakebin" adopt created-task \
    >"$home/version-drift.out" 2>"$home/version-drift.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "created-phase adoption ignored bytedcli version drift"
  [ "$(count_log "$home/bytedcli.log" "aime session send")" -eq 0 ] \
    || fail "created-phase adoption sent under an unverified bytedcli version"
  : >"$home/bytedcli.log"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    run_aime "$home" "$fakebin" adopt created-task >"$home/created-adopt.out" \
    || fail "checkpointed created task could not send after config removal"
  [ "$(count_log "$home/bytedcli.log" "aime session create")" -eq 0 ] \
    || fail "created-phase adoption repeated session creation"
  [ "$(count_log "$home/bytedcli.log" "aime session send")" -eq 1 ] \
    || fail "created-phase adoption did not perform exactly the checkpointed first send"
  [ "$(phase_of "$home" created-task)" = submitted ] \
    || fail "created-phase adoption did not reach submitted"
  run_aime "$home" "$fakebin" interrupt-wait created-task >/dev/null \
    || fail "created-phase adopted waiter cleanup failed"

  new_task "$home" not-started-task
  write_config "$home" true
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    dispatch_aime "$home" "$fakebin" not-started-task >/dev/null \
    || fail "not-started fixture dispatch failed"
  run_aime "$home" "$fakebin" interrupt-wait not-started-task >/dev/null \
    || fail "not-started fixture waiter cleanup failed"
  state=$(state_file "$home" not-started-task)
  staged="$home/not-started-state.json"
  jq '
    .phase = "create-not-started"
    | .session_id = null
    | .message_id = null
    | .provider_checkpoint = "create-intent"
    | .waiter = "not-armed"
  ' "$state" >"$staged" || fail "could not stage the not-started restart fixture"
  chmod 0600 "$staged"
  mv "$staged" "$state"
  write_config "$home" false
  : >"$home/bytedcli.log"
  rc=0
  run_aime "$home" "$fakebin" adopt not-started-task \
    >"$home/not-started-disabled.out" 2>"$home/not-started-disabled.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "disabled config allowed a checkpointed create to start"
  [ "$(count_log "$home/bytedcli.log" "aime session create")" -eq 0 ] \
    || fail "disabled not-started adoption reached session create"
  write_config "$home" true
  : >"$home/bytedcli.log"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    run_aime "$home" "$fakebin" adopt not-started-task >"$home/not-started-adopt.out" \
    || fail "checkpointed not-started task did not resume under verified config"
  [ "$(count_log "$home/bytedcli.log" "aime session create")" -eq 1 ] \
    || fail "not-started adoption did not perform exactly one first create"
  [ "$(count_log "$home/bytedcli.log" "aime session send")" -eq 1 ] \
    || fail "not-started adoption did not perform exactly one first send"
  [ "$(phase_of "$home" not-started-task)" = submitted ] \
    || fail "not-started adoption did not reach submitted"
  run_aime "$home" "$fakebin" interrupt-wait not-started-task >/dev/null \
    || fail "not-started adopted waiter cleanup failed"
  pass "restart adoption safely resumes not-started and created checkpoints, preserves submissions, and never claims cloud cancellation"
}

test_acceptance_unknown_and_explicit_failures() {
  local home fakebin id rc phase class
  home=$(new_home write-failures)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true

  for id in create-timeout create-malformed send-timeout send-malformed; do
    new_task "$home" "$id"
    : >"$home/bytedcli.log"
    rc=0
    FM_AIME_FAKE_FAILURE="$id" dispatch_aime "$home" "$fakebin" "$id" \
      >"$home/$id.out" 2>"$home/$id.err" || rc=$?
    [ "$rc" -ne 0 ] || fail "$id unexpectedly succeeded"
    phase=$(phase_of "$home" "$id")
    case "$id" in
      create-*) [ "$phase" = create-unknown ] || fail "$id did not preserve create-unknown" ;;
      send-*) [ "$phase" = send-unknown ] || fail "$id did not preserve send-unknown" ;;
    esac
    class=$(jq -r '.error_class' "$(state_file "$home" "$id")")
    case "$id" in
      *timeout) [ "$class" = timeout ] || fail "$id did not retain timeout class" ;;
      *malformed) [ "$class" = cli-failure ] || fail "$id did not retain malformed class" ;;
    esac
    rc=0
    FM_AIME_FAKE_FAILURE='' run_aime "$home" "$fakebin" adopt "$id" \
      >"$home/$id-adopt.out" 2>"$home/$id-adopt.err" || rc=$?
    [ "$rc" -ne 0 ] || fail "$id acceptance-unknown state was retried by adoption"
    case "$id" in
      create-*) [ "$(count_log "$home/bytedcli.log" "aime session create")" -eq 1 ] \
        || fail "$id repeated create" ;;
      send-*) [ "$(count_log "$home/bytedcli.log" "aime session send")" -eq 1 ] \
        || fail "$id repeated send" ;;
    esac
  done

  for id in create-rate create-unavailable send-rate; do
    new_task "$home" "$id"
    : >"$home/bytedcli.log"
    rc=0
    FM_AIME_FAKE_FAILURE="$id" dispatch_aime "$home" "$fakebin" "$id" \
      >"$home/$id.out" 2>"$home/$id.err" || rc=$?
    [ "$rc" -ne 0 ] || fail "$id unexpectedly succeeded"
    [ "$(phase_of "$home" "$id")" = terminal-failure ] \
      || fail "$id explicit rejection was not terminal"
    [ -s "$home/data/$id/report.md" ] || fail "$id explicit rejection has no report"
  done
  [ "$(jq -r '.outcome' "$(state_file "$home" create-rate)")" = rate-limited ] \
    || fail "rate limit outcome was not distinguished"
  [ "$(jq -r '.outcome' "$(state_file "$home" create-unavailable)")" = unavailable ] \
    || fail "unavailable outcome was not distinguished"
  pass "AIME writes preserve acceptance-unknown states and distinguish explicit rejection classes"
}

test_document_mode_and_terminal_result_failures() {
  local home fakebin trigger id content
  home=$(new_home document-results)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true

  id=document-ok
  new_task "$home" "$id" "Create the requested Feishu document and return its canonical marker."
  trigger="$home/$id.complete"
  content=$'# Research document\n\nFM_AIME_DOCUMENT_V1 {"url":"https://bytedance.my.larkoffice.com/docx/AbCdEf123","identity":"docx:AbCdEf123","revision":17}'
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" FM_AIME_FAKE_CONTENT="$content" \
    dispatch_aime "$home" "$fakebin" "$id" --document >/dev/null \
    || fail "document-mode dispatch failed"
  touch "$trigger"
  wait_phase "$home" "$id" terminal-success
  jq -e '
    .document.url == "https://bytedance.my.larkoffice.com/docx/AbCdEf123"
    and .document.identity == "docx:AbCdEf123"
    and .document.revision == 17
  ' "$(state_file "$home" "$id")" >/dev/null || fail "AIME-created document identity was not checkpointed"
  assert_grep 'AIME-created Feishu document' "$home/data/$id/report.md" \
    "document report omitted the canonical AIME artifact"
  assert_grep 'performed no Feishu create, copy, rewrite, permission, or sharing operation' \
    "$home/data/$id/report.md" "document report omitted the no-local-write boundary"
  ! grep -Eq 'lark-cli|lark-doc' "$home/bytedcli.log" || fail \
    "document mode invoked a local Feishu writer"

  id=document-missing
  new_task "$home" "$id"
  trigger="$home/$id.complete"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_CONTENT='# Result without a document marker' \
    dispatch_aime "$home" "$fakebin" "$id" --document >/dev/null \
    || fail "missing-document fixture dispatch failed"
  touch "$trigger"
  wait_phase "$home" "$id" terminal-failure
  [ "$(jq -r '.error_class' "$(state_file "$home" "$id")")" = document-identity-missing ] \
    || fail "missing document marker did not become terminal failure"
  assert_grep 'did not create, copy, rewrite, share, or change permissions' \
    "$home/data/$id/report.md" "missing document report blurred local-write boundary"

  id=document-invalid-host
  new_task "$home" "$id"
  trigger="$home/$id.complete"
  content=$'FM_AIME_DOCUMENT_V1 {"url":"https://example.com/docx/AbCdEf123","identity":"docx:AbCdEf123","revision":17}'
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" FM_AIME_FAKE_CONTENT="$content" \
    dispatch_aime "$home" "$fakebin" "$id" --document >/dev/null \
    || fail "invalid-document-host fixture dispatch failed"
  touch "$trigger"
  wait_phase "$home" "$id" terminal-failure
  [ "$(jq -r '.error_class' "$(state_file "$home" "$id")")" = document-identity-missing ] \
    || fail "non-Feishu document URL was accepted as canonical"

  id=empty-output
  new_task "$home" "$id"
  trigger="$home/$id.complete"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_OUTPUT_MODE=unfinished \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "empty-output fixture dispatch failed"
  touch "$trigger"
  wait_phase "$home" "$id" terminal-failure
  [ "$(jq -r '.error_class' "$(state_file "$home" "$id")")" = malformed-or-empty-output ] \
    || fail "empty provider output did not become terminal failure"
  pass "AIME document mode records the provider-created artifact and terminal bad results fail explicitly"
}

test_transient_readback_rearms_and_state_is_unknown() {
  local home fakebin trigger out recovery_marker tries=200 result sequence status_count
  home=$(new_home transient-readback)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true
  new_task "$home" transient
  trigger="$home/never"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    dispatch_aime "$home" "$fakebin" transient >/dev/null \
    || fail "transient fixture dispatch failed"

  out=$(FM_AIME_FAKE_REPLAY=timeout run_aime "$home" "$fakebin" state transient) \
    || fail "state read should normalize timeout instead of exiting"
  assert_contains "$out" "state: unknown" "readback timeout was mistaken for current task truth"
  assert_contains "$out" "readback=timeout" "readback timeout class missing"

  run_aime "$home" "$fakebin" interrupt-wait transient >/dev/null \
    || fail "transient fixture waiter cleanup failed"

  new_task "$home" recovers
  recovery_marker="$home/replay-recovered"
  FM_AIME_FAKE_REPLAY=recover FM_AIME_FAKE_RECOVERY_MARKER="$recovery_marker" \
    dispatch_aime "$home" "$fakebin" recovers >/dev/null \
    || fail "recovering-readback fixture dispatch failed"
  wait_phase "$home" recovers result-unavailable 400
  result=$(find "$home/state/procevent-inbox" -name 'aime-recovers.*.result' | head -1)
  [ -n "$result" ] || fail "unavailable AIME observation was not durably captured"
  sequence=${result##*/}
  sequence=${sequence%.result}
  sequence=${sequence##*.}
  status_count=$(grep -F -c 'blocked [key=aime-result-unavailable]' "$home/state/recovers.status")
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" handle recovers "$sequence" "$result" >/dev/null \
    || fail "duplicate unavailable AIME observation was not idempotent"
  [ "$(grep -F -c 'blocked [key=aime-result-unavailable]' "$home/state/recovers.status")" -eq "$status_count" ] \
    || fail "duplicate unavailable AIME observation duplicated the blocker"
  while [ "$tries" -gt 0 ] && [ "$(phase_of "$home" recovers)" != terminal-success ]; do
    FM_AIME_FAKE_REPLAY=recover FM_AIME_FAKE_RECOVERY_MARKER="$recovery_marker" \
      FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
      FM_AIME_FAKE_LOG="$home/bytedcli.log" FM_AIME_FAKE_SPACE_ID="$SPACE_ID" \
      FM_AIME_FAKE_SESSION_ID="$SESSION_ID" FM_AIME_FAKE_MESSAGE_ID="$MESSAGE_ID" \
      PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
      || fail "recovering-readback fixture could not reconcile its re-armed source"
    sleep 0.05
    tries=$((tries - 1))
  done
  wait_phase "$home" recovers terminal-success 400
  assert_grep 'blocked [key=aime-result-unavailable]' "$home/state/recovers.status" \
    "transient adapter failure did not open the result-unavailable blocker"
  assert_grep 'resolved [key=aime-result-unavailable]' "$home/state/recovers.status" \
    "authoritative recovery did not resolve the result-unavailable blocker"
  [ -z "$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/recovers.status")" ] \
    || fail "recovered AIME readback left a durable open blocker"
  pass "transient provider readback is unknown current state, re-arms, and resolves its blocker after recovery"
}

test_cloud_retirement_preserves_report() {
  local home fakebin id rc=0 report
  home=$(new_home cloud-retirement)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  id=retire-task
  new_task "$home" "$id"
  : >"$home/bytedcli.log"

  FM_AIME_FAKE_FAILURE=create-rate dispatch_aime "$home" "$fakebin" "$id" \
    >"$home/$id.out" 2>"$home/$id.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "retirement fixture unexpectedly submitted"
  [ "$(phase_of "$home" "$id")" = terminal-failure ] \
    || fail "retirement fixture did not reach terminal failure"
  report="$home/data/$id/report.md"
  [ -s "$report" ] || fail "retirement fixture has no durable report"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"

  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >"$home/retire.out" \
    || fail "terminal AIME task retirement failed"
  [ -s "$report" ] || fail "AIME retirement removed the durable report"
  [ ! -e "$home/state/$id.meta" ] || fail "AIME retirement retained volatile task metadata"
  [ ! -e "$home/state/$id.status" ] || fail "AIME retirement retained volatile status history"
  [ ! -e "$home/state/cloud-tasks/$id" ] || fail "AIME retirement retained private cloud state"
  pass "terminal AIME retirement passes the decision gate, removes volatile cloud state, and preserves the report"
}

test_local_executor_wrappers_delegate_unchanged() {
  local root="$TMP_ROOT/wrapper-root" out
  mkdir -p "$root/bin" "$root/home/state"
  cp "$ROOT/bin/fm-task-dispatch.sh" "$root/bin/"
  cp "$ROOT/bin/fm-task-state.sh" "$root/bin/"
  cp "$ROOT/bin/fm-task-retire.sh" "$root/bin/"
  cat >"$root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'spawn'
printf ' <%s>' "$@"
printf '\n'
SH
  cat >"$root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state-local'
printf ' <%s>' "$@"
printf '\n'
SH
  cat >"$root/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown'
printf ' <%s>' "$@"
printf '\n'
SH
  chmod +x "$root/bin/"*.sh

  out=$("$root/bin/fm-task-dispatch.sh" local-agent local-id project/path --scout --harness codex)
  [ "$out" = 'spawn <local-id> <project/path> <--scout> <--harness> <codex>' ] \
    || fail "local dispatch arguments changed: $out"
  out=$(FM_HOME="$root/home" "$root/bin/fm-task-state.sh" local-id)
  [ "$out" = 'state-local <local-id>' ] || fail "legacy local state delegation changed: $out"
  out=$(FM_HOME="$root/home" "$root/bin/fm-task-retire.sh" local-id --force-example)
  [ "$out" = 'teardown <local-id> <--force-example>' ] \
    || fail "legacy local retirement arguments changed: $out"
  pass "backend-neutral wrappers preserve local spawn, state, and teardown argument semantics"
}

test_probe_and_disabled_gate
test_probe_failures_are_distinct
test_sandbox_verification_is_explicit_and_stays_disabled
test_dispatch_completion_and_duplicate_replay
test_restart_adoption_and_cancellation
test_acceptance_unknown_and_explicit_failures
test_document_mode_and_terminal_result_failures
test_transient_readback_rearms_and_state_is_unknown
test_cloud_retirement_preserves_report
test_local_executor_wrappers_delegate_unchanged

echo "# fm-aime-cloud-worker.test.sh: all assertions passed"
