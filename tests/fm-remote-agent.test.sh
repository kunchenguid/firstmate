#!/usr/bin/env bash
# Behavioral coverage for native remote-agent routing and the iDA provider.
# Provider calls use the fake bytedcli below through the public scripts. The
# tests never create a real iDA/AIME session and never inspect implementation
# source strings as behavioral evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-agent)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
BASE_PATH=$PATH
IDA="$ROOT/bin/fm-remote-agent-ida.sh"
DISPATCH="$ROOT/bin/fm-task-dispatch.sh"
STATE_CMD="$ROOT/bin/fm-task-state.sh"
RETIRE="$ROOT/bin/fm-task-retire.sh"
SESSION_ID=70001
REMOTE_TASK_ID=80001

TRACKED_HOMES="$TMP_ROOT/homes"
: >"$TRACKED_HOMES"
cleanup_remote() {
  local home
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done <"$TRACKED_HOMES"
  fm_test_cleanup
}
trap cleanup_remote EXIT

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  printf '%s\n' "$home" >>"$TRACKED_HOMES"
  printf '%s\n' "$home"
}

write_ida_config() {
  cat >"$1/config/ida-remote-agent" <<'EOF'
schema=fm-ida-remote-agent-config.v1
enabled=true
region=sg
identity=user
agent_id=9001
model=ida-research-test
bytedcli_version=0.128.0
EOF
  chmod 0600 "$1/config/ida-remote-agent"
}

new_task() {
  local home=$1 id=$2 content=${3:-"PRIVATE_PROMPT_alpha OECID_sensitive"}
  mkdir -p "$home/data/$id"
  printf '# Brief\n' >"$home/data/$id/brief.md"
  printf '%s\n' "$content" >"$home/data/$id/instructions.txt"
  chmod 0600 "$home/data/$id/instructions.txt"
}

state_file() { printf '%s/state/remote-tasks/%s/state.json\n' "$1" "$2"; }
phase_of() { jq -r '.phase' "$(state_file "$1" "$2")"; }

wait_phase() {
  local home=$1 id=$2 expected=$3 tries=${4:-300}
  while [ "$tries" -gt 0 ]; do
    [ -f "$(state_file "$home" "$id")" ] && [ "$(phase_of "$home" "$id")" = "$expected" ] && return 0
    sleep 0.03; tries=$((tries - 1))
  done
  fail "timed out waiting for $id phase=$expected"
}

