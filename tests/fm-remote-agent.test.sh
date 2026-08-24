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
EOF
  chmod 0600 "$1/config/ida-remote-agent"
}

write_legacy_ida_version() {
  printf 'bytedcli_version=%s\n' "$2" >>"$1/config/ida-remote-agent"
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
if [ "${FM_IDA_FAKE_REQUIRE_CLEAN_PROXY:-0}" = 1 ]; then
  for proxy_name in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    printenv "$proxy_name" >/dev/null 2>&1 && { error PROXY_PRESENT "ambient proxy reached bytedcli"; exit 1; }
  done
  [ "${FM_IDA_FAKE_SENTINEL:-}" = preserved ] || { error ENV_LOST "unrelated environment was not preserved"; exit 1; }
fi
args=" $* "
case "$args" in
  *" --version "*) error UNEXPECTED_VERSION_PROBE 'iDA must not probe bytedcli version'; exit 1 ;;
  *" mcp --allow-domains ida "*)
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | jq -r '.id // empty' 2>/dev/null || true)
      method=$(printf '%s\n' "$line" | jq -r '.method // empty' 2>/dev/null || true)
      printf 'stdin-method:%s\n' "$method" >>"$log"
      case "$method" in
        initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"bytedcli","version":"0.128.0"}}}\n' "$request_id" ;;
        tools/call)
          tool=$(printf '%s\n' "$line" | jq -r '.params.name')
          printf 'tool:%s\n' "$tool" >>"$log"
          if [ "$tool" = list_commands ]; then
            text=$(printf '%s' 'bytedcli ida deep-research create — Options: --content <text> --name <name> --timeout-ms <milliseconds>
bytedcli ida session raw list — Options: --agent-id <id>
bytedcli ida session get — Options: --session-id <id>
bytedcli ida chat completion close — Options: --session-id <id>' | jq -Rs .)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":%s}],"isError":false}}\n' "$request_id" "$text"
            continue
          fi
          [ "$tool" = run_command ] || exit 19
          command=$(printf '%s\n' "$line" | jq -r '.params.arguments.command')
          eval "set -- $command"
          [ "$#" -ge 10 ] && [ "$1" = ida ] && [ "$2" = --region ] && [ "$3" = sg ] \
            && [ "$4" = deep-research ] && [ "$5" = create ] && [ "$6" = --content ] \
            && [ "$8" = --name ] && [ "${10}" = --timeout-ms ] || {
              result='{"status":"error","data":null,"error":{"code":"CLI_PARSE_ERROR","message":"SG region was not placed on the parent iDA command"}}'
              text=$(printf '%s' "$result" | jq -Rs .)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":%s}],"isError":false}}\n' "$request_id" "$text"
              continue
            }
          marker=$9
          case "$7" in "[Firstmate session marker: $marker]"$'\n\n'*) ;; *) exit 20 ;; esac
          printf 'command:ida-region-sg-deep-research-create\n' >>"$log"
          case "$mode" in
            timeout-created) printf '%s\t%s\trunning\t%s\n' "$session" "$marker" "$marker" >"$sessions"; exit 124 ;;
            timeout-zero) exit 124 ;;
            explicit-auth) result='{"status":"error","data":null,"error":{"code":"AUTH_REQUIRED","message":"authentication required"}}' ;;
            renamed-empty)
              printf '%s\tprovider-renamed\tcompleted\t%s\n' "$session" "$marker" >"$sessions"
              result=$(printf '{"status":"error","data":null,"error":{"code":"IDA_EMPTY_RESULT","message":"completed without an answer","details":{"session_id":%s,"task_id":%s}}}' "$session" "$remote_task")
              mcp_error=true
              ;;
            zero) printf '%s\t%s\tcompleted\t%s\n' "$session" "$marker" "$marker" >"$sessions"; result=$(printf '{"status":"success","data":{"session_id":%s,"task_id":%s,"created_session":true,"answer":""},"error":null}' "$session" "$remote_task") ;;
            *) printf '%s\t%s\tcompleted\t%s\n' "$session" "$marker" "$marker" >"$sessions"; result=$(printf '{"status":"success","data":{"session_id":%s,"task_id":%s,"created_session":true,"answer":"%s"},"error":null}' "$session" "$remote_task" "${FM_IDA_FAKE_ANSWER:-Verified iDA answer. PRIVATE_PROMPT_alpha OECID_sensitive token=top-secret OECID=123456789012345678 user@example.com}") ;;
          esac
          mcp_error=${mcp_error:-false}
          text=$(printf '%s' "$result" | jq -Rs .)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":%s}],"isError":%s}}\n' "$request_id" "$text" "$mcp_error"
          ;;
      esac
    done
    ;;
  *" ida --region sg agent get "*)
    success '{"id":9001,"name":"iDA Test","deep_research_enabled":true}'
    ;;
  *" ida --region sg session raw list "*)
    case "$mode" in list-unavailable) error HTTP_503 'service unavailable'; exit 1 ;; esac
    rows="[]"
    if [ -s "$sessions" ]; then
      rows=$(awk -F '\t' -v created="$(date -u '+%Y-%m-%d %H:%M:%S')" '{printf "{\"id\":%s,\"name\":\"%s\",\"agentInfo\":{\"id\":9001,\"name\":\"iDA Test\"},\"latestTaskStatus\":\"%s\",\"createTime\":\"%s\"}\n",$1,$2,$3,created}' "$sessions" | jq -s .)
    fi
    if [ "$mode" = truncated ]; then
      while [ "$(printf '%s\n' "$rows" | jq 'length')" -lt 100 ]; do rows=$(printf '%s\n' "$rows" | jq '. + [{id:(90000+length),name:"other",agentInfo:{id:9001,name:"iDA Test"},latestTaskStatus:"completed",createTime:"2020-01-01 00:00:00"}]'); done
    fi
    jq -cn --argjson rows "$rows" '{status:"success",data:{sessions:{sessionList:$rows,page:1,page_size:100}},error:null}'
    ;;
  *" ida --region sg session get "*)
    [ "$mode" != list-unavailable ] || { error HTTP_503 'service unavailable'; exit 1; }
    row=$(head -1 "$sessions" 2>/dev/null || true); [ -n "$row" ] || { error HTTP_404 'not found'; exit 1; }
    name=$(printf '%s' "$row" | cut -f2); status=$(printf '%s' "$row" | cut -f3); marker=$(printf '%s' "$row" | cut -f4)
    [ -n "$marker" ] || marker=$name
    case "$mode" in running) status=running ;; failed) status=failed ;; cancelled) status=cancelled ;; ambiguous-status) status=mystery_state ;; zero) status=completed ;; esac
    user="[Firstmate session marker: $marker]"$'\n\n'"PRIVATE_PROMPT_alpha OECID_sensitive"
    if [ "$status" = completed ] && [ "$mode" != zero ] && [ "$mode" != renamed-empty ]; then answer=${FM_IDA_FAKE_ANSWER:-'Verified iDA answer. PRIVATE_PROMPT_alpha OECID_sensitive token=top-secret OECID=123456789012345678 user@example.com'}; else answer=''; fi
    jq -cn --argjson sid "$session" --arg name "$name" --arg status "$status" --arg user "$user" --arg answer "$answer" '
      {status:"success",data:{session:{id:$sid,name:$name,agent_id:9001,agent_name:"iDA Test",latest_task_status:$status},
       messages:([{id:90,type:0,status:0,visible:true,text:$user}]
         + (if $answer=="" then [] else [{id:91,type:8,status:1,visible:true,text:$answer}] end)),
       queue_locked:false,queue_tasks:[]},error:null}'
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

