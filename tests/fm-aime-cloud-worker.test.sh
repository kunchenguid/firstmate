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

wait_present() { # <path>
  local path=$1 tries=${2:-200}
  while [ "$tries" -gt 0 ]; do
    [ -e "$path" ] && [ ! -L "$path" ] && return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

count_log() { # <log> <fixed-pattern>
  grep -F -c "$2" "$1" 2>/dev/null || true
}

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
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
      block|oversized-block)
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
    if [ "${FM_AIME_FAKE_REPLAY:-terminal}" = oversized ] \
      || [ "${FM_AIME_FAKE_REPLAY:-terminal}" = oversized-block ]; then
      jq -cn \
        --arg session "$session" \
        --rawfile payload "${FM_AIME_FAKE_REPLAY_PAYLOAD:?}" \
        '{status:"success",data:{session_id:$session,terminal:true,last_event_offset:73,events:[{offset:4,type:"progress",tool_payload:$payload},{offset:73,type:"terminal"}]},error:null}'
    elif [ "${FM_AIME_FAKE_REPLAY:-terminal}" = nonterminal ]; then
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
  FM_AIME_FAKE_REPLAY_PAYLOAD="${FM_AIME_FAKE_REPLAY_PAYLOAD:-}" \
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
  FM_AIME_FAKE_REPLAY_PAYLOAD="${FM_AIME_FAKE_REPLAY_PAYLOAD:-}" \
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

retire_aime() { # <home> <fakebin> <id>
  local home=$1 fakebin=$2 id=$3
  FM_HOME="$home" \
  FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
  FM_AIME_FAKE_LOG="$home/bytedcli.log" \
  FM_AIME_FAKE_SPACE_ID="$SPACE_ID" \
  FM_AIME_FAKE_SESSION_ID="$SESSION_ID" \
  FM_AIME_FAKE_MESSAGE_ID="$MESSAGE_ID" \
  FM_AIME_FAKE_REPLAY="${FM_AIME_FAKE_REPLAY:-terminal}" \
  FM_AIME_FAKE_OUTPUT_MODE="${FM_AIME_FAKE_OUTPUT_MODE:-success}" \
  FM_AIME_FAKE_SESSION_MODE="${FM_AIME_FAKE_SESSION_MODE:-success}" \
  FM_AIME_FAKE_SESSION_STATUS="${FM_AIME_FAKE_SESSION_STATUS:-completed}" \
  PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-task-retire.sh" "$id"
}

capture_aime_bytes() { # <home> <source-id> <bytes>
  local home=$1 source=$2 bytes=$3
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" register aime "$source" -- /bin/printf '%s' "$bytes" >/dev/null \
    || fail "could not register synthetic AIME capture for $source"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null 2>&1 \
    || fail "could not capture synthetic AIME bytes for $source"
}