make_fake_bytedcli() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat >"$fakebin/bytedcli" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_IDA_FAKE_LOG:?}
sessions=${FM_IDA_FAKE_SESSIONS:?}
mode=${FM_IDA_FAKE_MODE:-success}
session=${FM_IDA_FAKE_SESSION_ID:?}
remote_task=${FM_IDA_FAKE_TASK_ID:?}
printf 'argv:%s\n' "$*" >>"$log"
success() { printf '{"status":"success","data":%s,"error":null}\n' "$1"; }
error() { printf '{"status":"error","data":null,"error":{"code":"%s","message":"%s"}}\n' "$1" "$2"; }
args=" $* "
case "$args" in
  *" --version "*) success '{"version":"0.128.0"}' ;;
  *" mcp --allow-domains ida --all-tools "*)
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | jq -r '.id // empty' 2>/dev/null || true)
      method=$(printf '%s\n' "$line" | jq -r '.method // empty' 2>/dev/null || true)
      printf 'stdin-method:%s\n' "$method" >>"$log"
      case "$method" in
        initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"bytedcli","version":"0.128.0"}}}\n' "$request_id" ;;
        tools/call)
          marker=$(printf '%s\n' "$line" | jq -r '.params.arguments.name')
          printf 'tool:%s\n' "$(printf '%s\n' "$line" | jq -r '.params.name')" >>"$log"
          case "$mode" in
            timeout-created) printf '%s\t%s\trunning\n' "$session" "$marker" >"$sessions"; exit 124 ;;
            timeout-zero) exit 124 ;;
            explicit-auth) result='{"status":"error","data":null,"error":{"code":"AUTH_REQUIRED","message":"authentication required"}}' ;;
            zero) printf '%s\t%s\tcompleted\n' "$session" "$marker" >"$sessions"; result=$(printf '{"status":"success","data":{"session_id":%s,"task_id":%s,"created_session":true,"answer":""},"error":null}' "$session" "$remote_task") ;;
            *) printf '%s\t%s\tcompleted\n' "$session" "$marker" >"$sessions"; result=$(printf '{"status":"success","data":{"session_id":%s,"task_id":%s,"created_session":true,"answer":"%s"},"error":null}' "$session" "$remote_task" "${FM_IDA_FAKE_ANSWER:-Verified iDA answer. PRIVATE_PROMPT_alpha OECID_sensitive token=top-secret OECID=123456789012345678 user@example.com}") ;;
          esac
          text=$(printf '%s' "$result" | jq -Rs .)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":%s}],"isError":false}}\n' "$request_id" "$text"
          ;;
      esac
    done
    ;;
  *" ida --region sg session list "*)
    case "$mode" in list-unavailable) error HTTP_503 'service unavailable'; exit 1 ;; esac
    rows="[]"
    if [ -s "$sessions" ]; then
      rows=$(awk -F '\t' '{printf "{\"id\":%s,\"name\":\"%s\",\"agent_id\":9001,\"agent_name\":\"iDA Test\",\"latest_task_status\":\"%s\"}\n",$1,$2,$3}' "$sessions" | jq -s .)
    fi
    jq -cn --argjson rows "$rows" --argjson truncated "$([ "$mode" = truncated ] && echo true || echo false)" '{status:"success",data:{sessions:$rows,current_count:($rows|length),page:1,page_size:100,truncated:$truncated},error:null}'
    ;;
  *" ida --region sg session get "*)
    [ "$mode" != list-unavailable ] || { error HTTP_503 'service unavailable'; exit 1; }
    row=$(head -1 "$sessions" 2>/dev/null || true); [ -n "$row" ] || { error HTTP_404 'not found'; exit 1; }
    name=$(printf '%s' "$row" | cut -f2); status=$(printf '%s' "$row" | cut -f3)
    case "$mode" in running) status=running ;; failed) status=failed ;; cancelled) status=cancelled ;; ambiguous-status) status=mystery_state ;; zero) status=completed ;; esac
    if [ "$status" = completed ] && [ "$mode" != zero ]; then messages='[{"id":91,"type":8,"status":1,"visible":true,"text":"Verified iDA answer."}]'; else messages='[]'; fi
    jq -cn --argjson sid "$session" --arg name "$name" --arg status "$status" --argjson messages "$messages" '{status:"success",data:{session:{id:$sid,name:$name,agent_id:9001,agent_name:"iDA Test",latest_task_status:$status},messages:$messages,queue_locked:false,queue_tasks:[]},error:null}'
    ;;
  *" ida --region sg chat completion close "*)
    [ -s "$sessions" ] || { error HTTP_404 'not found'; exit 1; }
    awk -F '\t' 'BEGIN{OFS="\t"}{$3="cancelled";print}' "$sessions" >"$sessions.tmp" && mv "$sessions.tmp" "$sessions"
    success '{"result":true}'
    ;;
  *) error UNKNOWN_COMMAND "unsupported fake invocation: $*"; exit 1 ;;
esac
SH
  chmod +x "$fakebin/bytedcli"
  printf '%s\n' "$fakebin"
}

run_ida() {
  local home=$1 fakebin=$2; shift 2
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
  FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
  FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
  FM_IDA_FAKE_MODE="${FM_IDA_FAKE_MODE:-success}" PATH="$fakebin:$BASE_PATH" "$IDA" "$@"
}

dispatch_ida() { run_ida "$1" "$2" dispatch "$3" --instructions "$1/data/$3/instructions.txt"; }