dispatch_ida() {
  local home=$1 fakebin=$2 id=$3
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
  FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
  FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
  FM_IDA_FAKE_MODE="${FM_IDA_FAKE_MODE:-success}" PATH="$fakebin:$BASE_PATH" \
    "$DISPATCH" remote-agent/ida "$id" --instructions "$home/data/$id/instructions.txt"
}

test_dispatch_success_and_redaction() {
  local home fakebin id=ida-success log report snapshot result seq replay revision
  home=$(new_home success); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "iDA dispatch failed"
  wait_phase "$home" "$id" terminal-success || fail "iDA dispatch did not complete"
  assert_grep 'executor=remote-agent' "$home/state/$id.meta" "iDA metadata did not select remote-agent"
  assert_grep 'provider=ida' "$home/state/$id.meta" "iDA provider metadata missing"
  jq -e 'has("bytedcli_version") | not' "$(state_file "$home" "$id")" >/dev/null \
    || fail "new iDA durable state still records a bytedcli version"
  log="$home/bytedcli.log"; report="$home/data/$id/report.md"
  assert_grep 'mcp --allow-domains ida' "$log" "iDA did not use official domain-restricted bytedcli MCP"
  assert_no_grep 'all-tools' "$log" "iDA used named MCP tools that cannot bind SG region"
  assert_grep 'tool:run_command' "$log" "iDA did not use the official MCP command runner"
  assert_grep 'command:ida-region-sg-deep-research-create' "$log" "iDA did not place SG region on the parent command"
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
  result=$(find "$home/state/procevent-inbox" -name "ida-$id.*.result" -print -quit)
  seq=${result%.result}; seq=${seq##*.}; revision=$(jq -r '.revision' "$(state_file "$home" "$id")")
  replay=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent-ida.sh" autohandle "ida-$id" "$seq" "$result") || fail "iDA handled replay failed"
  assert_contains "$replay" 'duplicate=true' "iDA handled replay was applied twice"
  [ "$(jq -r '.revision' "$(state_file "$home" "$id")")" = "$revision" ] || fail "iDA handled replay mutated terminal state"
  pass "public iDA dispatch uses private SG MCP, captures a redacted report, and handles replay idempotently"
}

test_legacy_version_and_proxy_do_not_block_readiness() {
  local home fakebin id=ida-legacy-version out
  home=$(new_home legacy-version); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  write_legacy_ida_version "$home" 0.0.0-stale
  new_task "$home" "$id"; : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  out=$(http_proxy=http://proxy.invalid https_proxy=http://proxy.invalid all_proxy=socks://proxy.invalid no_proxy=localhost \
    HTTP_PROXY=http://proxy.invalid HTTPS_PROXY=http://proxy.invalid ALL_PROXY=socks://proxy.invalid NO_PROXY=localhost \
    FM_IDA_FAKE_REQUIRE_CLEAN_PROXY=1 FM_IDA_FAKE_SENTINEL=preserved run_ida "$home" "$fakebin" probe) \
    || fail "stale-version iDA probe was not ready"
  printf '%s\n' "$out" | jq -e '
    .outcome == "ready" and .region == "sg" and .identity == "user"
    and (.capabilities | index("deep-research.create") != null)
    and (has("bytedcli_version") | not)
  ' >/dev/null || fail "iDA probe did not preserve readiness checks without a version contract"
  assert_grep 'tool:list_commands' "$home/bytedcli.log" "iDA probe did not verify the required command capability"
  if http_proxy=http://proxy.invalid https_proxy=http://proxy.invalid all_proxy=socks://proxy.invalid no_proxy=localhost \
      HTTP_PROXY=http://proxy.invalid HTTPS_PROXY=http://proxy.invalid ALL_PROXY=socks://proxy.invalid NO_PROXY=localhost \
      FM_IDA_FAKE_REQUIRE_CLEAN_PROXY=1 FM_IDA_FAKE_SENTINEL=preserved \
      dispatch_ida "$home" "$fakebin" "$id" >/dev/null; then :; else fail "public dispatch refused stale legacy version metadata or ambient proxy input"; fi
  wait_phase "$home" "$id" terminal-success || fail "public direct dispatch was not ready after proxy sanitation"
  assert_no_grep '--version' "$home/bytedcli.log" "iDA still probed or compared an exact bytedcli version"
  pass "stale legacy config versions and ambient proxies do not block probed public iDA direct dispatch"
}

test_provider_rename_and_structured_empty_result() {
  local home fakebin id=ida-renamed-empty
  home=$(new_home renamed-empty); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  new_task "$home" "$id"; : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  FM_IDA_FAKE_MODE=renamed-empty dispatch_ida "$home" "$fakebin" "$id" >/dev/null \
    || fail "renamed empty-result public dispatch failed"
  wait_phase "$home" "$id" terminal-success || fail "renamed empty-result did not normalize terminal success"
  jq -e --arg sid "$SESSION_ID" --arg task "$REMOTE_TASK_ID" '
    .result_availability == "zero"
    and .provider_state.session_id == $sid
    and .provider_state.task_id == $task
  ' "$(state_file "$home" "$id")" >/dev/null || {
    jq -c '{phase,result_availability,provider_state}' "$(state_file "$home" "$id")" >&2
    fail "structured empty-result identity was not preserved"
  }
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep 'Result availability: `zero`' "$home/data/$id/report.md" "structured empty result was not reported exactly"
  assert_grep 'session raw list' "$home/bytedcli.log" "provider rename recovery did not use raw sessions"
  assert_grep 'session get' "$home/bytedcli.log" "provider rename recovery did not exact-check the private marker"
  pass "provider renaming and structured empty-result errors retain exact identity and normalize to zero"
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
  FM_HOME="$home" bash -c '. "$1/bin/fm-remote-agent-lib.sh"; STATE="$2/state"; DATA="$2/data"; fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5"; fm_remote_meta_write "$3" ida research' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "state fixture failed"
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
  creates=$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)
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
  creates=$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 1 ] || fail "preflight recovery issued an unsafe number of creates"
  pass "pre-submission provider unavailability preserves the safe checkpoint and recovers with one create"
}