capture_unpublished_bytes() { # <home> <adapter> <source-id> <bytes>
  local home=$1 adapter=$2 source=$3 bytes=$4 queue="$1/state/.wake-queue" saved
  saved="$1/state/.wake-queue.unpublished-saved"
  [ ! -e "$saved" ] && [ ! -L "$saved" ] \
    || fail "unpublished capture fixture found a stale saved wake queue"
  if [ -e "$queue" ]; then
    [ -f "$queue" ] && [ ! -L "$queue" ] \
      || fail "unpublished capture fixture found an unsafe wake queue"
    mv "$queue" "$saved"
  fi
  mkdir "$queue"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" register "$adapter" "$source" -- /bin/printf '%s' "$bytes" >/dev/null \
    || fail "could not register unpublished $adapter capture for $source"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null 2>&1 \
    || fail "could not capture unpublished $adapter bytes for $source"
  rmdir "$queue" || fail "unpublished capture unexpectedly wrote the wake queue"
  if [ -e "$saved" ]; then
    mv "$saved" "$queue"
  else
    : >"$queue"
  fi
  chmod 0600 "$queue"
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

test_durable_state_skips_provider_readback() {
  local home fakebin id=durable-state out sha
  home=$(new_home durable-state)
  fakebin=$(make_fake_bytedcli "$home")
  new_task "$home" "$id"
  sha=$(file_sha256 "$home/data/$id/instructions.txt")
  FM_HOME="$home" STATE="$home/state" DATA="$home/data" bash -c '
    . "$1/bin/fm-aime-cloud-lib.sh"
    fm_aime_state_initialize "$2" cn "$3" research "$4" "$5" 0.124.0
    fm_aime_state_transition "$2" submitted "" "" "$6" "$7" "" send-accepted "" "" not-armed ""
  ' _ "$ROOT" "$id" "$SPACE_ID" "$home/data/$id/instructions.txt" "$sha" \
    "$SESSION_ID" "$MESSAGE_ID" || fail "durable AIME state fixture failed"
  : >"$home/bytedcli.log"

  out=$(run_aime "$home" "$fakebin" state "$id" --durable-only) \
    || fail "durable-only AIME state read failed"
  assert_contains "$out" \
    "state: working · source: cloud-state · provider=aime phase=submitted outcome=none freshness=durable-local remote-readback=deferred" \
    "durable-only AIME state omitted its freshness gap"
  [ ! -s "$home/bytedcli.log" ] || fail "durable-only AIME state reached the provider"
  pass "durable-only AIME state is local and labels deferred provider freshness"
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

test_oversized_replay_stays_valid_through_runner_capture() {
  local home fakebin id payload trigger malformed malformed_seq result='' recovery_out evidence
  local early_recovery_rc=0 tries=200 runner_bound=1048576
  home=$(new_home oversized-replay)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true
  id=oversized
  new_task "$home" "$id"
  : >"$home/bytedcli.log"
  payload="$home/replay-payload"
  head -c "$((runner_bound + 4096))" /dev/zero | tr '\0' x >"$payload"
  [ "$(wc -c <"$payload" | tr -d '[:space:]')" -gt "$runner_bound" ] \
    || fail "oversized replay fixture does not exceed the runner capture bound"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" register aime aime-oversized -- \
      /bin/printf '{"truncated":' >/dev/null \
    || fail "could not register the pre-fix malformed capture fixture"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" start aime-oversized >/dev/null 2>&1 \
    || fail "could not capture the pre-fix malformed result fixture"
  malformed=$(find "$home/state/procevent-inbox" -name 'aime-oversized.*.result' | head -1)
  [ -n "$malformed" ] || fail "pre-fix malformed result fixture was not captured"
  malformed_seq=${malformed##*/}
  malformed_seq=${malformed_seq%.result}
  malformed_seq=${malformed_seq##*.}

  trigger="$home/oversized-ready"
  FM_PROCEVENT_MAX_OUTPUT_BYTES="$runner_bound" \
    FM_AIME_FAKE_REPLAY=oversized-block FM_AIME_FAKE_REPLAY_PAYLOAD="$payload" \
    FM_AIME_FAKE_TRIGGER="$trigger" FM_AIME_FAKE_CONTENT='# Oversized replay result' \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "oversized-replay AIME dispatch failed"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" handle "$id" "$malformed_seq" "$malformed" \
    >"$home/early-recovery.out" 2>"$home/early-recovery.err" || early_recovery_rc=$?
  [ "$early_recovery_rc" -ne 0 ] \
    || fail "malformed capture was acknowledged before a newer observation was applied"
  assert_absent "$home/state/procevent-inbox/aime-oversized.$malformed_seq.handled" \
    "rejected malformed recovery left a handled acknowledgement"
  touch "$trigger"
  while [ "$tries" -gt 0 ]; do
    result=$(find "$home/state/procevent-inbox" -name 'aime-oversized.*.result' ! -path "$malformed" 2>/dev/null | head -1)
    [ -n "$result" ] && break
    sleep 0.05
    tries=$((tries - 1))
  done
  [ -n "$result" ] || fail "oversized replay produced no captured observation"
  [ "$(wc -c <"$result" | tr -d '[:space:]')" -lt "$runner_bound" ] \
    || fail "oversized replay observation reached the runner capture bound"
  jq -s -e '
    length == 1
    and .[0].schema == "fm-aime-observation.v1"
    and .[0].from_offset == 0
    and .[0].terminal_candidate == true
    and .[0].replay.data.last_event_offset == 73
    and .[0].replay.data.event_count == 2
    and (.[0].replay.data | has("events") | not)
  ' "$result" >/dev/null || fail "captured oversized replay observation is malformed or lost its authoritative boundary"
  wait_phase "$home" "$id" terminal-success
  jq -e '.event_cursor == 73 and .outcome == "succeeded"' "$(state_file "$home" "$id")" >/dev/null \
    || fail "oversized replay did not advance the durable cursor to the authoritative offset"
  assert_grep '# Oversized replay result' "$home/data/$id/report.md" \
    "oversized replay did not produce the self-contained terminal report"
  recovery_out=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" handle "$id" "$malformed_seq" "$malformed") \
    || fail "adapter did not recover the older malformed capture after authoritative replay"
  assert_contains "$recovery_out" "malformed-superseded=true" \
    "malformed recovery did not report its superseded evidence outcome"
  assert_present "$home/state/procevent-inbox/aime-oversized.$malformed_seq.handled" \
    "adapter-owned recovery did not retire the malformed generation"
  evidence=$(find "$home/state/cloud-tasks/$id/artifacts" -name '*-malformed-observation.json' | head -1)
  if [ -z "$evidence" ] || ! cmp -s "$malformed" "$evidence"; then
    fail "adapter-owned recovery did not preserve the exact malformed evidence"
  fi
  pass "oversized replay history stays bounded, handles to terminal success, and safely supersedes the malformed capture"
}

test_stopped_terminal_unavailable_retires_generations_and_report() {
  local home fakebin id source trigger report before after out seq quarantine
  home=$(new_home stopped-terminal-unavailable)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  id=terminal-unavailable
  source=aime-$id
  new_task "$home" "$id"
  : >"$home/bytedcli.log"

  capture_aime_bytes "$home" "$source" '{synthetic-malformed-one'
  capture_aime_bytes "$home" "$source" '{synthetic-malformed-two'
  assert_absent "$home/state/procevent-inbox/$source.1.handled" \
    "malformed fixture was acknowledged before terminal-unavailable proof"
  assert_absent "$home/state/procevent-inbox/$source.2.handled" \
    "second malformed fixture was acknowledged before terminal-unavailable proof"

  trigger="$home/terminal"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_SESSION_STATUS=stopped FM_AIME_FAKE_OUTPUT_MODE=unavailable \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "stopped terminal-unavailable fixture dispatch failed"
  touch "$trigger"
  wait_phase "$home" "$id" terminal-failure 400
  for seq in 1 2 3; do
    wait_present "$home/state/procevent-inbox/$source.$seq.handled" 400 \
      || fail "terminal-unavailable generation $seq was not durably acknowledged"
  done
  jq -e '
    .phase == "terminal-failure"
    and .outcome == "failed"
    and .error_class == "provider-stopped-output-unavailable"
    and .provider_checkpoint == "terminal-output-unavailable"
    and .waiter == "terminal"
    and .event_cursor == 9
  ' "$(state_file "$home" "$id")" >/dev/null \
    || fail "stopped terminal-unavailable state lost its truthful terminal proof"
  report="$home/data/$id/report.md"
  assert_grep "Provider status: \`stopped\`" "$report" \
    "terminal-unavailable report omitted stopped provider truth"
  assert_grep "Requested output: \`unavailable after bounded readback\`" "$report" \
    "terminal-unavailable report omitted unavailable output truth"
  assert_grep 'recovered no result, computed no replacement outcome' "$report" \
    "terminal-unavailable report implied a result was recovered or computed"
  assert_grep 'neither attempted nor claimed provider cancellation' "$report" \
    "terminal-unavailable report blurred the cancellation boundary"
  assert_no_grep 'synthetic-malformed-one' "$report" \
    "malformed payload bytes leaked into the failure report"
  assert_no_grep 'synthetic-malformed-two' "$report" \
    "second malformed payload leaked into the failure report"
  quarantine="$home/data/$id/aime-quarantine"
  cmp -s "$home/state/procevent-inbox/$source.1.result" "$quarantine/$source.1.result" \
    || fail "first malformed generation was not preserved exactly in private quarantine"
  cmp -s "$home/state/procevent-inbox/$source.2.result" "$quarantine/$source.2.result" \
    || fail "second malformed generation was not preserved exactly in private quarantine"
  cmp -s "$home/state/procevent-inbox/$source.3.result" "$quarantine/$source.3.result" \
    || fail "terminal proof generation was not preserved exactly in private quarantine"
  assert_grep "$source#1" "$report" "first quarantined generation is absent from the audit record"
  assert_grep "$source#2" "$report" "second quarantined generation is absent from the audit record"
  assert_grep "$source#3" "$report" "terminal proof generation is absent from the audit record"
  assert_absent "$home/state/procevent/$source.source" \
    "terminal-unavailable handling left future result listening armed"

  out=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" reconcile)
  assert_contains "$out" 'published=0' \
    "handled terminal-unavailable generations were re-announced"
  assert_no_grep "procevent aime $source" "$home/state/.wake-queue" \
    "an already queued terminal-unavailable wake survived adapter retirement"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >/dev/null \
    || fail "first terminal-unavailable retirement preparation retry failed"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >/dev/null \
    || fail "second terminal-unavailable retirement preparation retry was not idempotent"

  fm_test_archive_goal "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"
  before=$(file_sha256 "$report")
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >/dev/null \
    || fail "stopped terminal-unavailable task did not archive through the task interface"
  after=$(file_sha256 "$report")
  [ "$before" = "$after" ] || fail "archival changed the terminal-unavailable failure report"
  assert_absent "$home/state/cloud-tasks/$id" \
    "terminal-unavailable archival retained volatile cloud state"
  assert_present "$quarantine/$source.1.result" \
    "archival removed the private malformed-generation evidence"
  assert_present "$quarantine/$source.2.result" \
    "archival removed the second malformed-generation evidence"
  out=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" reconcile)
  assert_contains "$out" 'published=0' \
    "archived terminal-unavailable generations resumed announcement"
  pass "provider-stopped terminal output unavailability becomes a truthful failure, retires exact captured generations, and archives with evidence"
}

test_existing_result_unavailable_guarded_archival() {
  local home fakebin id source trigger report
  home=$(new_home existing-result-unavailable)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  id=existing-terminal-unavailable
  source=aime-$id
  new_task "$home" "$id"
  trigger="$home/initial-wait"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "existing result-unavailable fixture dispatch failed"
  run_aime "$home" "$fakebin" interrupt-wait "$id" >/dev/null \
    || fail "existing result-unavailable fixture initial waiter cleanup failed"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" arm "$id" >/dev/null \
    || fail "existing result-unavailable fixture could not arm bounded readback"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    FM_AIME_FAKE_LOG="$home/bytedcli.log" FM_AIME_FAKE_SPACE_ID="$SPACE_ID" \
    FM_AIME_FAKE_SESSION_ID="$SESSION_ID" FM_AIME_FAKE_MESSAGE_ID="$MESSAGE_ID" \
    FM_AIME_FAKE_REPLAY=terminal FM_AIME_FAKE_OUTPUT_MODE=unavailable \
    FM_AIME_FAKE_SESSION_STATUS=completed PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null \
    || fail "existing result-unavailable fixture readback did not complete"
  [ "$(phase_of "$home" "$id")" = result-unavailable ] \
    || fail "preparation fixture did not preserve the existing result-unavailable phase"
  run_aime "$home" "$fakebin" interrupt-wait "$id" >/dev/null \
    || fail "existing result-unavailable fixture re-armed waiter cleanup failed"

  report="$home/data/$id/report.md"
  printf '# Preserved synthetic AIME failure report\n\nThe provider result is unavailable; no research result was recovered.\n' >"$report"
  chmod 0600 "$report"
  capture_unpublished_bytes "$home" aime "$source" '{existing-malformed-one'
  capture_unpublished_bytes "$home" aime "$source" '{existing-malformed-two'
  fm_test_archive_goal "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"

  FM_AIME_FAKE_REPLAY=terminal FM_AIME_FAKE_OUTPUT_MODE=unavailable \
    FM_AIME_FAKE_SESSION_STATUS=stopped retire_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "guarded task retirement did not archive an existing stopped terminal-unavailable record"
  assert_absent "$home/state/cloud-tasks/$id" \
    "guarded archival retained the existing volatile cloud record"
  assert_grep 'Preserved synthetic AIME failure report' "$report" \
    "guarded archival replaced the existing failure report"
  assert_grep "Provider status: \`stopped\`" "$report" \
    "guarded archival did not append the proven terminal outcome"
  assert_grep "Requested output: \`unavailable after bounded readback\`" "$report" \
    "guarded archival did not record the failed bounded readback"
  assert_present "$home/state/procevent-inbox/$source.2.handled" \
    "guarded archival did not acknowledge the first pending malformed generation"
  assert_present "$home/state/procevent-inbox/$source.3.handled" \
    "guarded archival did not acknowledge the second pending malformed generation"
  assert_present "$home/data/$id/aime-quarantine/$source.2.result" \
    "guarded archival did not preserve the first pending malformed generation"
  assert_present "$home/data/$id/aime-quarantine/$source.3.result" \
    "guarded archival did not preserve the second pending malformed generation"
  pass "an existing result-unavailable record uses bounded fresh proof to archive only the stopped terminal-unavailable failure class"
}

test_terminal_unavailable_retry_and_refusal_boundaries() {
  local home fakebin id source trigger report rc out wrong_session wrong_observation
  local contradictory_observation unrelated_source
  home=$(new_home terminal-unavailable-retry)
  fakebin=$(make_fake_bytedcli "$home")
  write_config "$home" true
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  id=retry-boundary
  source=aime-$id
  new_task "$home" "$id"
  trigger="$home/terminal"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_SESSION_STATUS=stopped FM_AIME_FAKE_OUTPUT_MODE=unavailable \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "retry-boundary fixture dispatch failed"
  touch "$trigger"
  wait_present "$home/state/procevent-inbox/$source.1.handled" 400 \
    || fail "retry-boundary terminal proof was not acknowledged"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >/dev/null \
    || fail "retry-boundary terminal seal did not settle"

  capture_unpublished_bytes "$home" aime "$source" '{retry-boundary-malformed'
  assert_absent "$home/state/procevent-inbox/$source.2.handled" \
    "unpublished malformed generation was unexpectedly acknowledged"
  rc=0
  FM_AIME_RETIRE_MAX_GENERATIONS=1 \
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >"$home/bounded.out" 2>"$home/bounded.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "bounded retirement scan silently skipped a later generation"
  assert_grep 'bounded retirement scan' "$home/bounded.err" \
    "bounded retirement refusal did not identify its limit"
  assert_absent "$home/data/$id/aime-quarantine/$source.2.result" \
    "over-bound retirement partially quarantined a generation"
  assert_absent "$home/state/procevent-inbox/$source.2.handled" \
    "over-bound retirement partially acknowledged a generation"

  ln -s "$home/nonexistent-handled-target" "$home/state/procevent-inbox/$source.2.handled"
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >"$home/interrupted.out" 2>"$home/interrupted.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe acknowledgement boundary did not interrupt retirement preparation"
  assert_grep 'could not be acknowledged' "$home/interrupted.err" \
    "interrupted preparation did not preserve its exact retry boundary"
  assert_present "$home/data/$id/aime-quarantine/$source.2.result" \
    "interrupted preparation lost the quarantined generation"
  report="$home/data/$id/report.md"
  assert_grep "$source#2" "$report" \
    "interrupted preparation lost the durable report ledger entry"
  [ -L "$home/state/procevent-inbox/$source.2.handled" ] \
    || fail "failed acknowledgement unexpectedly replaced its unsafe marker"
  rm -f -- "$home/state/procevent-inbox/$source.2.handled"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >/dev/null \
    || fail "retry after the acknowledgement interruption did not converge"
  assert_present "$home/state/procevent-inbox/$source.2.handled" \
    "retry did not durably acknowledge the quarantined generation"
  [ "$(grep -F -c "$source#2" "$report")" -eq 1 ] \
    || fail "retry duplicated the generation audit entry"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >/dev/null \
    || fail "completed retirement preparation was not idempotent"

  fm_test_archive_goal "$home" "$id"
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >"$home/decision.out" 2>"$home/decision.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "terminal-unavailable archival bypassed decision review"
  assert_grep 'decision completion gate has not passed' "$home/decision.err" \
    "incomplete decision review did not remain the archival blocker"
  assert_present "$(state_file "$home" "$id")" \
    "decision-gate refusal removed terminal-unavailable state"
  fm_test_archive_goal "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >/dev/null \
    || fail "decision-complete retry did not archive the prepared task"

  id=identity-mismatch
  source=aime-$id
  new_task "$home" "$id"
  trigger="$home/$id-terminal"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_SESSION_STATUS=stopped FM_AIME_FAKE_OUTPUT_MODE=unavailable \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "identity-mismatch fixture dispatch failed"
  touch "$trigger"
  wait_present "$home/state/procevent-inbox/$source.1.handled" 400 \
    || fail "identity-mismatch fixture did not reach its sealed baseline"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >/dev/null \
    || fail "identity-mismatch terminal seal did not settle"
  unrelated_source=aime-unrelated-retirement-source
  capture_unpublished_bytes "$home" aime "$unrelated_source" '{synthetic-unrelated-source'
  assert_absent "$home/state/procevent-inbox/$unrelated_source.1.handled" \
    "AIME retirement acknowledged a generation from an unrelated source"
  assert_absent "$home/data/$id/aime-quarantine/$unrelated_source.1.result" \
    "AIME retirement quarantined a generation from an unrelated source"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent.sh" retire "$unrelated_source" >/dev/null \
    || fail "unrelated-source fixture cleanup failed"
  wrong_session=99999999-9999-4999-8999-999999999999
  wrong_observation=$(jq -cn \
    --arg id "$id" --arg session "$wrong_session" '
      {
        schema:"fm-aime-observation.v1",task_id:$id,provider:"aime",site:"cn",
        session_id:$session,from_offset:9,replay_ok:true,session_ok:true,output_ok:false,
        terminal_candidate:true,observed_at:"2026-08-18T00:00:00Z",
        replay:{status:"success",data:{session_id:$session,terminal:true,last_event_offset:10,event_count:1},error:null},
        session:{status:"success",data:{id:$session,status:"stopped"},error:null},
        output:{status:"error",error_class:"unavailable"}
      }')
  capture_unpublished_bytes "$home" aime "$source" "$wrong_observation"
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >"$home/identity.out" 2>"$home/identity.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "identity-mismatched observation was suppressed during retirement"
  assert_grep 'observation identity does not match' "$home/identity.err" \
    "identity-mismatch refusal did not name the failed binding"
  assert_absent "$home/state/procevent-inbox/$source.2.handled" \
    "identity-mismatched generation was acknowledged"
  assert_absent "$home/data/$id/aime-quarantine/$source.2.result" \
    "identity-mismatched generation was quarantined as if owned"

  id='terminal-proof-mismatch'
  source=aime-$id
  new_task "$home" "$id"
  trigger="$home/$id-terminal"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_SESSION_STATUS=stopped FM_AIME_FAKE_OUTPUT_MODE=unavailable \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "terminal-proof-mismatch fixture dispatch failed"
  touch "$trigger"
  wait_present "$home/state/procevent-inbox/$source.1.handled" 400 \
    || fail "terminal-proof-mismatch fixture did not reach its sealed baseline"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >/dev/null \
    || fail "terminal-proof-mismatch terminal seal did not settle"
  contradictory_observation=$(jq -cn \
    --arg id "$id" --arg session "$SESSION_ID" '
      {
        schema:"fm-aime-observation.v1",task_id:$id,provider:"aime",site:"cn",
        session_id:$session,from_offset:9,replay_ok:true,session_ok:true,output_ok:false,
        terminal_candidate:true,observed_at:"2026-08-18T00:00:00Z",
        replay:{status:"success",data:{session_id:$session,terminal:false,last_event_offset:10,event_count:1},error:null},
        session:{status:"success",data:{id:$session,status:"stopped"},error:null},
        output:{status:"error",error_class:"unavailable"}
      }')
  capture_unpublished_bytes "$home" aime "$source" "$contradictory_observation"
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >"$home/terminal-proof.out" 2>"$home/terminal-proof.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "nonterminal replay evidence was suppressed during retirement"
  assert_grep 'contradicts the terminal-unavailable outcome' "$home/terminal-proof.err" \
    "nonterminal replay refusal did not preserve the authoritative-terminal boundary"
  assert_absent "$home/state/procevent-inbox/$source.2.handled" \
    "generation without authoritative terminal replay was acknowledged"
  assert_absent "$home/data/$id/aime-quarantine/$source.2.result" \
    "generation without authoritative terminal replay was quarantined"

  id='adapter-mismatch'
  source=aime-$id
  new_task "$home" "$id"
  trigger="$home/$id-terminal"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_SESSION_STATUS=stopped FM_AIME_FAKE_OUTPUT_MODE=unavailable \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "adapter-mismatch fixture dispatch failed"
  touch "$trigger"
  wait_present "$home/state/procevent-inbox/$source.1.handled" 400 \
    || fail "adapter-mismatch fixture did not reach its sealed baseline"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >/dev/null \
    || fail "adapter-mismatch terminal seal did not settle"
  capture_unpublished_bytes "$home" lavish "$source" 'synthetic-unrelated-adapter-result'
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" prepare-retire "$id" >"$home/adapter.out" 2>"$home/adapter.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "another adapter's generation was suppressed by AIME retirement"
  assert_grep 'not owned by the AIME adapter' "$home/adapter.err" \
    "adapter mismatch refusal did not preserve one-owner evidence"
  assert_absent "$home/state/procevent-inbox/$source.2.handled" \
    "another adapter's generation was acknowledged by AIME"
  pass "terminal-unavailable preparation is bounded and retryable, preserves decision holds, and refuses identity or adapter mismatches"
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
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" restart-task \
    >"$home/running-retire.out" 2>"$home/running-retire.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "submitted AIME task was retired"
  assert_grep 'goal is unfinished' "$home/running-retire.err" \
    "unfinished remote goal did not block retirement"
  [ "$(phase_of "$home" restart-task)" = submitted ] || fail 'retirement changed live provider phase'
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
  local home fakebin id rc phase class retire_rc
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
    retire_rc=0
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
      "$ROOT/bin/fm-task-retire.sh" "$id" \
      >"$home/$id-retire.out" 2>"$home/$id-retire.err" || retire_rc=$?
    [ "$retire_rc" -ne 0 ] || fail "$id acceptance uncertainty was retired"
    assert_grep 'goal is unfinished' "$home/$id-retire.err" \
      "$id retirement refusal did not preserve unfinished goal"
    [ "$(phase_of "$home" "$id")" = "$phase" ] || fail 'retirement changed ambiguous provider phase'
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
  local home fakebin trigger out recovery_marker tries=200 result sequence status_count rc
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

  new_task "$home" uncertain-terminal
  trigger="$home/uncertain-never"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    dispatch_aime "$home" "$fakebin" uncertain-terminal >/dev/null \
    || fail "provider-uncertainty fixture dispatch failed"
  run_aime "$home" "$fakebin" interrupt-wait uncertain-terminal >/dev/null \
    || fail "provider-uncertainty fixture initial waiter cleanup failed"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ADAPTER" arm uncertain-terminal >/dev/null \
    || fail "provider-uncertainty fixture could not arm one bounded readback"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    FM_AIME_FAKE_LOG="$home/bytedcli.log" FM_AIME_FAKE_SPACE_ID="$SPACE_ID" \
    FM_AIME_FAKE_SESSION_ID="$SESSION_ID" FM_AIME_FAKE_MESSAGE_ID="$MESSAGE_ID" \
    FM_AIME_FAKE_REPLAY=unavailable PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-procevent.sh" start aime-uncertain-terminal >/dev/null \
    || fail "provider-uncertainty fixture readback did not complete"
  [ "$(phase_of "$home" uncertain-terminal)" = result-unavailable ] \
    || fail "provider uncertainty did not remain result-unavailable"
  printf '# Synthetic provider-uncertainty report\n\nNo provider result is available.\n' \
    >"$home/data/uncertain-terminal/report.md"
  chmod 0600 "$home/data/uncertain-terminal/report.md"
  fm_test_archive_goal "$home" uncertain-terminal
  rc=0
  FM_AIME_FAKE_REPLAY=unavailable \
    retire_aime "$home" "$fakebin" uncertain-terminal \
    >"$home/uncertain-retire.out" 2>"$home/uncertain-retire.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "provider-uncertain result-unavailable task was retired"
  assert_grep 'terminal stopped/output-unavailable evidence is not proven' \
    "$home/uncertain-retire.err" \
    "provider-uncertain retirement did not refuse at the proof boundary"
  assert_present "$home/state/procevent/aime-uncertain-terminal.source" \
    "provider-uncertain retirement stopped adoptable result listening"
  run_aime "$home" "$fakebin" interrupt-wait uncertain-terminal >/dev/null \
    || fail "provider-uncertainty fixture waiter cleanup failed"

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
  local home fakebin id rc=0 report saved alias trigger
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

  fm_test_archive_goal "$home" "$id"
  saved="$home/data/$id/report.saved"
  mv "$report" "$saved"
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >"$home/missing-report.out" 2>"$home/missing-report.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "AIME retirement accepted a missing report"
  mv "$saved" "$report"

  chmod 0644 "$report"
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >"$home/mode-report.out" 2>"$home/mode-report.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "AIME retirement accepted a non-private report"
  chmod 0600 "$report"

  alias="$home/data/$id/report.alias"
  ln "$report" "$alias"
  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >"$home/hardlink-report.out" 2>"$home/hardlink-report.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "AIME retirement accepted a hardlinked report"
  rm -f -- "$alias"

  rc=0
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >"$home/decision-report.out" 2>"$home/decision-report.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "AIME retirement bypassed incomplete decision review"
  assert_grep 'decision completion gate has not passed' "$home/decision-report.err" \
    "AIME retirement did not preserve the decision gate after report checks"
  fm_test_archive_goal "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"

  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >"$home/retire.out" \
    || fail "terminal AIME task retirement failed"
  [ -s "$report" ] || fail "AIME retirement removed the durable report"
  [ ! -e "$home/state/$id.meta" ] || fail "AIME retirement retained volatile task metadata"
  [ ! -e "$home/state/$id.status" ] || fail "AIME retirement retained volatile status history"
  [ ! -e "$home/state/cloud-tasks/$id" ] || fail "AIME retirement retained private cloud state"

  id=provider-failed
  new_task "$home" "$id"
  trigger="$home/provider-failed-terminal"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_SESSION_MODE=failed FM_AIME_FAKE_OUTPUT_MODE=unavailable \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "ordinary provider-failure retirement fixture dispatch failed"
  touch "$trigger"
  wait_phase "$home" "$id" terminal-failure 400
  [ "$(jq -r '.error_class' "$(state_file "$home" "$id")")" = provider-terminal-failure ] \
    || fail "ordinary provider failure was changed by terminal-unavailable handling"
  assert_grep "Error class: \`provider-terminal-failure\`" "$home/data/$id/report.md" \
    "ordinary provider failure report changed classification"
  fm_test_archive_goal "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >/dev/null \
    || fail "ordinary terminal provider failure no longer archives"
  assert_present "$home/data/$id/report.md" \
    "ordinary provider failure archival removed its report"

  id=success-retire
  new_task "$home" "$id"
  trigger="$home/success-retire-terminal"
  FM_AIME_FAKE_REPLAY=block FM_AIME_FAKE_TRIGGER="$trigger" \
    FM_AIME_FAKE_SESSION_STATUS=stopped \
    dispatch_aime "$home" "$fakebin" "$id" >/dev/null \
    || fail "successful retirement fixture dispatch failed"
  touch "$trigger"
  wait_phase "$home" "$id" terminal-success 400
  assert_grep '## Provider Result' "$home/data/$id/report.md" \
    "readable stopped-provider output was not preserved as success"
  fm_test_archive_goal "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-task-retire.sh" "$id" >/dev/null \
    || fail "successful AIME result no longer archives"
  assert_present "$home/data/$id/report.md" \
    "successful AIME archival removed its report"
  pass "terminal AIME success and failure retirement enforce report and decision safety while preserving ordinary provider failures"
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
test_durable_state_skips_provider_readback
test_dispatch_completion_and_duplicate_replay
test_oversized_replay_stays_valid_through_runner_capture
test_stopped_terminal_unavailable_retires_generations_and_report
test_existing_result_unavailable_guarded_archival
test_terminal_unavailable_retry_and_refusal_boundaries
test_restart_adoption_and_cancellation
test_acceptance_unknown_and_explicit_failures
test_document_mode_and_terminal_result_failures
test_transient_readback_rearms_and_state_is_unknown
test_cloud_retirement_preserves_report
test_local_executor_wrappers_delegate_unchanged

echo "# fm-aime-cloud-worker.test.sh: all assertions passed"