test_dispatch_success_and_redaction() {
  local home fakebin id=ida-success log report snapshot
  home=$(new_home success); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "iDA dispatch failed"
  wait_phase "$home" "$id" terminal-success || fail "iDA dispatch did not complete"
  assert_grep 'executor=remote-agent' "$home/state/$id.meta" "iDA metadata did not select remote-agent"
  assert_grep 'provider=ida' "$home/state/$id.meta" "iDA provider metadata missing"
  log="$home/bytedcli.log"; report="$home/data/$id/report.md"
  assert_grep 'mcp --allow-domains ida --all-tools' "$log" "iDA did not use official bytedcli MCP"
  if grep '^argv:' "$log" | grep -F 'PRIVATE_PROMPT_alpha' >/dev/null; then fail "private prompt leaked into argv"; fi
  assert_no_grep 'PRIVATE_PROMPT_alpha' "$log" "private prompt leaked into provider command logs"
  if grep -R -F 'PRIVATE_PROMPT_alpha' "$home/state" "$report" >/dev/null; then fail "private prompt leaked into state/report"; fi
  if grep -R -E 'top-secret|123456789012345678|user@example.com' "$home/state" "$report" >/dev/null; then fail "credential, OECID, or PII leaked into normalized state/report"; fi
  assert_grep '[REDACTED' "$report" "sensitive final-answer fields were not visibly redacted"
  assert_grep 'Verified iDA answer' "$report" "iDA final answer was not captured"
  assert_grep 'done: iDA remote research complete' "$home/state/$id.status" "terminal result did not route through durable task status"
  assert_grep "procevent ida ida-$id" "$home/state/.wake-queue" "iDA completion did not route through the durable process-event wake"
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep 'Result availability: `available`' "$report" "available result distinction missing"
  snapshot=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fleet snapshot could not read a terminal iDA task"
  printf '%s\n' "$snapshot" | jq -e --arg id "$id" '
    .tasks[] | select(.id == $id)
    | .executor == "remote-agent"
      and .provider == "ida"
      and .current_state.state == "done"
      and .current_state.source == "remote-state"
      and .endpoint.status == "not_applicable"
      and .paths.remote_state.present == true
      and .paths.report.present == true
  ' >/dev/null || fail "fleet snapshot did not preserve native remote-agent state/report/endpoint semantics"
  pass "iDA dispatch uses stdin MCP, publishes remote metadata, captures a report, and redacts the prompt"
}

test_provider_states_and_zero_result() {
  local home fakebin id out
  home=$(new_home states); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  id=ida-zero; new_task "$home" "$id"; : >"$home/sessions.tsv"
  FM_IDA_FAKE_MODE=zero dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "zero-result dispatch failed"
  wait_phase "$home" "$id" terminal-success
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep 'Result availability: `zero`' "$home/data/$id/report.md" "zero result was conflated"

  id=ida-live; new_task "$home" "$id"; marker="firstmate:$id:1234567890abcdef"
  sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}'); marker="firstmate:$id:${sha:0:16}"
  printf '%s\t%s\trunning\n' "$SESSION_ID" "$marker" >"$home/sessions.tsv"
  provider=$(jq -cn --arg marker "$marker" '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:null,agent_id:"9001",agent_name:null,model:"ida-research-test",provider_status:"running"}')
  FM_HOME="$home" bash -c '. "$1/bin/fm-remote-agent-lib.sh"; STATE="$2/state"; DATA="$2/data"; fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" 0.128.0 "$5"; fm_remote_meta_write "$3" ida research' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "state fixture failed"
  staged="$home/state-$id.json"
  jq '.phase="running" | .provider_checkpoint="provider-running"' "$(state_file "$home" "$id")" >"$staged"
  chmod 0600 "$staged"; mv "$staged" "$(state_file "$home" "$id")"
  FM_IDA_FAKE_MODE=running out=$(run_ida "$home" "$fakebin" state "$id")
  assert_contains "$out" 'state: working' "running iDA state was not healthy"
  FM_IDA_FAKE_MODE=failed out=$(run_ida "$home" "$fakebin" state "$id")
  assert_contains "$out" 'state: failed' "failed iDA state was not reported"
  FM_IDA_FAKE_MODE=cancelled out=$(run_ida "$home" "$fakebin" state "$id")
  assert_contains "$out" 'state: failed' "cancelled iDA state was not reported"
  FM_IDA_FAKE_MODE=list-unavailable out=$(FM_IDA_FAKE_MODE=list-unavailable run_ida "$home" "$fakebin" state "$id")
  assert_contains "$out" 'state: unknown' "unavailable iDA state was not distinguished"
  FM_IDA_FAKE_MODE=ambiguous-status out=$(run_ida "$home" "$fakebin" state "$id")
  assert_contains "$out" 'state: blocked' "ambiguous iDA status was not blocked"
  pass "iDA current-state distinguishes running, failed, cancelled, unavailable, ambiguous, and exact-zero results"
}