test_artifact_store_idempotency() {
  local home id=ida-store sha provider rc=0
  home=$(new_home store)
  mkdir -p "$home/data/$id"
  printf 'PRIVATE_PROMPT_alpha\n' >"$home/data/$id/instructions.txt"; chmod 0600 "$home/data/$id/instructions.txt"
  sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}')
  provider=$(jq -cn --arg marker "firstmate:$id:${sha:0:16}" '{region:"sg",identity:"user",session_marker:$marker,session_id:null,task_id:null,agent_id:null,agent_name:null,model:null,provider_status:null}')
  FM_HOME="$home" bash -c '
    set -u
    . "$1/bin/fm-remote-agent-lib.sh"
    STATE="$2/state"; DATA="$2/data"; id=$3
    fm_remote_state_initialize "$id" ida research "$2/data/$id/instructions.txt" "$4" "$5" || exit 10
    printf "same-bytes\n" >"$2/a.json"; printf "same-bytes\n" >"$2/b.json"; printf "other-bytes\n" >"$2/c.json"
    first=$(fm_remote_artifact_store "$id" observation "$2/a.json") || exit 11
    again=$(fm_remote_artifact_store "$id" observation "$2/b.json") || exit 12
    [ "$first" = "$again" ] || exit 13
    fm_remote_artifact_store "$id" observation "$2/c.json" >/dev/null 2>&1 && exit 14
    exit 0
  ' _ "$ROOT" "$home" "$id" "$sha" "$provider"; rc=$?
  [ "$rc" -eq 0 ] || fail "remote artifact store idempotency drifted (rc=$rc)"
  assert_grep 'same-bytes' "$home/state/remote-tasks/$id/artifacts/1-observation.json" "idempotent re-store lost the identical artifact"
  pass "remote artifact store re-verifies identical content and refuses different content at the same revision"
}

test_abandon_after_authoritative_zero_match() {
  local home fakebin id=ida-abandon dup=ida-abandon-dup marker sha creates
  home=$(new_home abandon); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  new_task "$home" "$id"; : >"$home/sessions.tsv"; : >"$home/bytedcli.log"
  FM_IDA_FAKE_MODE=timeout-zero dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "abandon fixture dispatch failed"
  wait_phase "$home" "$id" ambiguous || fail "timeout-zero submission did not wedge ambiguous"
  run_ida "$home" "$fakebin" adopt "$id" >"$home/adopt.out" 2>"$home/adopt.err" && fail "adoption escaped a zero-match ambiguous task"
  assert_grep 'remains ambiguous' "$home/adopt.err" "ambiguous adoption refusal drifted"
  run_ida "$home" "$fakebin" abandon "$id" >"$home/abandon.out" 2>"$home/abandon.err" && fail "abandonment lacked an authority gate"
  assert_grep 'requires --authorize-abandon' "$home/abandon.err" "abandonment gate missing"
  FM_IDA_FAKE_MODE=timeout-zero run_ida "$home" "$fakebin" abandon "$id" --authorize-abandon >/dev/null || fail "authorized abandonment failed"
  [ "$(phase_of "$home" "$id")" = terminal-failure ] || fail "abandonment did not fail-terminal the durable record"
  assert_grep 'abandoned' "$home/data/$id/report.md" "abandonment report missing"
  assert_grep 'zero-match' "$home/data/$id/report.md" "abandonment report lost its proof boundary"
  assert_grep 'abandoned' "$home/state/$id.status" "abandonment did not route through durable task status"
  creates=$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 1 ] || fail "abandonment path issued another create"
  FM_HOME="$home" "$RETIRE" "$id" >/dev/null 2>&1 && fail "abandoned retirement bypassed the decision gate"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"
  FM_HOME="$home" "$RETIRE" "$id" >/dev/null || fail "decision-complete abandoned retirement failed"
  assert_absent "$home/state/$id.meta" "retirement retained abandoned iDA metadata"
  assert_present "$home/data/$id/report.md" "retirement removed the abandoned durable report"

  new_task "$home" "$dup"; : >"$home/sessions.tsv"
  sha=$(sha256sum "$home/data/$dup/instructions.txt" | awk '{print $1}'); marker="firstmate:$dup:${sha:0:16}"
  FM_IDA_FAKE_MODE=timeout-zero dispatch_ida "$home" "$fakebin" "$dup" >/dev/null || fail "duplicate-marker abandon fixture dispatch failed"
  wait_phase "$home" "$dup" ambiguous || fail "duplicate-marker fixture did not wedge ambiguous"
  printf '%s\t%s\tcompleted\n' "$SESSION_ID" "$marker" >"$home/sessions.tsv"
  printf '%s\t%s\tcompleted\n' "$((SESSION_ID + 1))" "$marker" >>"$home/sessions.tsv"
  FM_IDA_FAKE_MODE=success run_ida "$home" "$fakebin" abandon "$dup" --authorize-abandon >"$home/dup.out" 2>"$home/dup.err" \
    && fail "abandonment ignored a non-zero-match session list"
  assert_grep 'zero-match' "$home/dup.err" "abandonment proof refusal drifted"
  [ "$(phase_of "$home" "$dup")" = ambiguous ] || fail "refused abandonment mutated the durable record"
  run_ida "$home" "$fakebin" interrupt-wait "$dup" >/dev/null || true
  pass "iDA abandonment fail-terminals only after authoritative zero-match proof and never recreates"
}