test_timeout_reconciliation_and_no_duplicate() {
  local home fakebin id=ida-timeout creates
  home=$(new_home timeout); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/sessions.tsv"; : >"$home/bytedcli.log"
  FM_IDA_FAKE_MODE=timeout-created dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "timeout-created dispatch setup failed"
  wait_phase "$home" "$id" running || fail "timeout-created session was not reconciled"
  run_ida "$home" "$fakebin" interrupt-wait "$id" >/dev/null || fail "timeout fixture waiter cleanup failed"
  FM_IDA_FAKE_MODE=running run_ida "$home" "$fakebin" adopt "$id" >/dev/null || fail "timeout fixture adoption failed"
  sleep 0.2
  creates=$(grep -F -c 'tool:ida_deep_research_create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 1 ] || fail "timeout reconciliation created a duplicate remote session"
  run_ida "$home" "$fakebin" interrupt-wait "$id" >/dev/null || true
  pass "ambiguous timeout reconciles the durable marker and adoption never creates a duplicate session"
}

test_pre_submission_unavailable_recovers_without_duplicate() {
  local home fakebin id=ida-preflight creates tries=300
  home=$(new_home preflight-unavailable); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/sessions.tsv"; : >"$home/bytedcli.log"
  FM_IDA_FAKE_MODE=list-unavailable dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "unavailable preflight dispatch setup failed"
  while [ "$tries" -gt 0 ] && ! find "$home/state/remote-tasks/$id/artifacts" -type f -name '*-observation.json' -print -quit 2>/dev/null | grep -q .; do
    sleep 0.03; tries=$((tries - 1))
  done
  [ "$tries" -gt 0 ] || fail "pre-submission unavailable observation was not handled"
  [ "$(phase_of "$home" "$id")" = submission-not-started ] || fail "pre-submission unavailability lost the safe not-started checkpoint"
  run_ida "$home" "$fakebin" interrupt-wait "$id" >/dev/null || fail "preflight waiter cleanup failed"
  FM_IDA_FAKE_MODE=success run_ida "$home" "$fakebin" adopt "$id" >/dev/null || fail "preflight recovery adoption failed"
  wait_phase "$home" "$id" terminal-success || fail "preflight recovery did not submit after provider recovered"
  creates=$(grep -F -c 'tool:ida_deep_research_create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 1 ] || fail "preflight recovery issued an unsafe number of creates"
  pass "pre-submission provider unavailability preserves the safe checkpoint and recovers with one create"
}

test_cancellation_and_retirement_authority() {
  local home fakebin id=ida-cancel rc=0
  home=$(new_home cancel); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/sessions.tsv"; FM_IDA_FAKE_MODE=timeout-created dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "cancel fixture dispatch failed"
  wait_phase "$home" "$id" running || fail "cancel fixture did not run"
  run_ida "$home" "$fakebin" cancel "$id" >"$home/unauthorized.out" 2>"$home/unauthorized.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "iDA cancellation lacked an authority gate"
  assert_grep 'requires --authorize-provider-cancel' "$home/unauthorized.err" "cancellation gate missing"
  FM_IDA_FAKE_MODE=cancelled run_ida "$home" "$fakebin" cancel "$id" --authorize-provider-cancel >/dev/null || fail "authorized iDA cancellation failed"
  wait_phase "$home" "$id" terminal-cancelled || fail "cancellation did not reach terminal-cancelled"
  rc=0; FM_HOME="$home" "$RETIRE" "$id" >"$home/retire.out" 2>"$home/retire.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "retirement bypassed the decision gate"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"
  FM_HOME="$home" "$RETIRE" "$id" >/dev/null || fail "decision-complete iDA retirement failed"
  assert_absent "$home/state/$id.meta" "retirement retained iDA metadata"
  assert_present "$home/data/$id/report.md" "retirement removed durable iDA report"
  pass "iDA cancellation needs explicit authority and retirement preserves report plus decision safety"
}

test_aime_compatibility_and_local_unchanged() {
  local home fakebin out
  home=$(new_home compatibility); fakebin=$(make_fake_bytedcli "$home")
  mkdir -p "$home/state/cloud-tasks/legacy-aime"
  cat >"$home/state/legacy-aime.meta" <<EOF
kind=scout
executor=cloud-worker
provider=aime
task_type=research
cloud_state=$home/state/cloud-tasks/legacy-aime
EOF
  chmod 0600 "$home/state/legacy-aime.meta"
  cat >"$home/state/cloud-tasks/legacy-aime/state.json" <<'EOF'
{"schema":"fm-aime-task-state.v1","task_id":"legacy-aime","executor":"cloud-worker","provider":"aime","revision":1,"phase":"terminal-failure","site":"cn","space_id":"11111111-1111-4111-8111-111111111111","identity":"user","result_mode":"research","instruction_file":"/tmp/legacy","instruction_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bytedcli_version":"0.124.0","session_id":null,"message_id":null,"event_cursor":0,"outcome":"failed","error_class":"auth","provider_checkpoint":"create-rejected","waiter":"not-armed","result_path":null,"report_path":null,"document":null,"created_at":"2026-08-14T00:00:00Z","updated_at":"2026-08-14T00:00:00Z"}
EOF
  chmod 0600 "$home/state/cloud-tasks/legacy-aime/state.json"
  out=$(FM_HOME="$home" "$STATE_CMD" legacy-aime)
  assert_contains "$out" 'source: cloud-state' "legacy AIME metadata was not readable"

  cat >"$fakebin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'local-spawn:%s\n' "$*"
SH
  chmod +x "$fakebin/fm-spawn.sh"
  # The public dispatch wrapper uses its sibling, so verify unchanged local
  # behavior through the existing dedicated AIME suite's stubbed ROOT copy.
  [ "$($DISPATCH unsupported/task sample 2>&1 || true)" = 'error: unsupported task executor: unsupported/task' ] || fail "executor error behavior drifted"
  pass "legacy cloud-worker/AIME records remain readable and unrelated executor routing stays fail-closed"
}

test_remote_aime_dispatch_metadata() {
  local home fakebin id=remote-aime trigger
  home=$(new_home remote-aime); fakebin=$(fm_fakebin "$home-aime")
  mkdir -p "$home/config"; trigger="$home/never-terminal"
  cat >"$home/config/aime-cloud-worker" <<'EOF'
schema=fm-aime-cloud-worker-config.v1
enabled=true
site=cn
space_id=11111111-1111-4111-8111-111111111111
identity=user
sandbox_verified_version=0.124.0
sandbox_verified_at=2026-08-14T00:00:00Z
sandbox_verification=disposable-session-readback
EOF
  chmod 0600 "$home/config/aime-cloud-worker"; new_task "$home" "$id"
  cat >"$fakebin/bytedcli" <<'SH'
#!/usr/bin/env bash
set -u
args=" $* "; space=11111111-1111-4111-8111-111111111111; session=22222222-2222-4222-8222-222222222222
success(){ printf '{"status":"success","data":%s,"error":null}\n' "$1"; }
case "$args" in
 *" --version "*) success '{"version":"0.124.0"}' ;;
 *" aime space list "*) success "{\"spaces\":[{\"id\":\"$space\",\"status\":\"active\",\"permission_actions\":[\"space.read\",\"session.create\"]}]}" ;;
 *" aime space get "*) success "{\"id\":\"$space\",\"name\":\"space\",\"status\":\"active\"}" ;;
 *" aime session create "*) success "{\"id\":\"$session\",\"source_space_id\":\"$space\"}" ;;
 *" aime session send "*) success "{\"session_id\":\"$session\",\"auto_session_created\":false,\"message\":{\"message_id\":\"message-3333\"}}" ;;
 *" aime session replay-events "*) while [ ! -e "${FM_AIME_TRIGGER:?}" ]; do sleep 0.05; done ;;
 *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/bytedcli"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" FM_AIME_TRIGGER="$trigger" PATH="$fakebin:$BASE_PATH" \
    "$DISPATCH" remote-agent/aime "$id" --instructions "$home/data/$id/instructions.txt" >/dev/null || fail "remote-agent/AIME dispatch failed"
  assert_grep 'executor=remote-agent' "$home/state/$id.meta" "remote AIME metadata kept the legacy discriminator"
  [ "$(jq -r '.executor' "$home/state/cloud-tasks/$id/state.json")" = remote-agent ] || fail "remote AIME state did not record the new executor"
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-remote-agent-aime.sh" interrupt-wait "$id" >/dev/null || fail "remote AIME waiter cleanup failed"
  pass "new AIME tasks explicitly select remote-agent while the legacy schema and lifecycle remain intact"
}

test_dispatch_success_and_redaction
test_provider_states_and_zero_result
test_timeout_reconciliation_and_no_duplicate
test_pre_submission_unavailable_recovers_without_duplicate
test_cancellation_and_retirement_authority
test_aime_compatibility_and_local_unchanged
test_remote_aime_dispatch_metadata
printf '# fm-remote-agent.test.sh: all assertions passed\n'