test_cancellation_and_retirement_authority() {
  local home fakebin id=ida-cancel rc=0 out staged
  home=$(new_home cancel); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/sessions.tsv"; FM_IDA_FAKE_MODE=timeout-created dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "cancel fixture dispatch failed"
  wait_phase "$home" "$id" running || fail "cancel fixture did not run"
  run_ida "$home" "$fakebin" interrupt-wait "$id" >/dev/null || fail "legacy-state waiter cleanup failed"
  staged="$home/legacy-state.json"
  jq '.bytedcli_version="0.0.0-legacy"' "$(state_file "$home" "$id")" >"$staged"
  chmod 0600 "$staged"; mv "$staged" "$(state_file "$home" "$id")"
  FM_IDA_FAKE_MODE=running out=$(run_ida "$home" "$fakebin" state "$id")
  assert_contains "$out" 'state: working' "legacy bytedcli durable metadata blocked state reconciliation"
  FM_IDA_FAKE_MODE=running run_ida "$home" "$fakebin" adopt "$id" >/dev/null \
    || fail "legacy bytedcli durable metadata blocked adoption"
  run_ida "$home" "$fakebin" cancel "$id" >"$home/unauthorized.out" 2>"$home/unauthorized.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "iDA cancellation lacked an authority gate"
  assert_grep 'requires --authorize-provider-cancel' "$home/unauthorized.err" "cancellation gate missing"
  FM_IDA_FAKE_MODE=cancelled run_ida "$home" "$fakebin" cancel "$id" --authorize-provider-cancel >/dev/null || fail "authorized iDA cancellation failed"
  wait_phase "$home" "$id" terminal-cancelled || fail "cancellation did not reach terminal-cancelled"
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep 'Legacy bytedcli version: `0.0.0-legacy` (informational)' "$home/data/$id/report.md" \
    "legacy durable version was not retained as informational report metadata"
  rc=0; FM_HOME="$home" "$RETIRE" "$id" >"$home/retire.out" 2>"$home/retire.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "retirement bypassed the decision gate"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"
  FM_HOME="$home" "$RETIRE" "$id" >/dev/null || fail "decision-complete iDA retirement failed"
  assert_absent "$home/state/$id.meta" "retirement retained iDA metadata"
  assert_present "$home/data/$id/report.md" "retirement removed durable iDA report"
  pass "legacy version state remains readable through adoption, reconciliation, cancellation, and safe retirement"
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
test_legacy_version_and_proxy_do_not_block_readiness
test_provider_rename_and_structured_empty_result
test_provider_states_and_zero_result
test_timeout_reconciliation_and_no_duplicate
test_artifact_store_idempotency
test_abandon_after_authoritative_zero_match
test_pre_submission_unavailable_recovers_without_duplicate
test_cancellation_and_retirement_authority
test_aime_compatibility_and_local_unchanged
test_remote_aime_dispatch_metadata
printf '# fm-remote-agent.test.sh: all assertions passed\n'
