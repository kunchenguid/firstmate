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
EOF
  chmod 0600 "$1/config/ida-remote-agent"
}

write_legacy_ida_version() {
  printf 'bytedcli_version=%s\n' "$2" >>"$1/config/ida-remote-agent"
}

new_task() {
  local home=$1 id=$2 content=${3:-"PRIVATE_PROMPT_alpha OECID_sensitive"}
  mkdir -p "$home/data/$id"
  if [ ! -f "$home/data/backlog.md" ]; then
    printf '%s\n' '# Tasks' '' '## In flight' '' '## Queued' '' '## Done' >"$home/data/backlog.md"
  fi
  TASKS_AXI_BACKEND=markdown tasks-axi add "$id" "Remote research $id" --kind scout --start \
    --file "$home/data/backlog.md" >/dev/null || fail "could not add remote fixture task $id"
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
[ -z "${FM_IDA_FAKE_MODE_FILE:-}" ] || [ ! -f "$FM_IDA_FAKE_MODE_FILE" ] \
  || mode=$(sed -n '1p' "$FM_IDA_FAKE_MODE_FILE")
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
    if [ "${FM_IDA_FAKE_MCP_AUTH_FAIL:-0}" = 1 ]; then
      printf 'sso ticket expired: HTTP 401\n' >&2
      exit 1
    fi
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
            if [ "${FM_IDA_FAKE_NO_MODEL_CAPABILITY:-0}" = 1 ]; then model_option=; else model_option=' --model <name>'; fi
            if [ "${FM_IDA_FAKE_NO_FOLLOWUP:-0}" = 1 ]; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"no continuation capability"}],"isError":false}}\n' "$request_id"
              continue
            fi
            text=$(printf 'bytedcli ida deep-research create — Options: --content <text> --name <name>%s --timeout-ms <milliseconds>
bytedcli ida session raw list — Options: --agent-id <id>
bytedcli ida session get — Options: --session-id <id>
bytedcli ida deep-research list — Options: --session-id <id>
bytedcli ida deep-research get — Options: --session-id <id> --task-id <id>
bytedcli ida deep-research create — Options: --session-id <id> --no-wait
bytedcli ida chat completion close — Options: --session-id <id>' "$model_option" | jq -Rs .)
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
          selected_model=
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --model) selected_model=$2; shift 2 ;;
              *) shift ;;
            esac
          done
          printf 'command:ida-region-sg-deep-research-create\n' >>"$log"
          printf 'create-model:%s\n' "${selected_model:-omitted}" >>"$log"
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
            step-answer-only)
              printf '%s\t%s\tcompleted\t%s\n' "$session" "$marker" "$marker" >"$sessions"
              result=$(printf '{"status":"error","data":null,"error":{"code":"IDA_EMPTY_RESULT","message":"completed without a compact answer","details":{"session_id":%s,"task_id":%s}}}' "$session" "$remote_task")
              mcp_error=true
              ;;
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
  *" ida --region sg model list "*)
    success '{"models":[{"name":"ida-research-test"},{"name":"ida-explicit-test"}]}'
    ;;
  *" ida --region sg deep-research list "*)
    success '{"session":{"id":70001},"tasks":[{"task_id":80001,"terminal_status":"completed"}]}'
    ;;
  *" ida --region sg deep-research artifact list "*)
    case "$mode" in
      artifact-list-error) error HTTP_503 'service unavailable'; exit 1 ;;
      artifact-list-malformed) success '{"session_id":70001,"task_id":80001,"artifacts":"not-an-array"}'; exit 0 ;;
      artifact-list-missing) success '{"session_id":70001,"task_id":80001}'; exit 0 ;;
      artifact-list-mismatch) success '{"session_id":70002,"task_id":80001,"artifacts":[]}'; exit 0 ;;
      artifact-list-empty) success '{"session_id":70001,"task_id":80001,"artifacts":[]}'; exit 0 ;;
      artifact-list-partial) truncated=true ;;
      *) truncated=false ;;
    esac
    jq -cn --argjson truncated "$truncated" '
      {status:"success",data:{session_id:70001,task_id:80001,truncated:$truncated,artifacts:[{
        task_id:80001,artifact_id:"artifact-92",name:"research-output",description:"PRIVATE_DESCRIPTION_BODY",
        content_type:"document",files:[
          {name:"report.csv",mime_type:"text/csv",uri:"https://ida.example/artifact-92/report.csv",size:4242},
          {name:"analysis.js",mime_type:"text/javascript",uri:"https://ida.example/artifact-92/analysis.js",size:31337}
        ],tables:[{columns:["secret-column"],rows:[["PRIVATE_TABLE_CELL"]]}],
        text:"PRIVATE_DOCUMENT_TEXT",script:"PRIVATE_SCRIPT_BODY"
      }]},error:null}'
    ;;
  *" ida --region sg session raw list "*)
    case "$mode" in list-unavailable) error HTTP_503 'service unavailable'; exit 1 ;; esac
    if [ -n "${FM_IDA_FAKE_LIST_DONE_TASK:-}" ] \
        && mkdir "${FM_IDA_FAKE_LIST_DONE_CLAIM:?}" 2>/dev/null; then
      TASKS_AXI_BACKEND=markdown tasks-axi done "$FM_IDA_FAKE_LIST_DONE_TASK" \
        --file "$FM_HOME/data/backlog.md" >/dev/null \
        || { error FIXTURE_ERROR 'could not close task at list boundary'; exit 1; }
    fi
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
    case "$mode" in
      get-launch-126) printf 'PRIVATE_LOCAL_STDERR token=synthetic-secret\n' >&2; exit 126 ;;
      get-launch-127) printf 'PRIVATE_LOCAL_STDERR token=synthetic-secret\n' >&2; exit 127 ;;
      get-empty) printf 'PRIVATE_LOCAL_STDERR token=synthetic-secret\n' >&2; exit 0 ;;
      get-malformed) printf 'PRIVATE_LOCAL_STDOUT not-json\n'; exit 0 ;;
      get-multiple) printf '{}\n{}\n'; exit 0 ;;
      get-exit-error) success '{}'; exit 1 ;;
      get-structure) success '{"session":{"id":70001},"messages":{}}'; exit 0 ;;
      get-session-mismatch) success '{"session":{"id":70002},"messages":[]}'; exit 0 ;;
      get-stderr-unavailable) printf 'network request failed: HTTP 503 token=synthetic-secret\n' >&2; exit 1 ;;
      get-provider-error) error INTERNAL_ERROR 'temporary provider read failure'; exit 1 ;;
      get-unavailable) error HTTP_503 'service unavailable'; exit 1 ;;
      get-auth) error AUTH_REQUIRED 'authentication required'; exit 1 ;;
    esac
    [ "$mode" != list-unavailable ] || { error HTTP_503 'service unavailable'; exit 1; }
    row=$(head -1 "$sessions" 2>/dev/null || true); [ -n "$row" ] || { error HTTP_404 'not found'; exit 1; }
    name=$(printf '%s' "$row" | cut -f2); status=$(printf '%s' "$row" | cut -f3); marker=$(printf '%s' "$row" | cut -f4)
    [ -n "$marker" ] || marker=$name
    case "$mode" in
      running) status=running ;;
      failed) status=failed ;;
      cancelled) status=cancelled ;;
      ambiguous-status) status=mystery_state ;;
      zero|structured-artifact|structured-text|structured-empty|structured-malformed|structured-unsupported|step-answer-only) status=completed ;;
      failed-answered) status=failed ;;
      cancelled-answered) status=cancelled ;;
      closed-answered) status=closed ;;
      recorded-task-conflict|aggregate-error-running|aggregate-error-success|recorded-task-missing) status=error ;;
    esac
    user="[Firstmate session marker: $marker]"$'\n\n'"PRIVATE_PROMPT_alpha OECID_sensitive"
    if { [ "$status" = completed ] && [ "$mode" != zero ] && [ "$mode" != renamed-empty ] \
        && [ "$mode" != step-answer-only ] && [ "${mode#structured-}" = "$mode" ]; } \
      || [ "$mode" = failed-answered ] || [ "$mode" = cancelled-answered ] || [ "$mode" = closed-answered ]; then answer=${FM_IDA_FAKE_ANSWER:-'Verified iDA answer. PRIVATE_PROMPT_alpha OECID_sensitive token=top-secret OECID=123456789012345678 user@example.com'}; else answer=''; fi
    structured_answer=${FM_IDA_FAKE_ANSWER:-'FM_IDA_READINESS_V1 {"status":"ok","instruction_received":true,"business_data_accessed":false,"external_write_performed":false,"echo":"sg-ida-e2e-20260825-v1"}'}
    jq -cn --argjson sid "$session" --arg name "$name" --arg status "$status" --arg user "$user" \
      --arg answer "$answer" --arg structured_answer "$structured_answer" --arg mode "$mode" --arg task "$remote_task" '
      def task_status:
        if $mode=="aggregate-error-running" or $mode=="recorded-task-missing" then "running"
        elif $mode=="aggregate-error-success" or $mode=="recorded-task-conflict" then "success"
        else $status
        end;
      def recorded_task_message:
        {id:91,type:8,status:1,visible:true,
         deep_research_content:{taskId:$task,terminalStatus:task_status}};
      {status:"success",data:{session:{id:$sid,name:$name,agent_id:9001,agent_name:"iDA Test",latest_task_status:$status},
       messages:([{id:90,type:0,status:0,visible:true,text:$user}]
         + (if $answer=="" then [] else [(recorded_task_message + {text:$answer})] end)
         + (if $mode=="step-answer-only" then [{
             id:92,type:8,status:1,visible:true,
             deep_research_content:{taskId:$task,terminalStatus:task_status,
               steps:[
                 {id:1,status:1,content:""},
                 {id:2,status:1,content:($structured_answer + "\nAdditional provider text.")}
               ]}
           }]
           elif $mode=="structured-artifact" then [{
             id:92,type:8,status:1,visible:true,
             deep_research_content:{taskId:$task,terminalStatus:task_status,finalAnswer:[{artifact:{
               artifactId:"PRIVATE_ARTIFACT_ID_92",name:"PRIVATE_ARTIFACT_NAME_92",
               parts:[
                 {type:"file",file:{fileUri:"PRIVATE_FILE_URI_92",fileName:"PRIVATE_FILE_NAME_92",mimeType:"application/json"}},
                 {type:"data",data:{sheets:[{name:"PRIVATE_SHEET_92",rows:[["PRIVATE_CELL_92"]]}],rawBytes:"PRIVATE_ARTIFACT_BYTES_92"}}
               ]
             }}]}
           }]
           elif $mode=="structured-text" or $mode=="aggregate-error-success" or $mode=="recorded-task-conflict" then [{
             id:92,type:8,status:1,visible:true,
             deep_research_content:{taskId:$task,terminalStatus:task_status,
               finalAnswer:[{result:{answer:$structured_answer}}]}
           }]
           elif $mode=="structured-empty" then [{
             id:92,type:8,status:1,visible:true,
             deep_research_content:{taskId:$task,terminalStatus:task_status,
               finalAnswer:[{artifact:{parts:[{type:"file",file:{}},{type:"data",data:{}}]}}]}
           }]
           elif $mode=="structured-malformed" then [{
             id:92,type:8,status:1,visible:true,
             deep_research_content:{taskId:$task,terminalStatus:task_status,
               finalAnswer:[{artifact:{parts:"PRIVATE_MALFORMED_PARTS_92"}}]}
           }]
           elif $mode=="structured-unsupported" then [{
             id:92,type:8,status:1,visible:true,
             deep_research_content:{taskId:$task,terminalStatus:task_status,
               finalAnswer:[{artifact:{parts:[{type:"image",image:{bytes:"PRIVATE_UNSUPPORTED_BYTES_92"}}]}}]}
           }]
           elif $mode=="recorded-task-missing" then [{
             id:92,type:8,status:1,visible:true,
             deep_research_content:{taskId:(($task|tonumber)+1|tostring),terminalStatus:"success",
               finalAnswer:[{answer:"PRIVATE_OTHER_TASK_ANSWER"}]}
           }]
           else [] end)
         + (if $answer=="" and ($mode | startswith("structured-") | not)
                and $mode!="aggregate-error-success" and $mode!="recorded-task-conflict"
                and $mode!="recorded-task-missing" then
              [{id:91,type:8,status:1,visible:true,
                deep_research_content:{taskId:$task,terminalStatus:task_status,finalAnswer:[]}}]
            else [] end)
         + (if $mode=="recorded-task-conflict" then [{
             id:93,type:8,status:1,visible:true,
             deep_research_content:{taskId:(($task|tonumber)+1|tostring),terminalStatus:"error",
               finalAnswer:[{answer:"PRIVATE_OTHER_TASK_ANSWER"}]}
           }] else [] end)),
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
  shift 3
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
  FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
  FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
  FM_IDA_FAKE_MODE="${FM_IDA_FAKE_MODE:-success}" PATH="$fakebin:$BASE_PATH" \
    "$DISPATCH" remote-agent/ida "$id" --instructions "$home/data/$id/instructions.txt" "$@"
}

test_artifact_discovery_projects_before_stdout() {
  local home fakebin id=ida-artifact-discovery sha marker provider out rc variant
  home=$(new_home artifact-discovery); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  new_task "$home" "$id"; : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}')
  marker="firstmate:$id:${sha:0:16}"
  provider=$(jq -cn --arg marker "$marker" \
    '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:"80001",
      agent_id:"9001",agent_name:"iDA Test",model:null,provider_status:"completed"}')
  FM_HOME="$home" bash -c '
    set -u
    . "$1/bin/fm-remote-agent-lib.sh"
    STATE="$2/state"; DATA="$2/data"
    fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5" || exit 10
    fm_remote_meta_write "$3" ida research || exit 11
  ' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "artifact discovery state fixture failed"

  out=$(FM_IDA_FAKE_MODE=artifact-list FM_IDA_FAKE_LOG="$home/bytedcli.log" \
    FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" FM_IDA_FAKE_SESSION_ID="$SESSION_ID" \
    FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$IDA" artifacts "$id") || fail "task-bound artifact discovery failed"
  printf '%s\n' "$out" >"$home/projected-artifacts.json"
  jq -e --arg id "$id" '
    .schema == "fm-ida-artifact-discovery.v1" and .task_id == $id
    and .session_id == "70001" and .remote_task_id == "80001"
    and .availability == "available" and .provider_truncated == false
    and .artifact_count == 1 and .error_class == null
    and .artifacts[0] == {
      task_id:"80001",artifact_id:"artifact-92",name:"research-output",content_type:"document",
      table_count:1,has_text:true,files:[
        {file_name:"report.csv",mime_type:"text/csv",uri:"https://ida.example/artifact-92/report.csv",size:4242},
        {file_name:"analysis.js",mime_type:"text/javascript",uri:"https://ida.example/artifact-92/analysis.js",size:31337}
      ]}
  ' "$home/projected-artifacts.json" >/dev/null || fail "artifact discovery lost selected identities, URIs, sizes, types, or counts"
  if printf '%s\n' "$out" | grep -E 'PRIVATE_|secret-column|"description":|"tables":|"rows":|"script":' >/dev/null; then
    fail "artifact discovery leaked provider document, table, script, or unrelated description content"
  fi
  assert_grep 'ida --region sg deep-research artifact list --session-id 70001 --task-id 80001' "$home/bytedcli.log" \
    "artifact discovery was not bound to the recorded session and remote task"

  out=$(FM_IDA_FAKE_MODE=artifact-list-empty run_ida "$home" "$fakebin" artifacts "$id") \
    || fail "an empty artifact list was treated as a provider failure"
  printf '%s\n' "$out" | jq -e '.availability == "empty" and .artifact_count == 0 and .artifacts == []' >/dev/null \
    || fail "empty artifact availability was not preserved"
  out=$(FM_IDA_FAKE_MODE=artifact-list-partial run_ida "$home" "$fakebin" artifacts "$id") \
    || fail "a partial artifact list was discarded"
  printf '%s\n' "$out" | jq -e '.availability == "partial" and .provider_truncated == true and .artifact_count == 1' >/dev/null \
    || fail "provider truncation was not explicit in artifact discovery"

  for variant in artifact-list-malformed artifact-list-missing artifact-list-mismatch artifact-list-error; do
    rc=0
    out=$(FM_IDA_FAKE_MODE="$variant" run_ida "$home" "$fakebin" artifacts "$id") || rc=$?
    [ "$rc" -ne 0 ] || fail "$variant artifact response was accepted"
    printf '%s\n' "$out" | jq -e '
      .schema == "fm-ida-artifact-discovery.v1" and .availability == "error"
      and .artifacts == [] and (.error_class | type == "string" and length > 0)
    ' >/dev/null || fail "$variant did not return a bounded structured error projection"
    if printf '%s\n' "$out" | grep -E 'PRIVATE_|service unavailable' >/dev/null; then
      fail "$variant leaked raw provider content through its error projection"
    fi
  done
  pass "artifact discovery retains exact task/file selection fields and availability while dropping raw bodies before stdout"
}

test_dispatch_model_selection_and_validation() {
  local home fakebin id state creates rc
  home=$(new_home model-selection); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"

  id=ida-explicit-model; new_task "$home" "$id"
  dispatch_ida "$home" "$fakebin" "$id" --model ida-explicit-test >/dev/null \
    || fail "explicit-model iDA dispatch failed"
  wait_phase "$home" "$id" terminal-success || fail "explicit-model dispatch did not complete"
  state=$(state_file "$home" "$id")
  [ "$(jq -r '.provider_state.model' "$state")" = ida-explicit-test ] \
    || fail "explicit model did not round-trip through private state"
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep 'Model: `ida-explicit-test`' "$home/data/$id/report.md" "explicit model did not survive result readback"
  creates=$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 1 ] || fail "explicit model did not reach exactly one create call"
  assert_grep 'create-model:ida-explicit-test' "$home/bytedcli.log" "explicit model did not reach the official create request"

  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  printf 'model=ida-research-test\n' >>"$home/config/ida-remote-agent"
  id=ida-provider-default; new_task "$home" "$id"
  dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "provider-default iDA dispatch failed"
  wait_phase "$home" "$id" terminal-success || fail "provider-default dispatch did not complete"
  jq -e '.provider_state.model == null' "$(state_file "$home" "$id")" >/dev/null \
    || fail "omitted model materialized a config or guessed default"
  assert_grep 'create-model:omitted' "$home/bytedcli.log" "omitted model changed the old create request"
  assert_no_grep 'ida --region sg model list' "$home/bytedcli.log" "omitted model unexpectedly queried the model catalog"

  for id in ida-model-empty ida-model-malformed ida-model-position ida-model-duplicate; do new_task "$home" "$id"; done
  : >"$home/bytedcli.log"; rc=0
  dispatch_ida "$home" "$fakebin" ida-model-empty --model '' >"$home/empty.out" 2>"$home/empty.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "empty iDA model was accepted"
  assert_grep 'non-empty value' "$home/empty.err" "empty model error was not actionable"
  rc=0; dispatch_ida "$home" "$fakebin" ida-model-malformed --model 'bad model' >"$home/malformed.out" 2>"$home/malformed.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed iDA model was accepted"
  assert_grep 'malformed iDA model' "$home/malformed.err" "malformed model error was not actionable"
  rc=0; dispatch_ida "$home" "$fakebin" ida-model-position --model=ida-explicit-test >"$home/position.out" 2>"$home/position.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported iDA model argument form was accepted"
  assert_grep "use '--model <value>' exactly once" "$home/position.err" "unsupported model argument error was not actionable"
  rc=0; dispatch_ida "$home" "$fakebin" ida-model-duplicate --model ida-explicit-test --model ida-research-test >"$home/duplicate.out" 2>"$home/duplicate.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate iDA model flags were accepted"
  assert_grep 'duplicate --model' "$home/duplicate.err" "duplicate model error was not actionable"
  [ ! -s "$home/bytedcli.log" ] || fail "invalid model input made a provider call"

  id=ida-model-unsupported; new_task "$home" "$id"; rc=0
  dispatch_ida "$home" "$fakebin" "$id" --model ida-not-in-catalog >"$home/unsupported.out" 2>"$home/unsupported.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported iDA model was accepted"
  assert_grep 'unsupported iDA model' "$home/unsupported.err" "unsupported model error was not actionable"
  creates=$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 0 ] || fail "unsupported model reached provider mutation"
  assert_absent "$home/state/$id.meta" "unsupported model published task metadata"

  id=ida-model-incompatible; new_task "$home" "$id"; : >"$home/bytedcli.log"; rc=0
  FM_IDA_FAKE_NO_MODEL_CAPABILITY=1 dispatch_ida "$home" "$fakebin" "$id" --model ida-explicit-test \
    >"$home/incompatible.out" 2>"$home/incompatible.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "provider-incompatible iDA model selection was accepted"
  assert_grep 'does not support --model' "$home/incompatible.err" "provider-incompatible model error was not actionable"
  assert_no_grep 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" "provider-incompatible model reached provider mutation"
  assert_absent "$home/state/$id.meta" "provider-incompatible model published task metadata"

  id=ida-model-auth-outage; new_task "$home" "$id"; : >"$home/bytedcli.log"; rc=0
  FM_IDA_FAKE_MCP_AUTH_FAIL=1 dispatch_ida "$home" "$fakebin" "$id" --model ida-explicit-test \
    >"$home/auth.out" 2>"$home/auth.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "iDA model validation during an MCP auth outage was accepted"
  assert_grep "cannot validate iDA model 'ida-explicit-test': auth" "$home/auth.err" "auth outage error was not reported with its classified cause"
  assert_no_grep 'does not support --model' "$home/auth.err" "auth outage was misreported as a CLI incompatibility"
  assert_no_grep 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" "auth outage reached provider mutation"
  assert_absent "$home/state/$id.meta" "auth outage published task metadata"

  state=$(state_file "$home" ida-explicit-model)
  jq 'del(.provider_state.model)' "$state" >"$home/legacy-model-state.json"
  chmod 0600 "$home/legacy-model-state.json"
  mv "$home/legacy-model-state.json" "$state"
  run_ida "$home" "$fakebin" state ida-explicit-model >"$home/legacy-model.out" \
    || fail "legacy state without a model field became unreadable"
  assert_grep 'state: done' "$home/legacy-model.out" "legacy model-less state did not preserve terminal state"
  pass "iDA dispatch validates an optional model, preserves omission, round-trips explicit intent, and classifies capability failures"
}

test_ida_usage_help_boundary() {
  local out rc=0
  out="$TMP_ROOT/ida-usage.out"
  "$IDA" --help >"$out" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "iDA usage did not exit with the usage status"
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep '`retire` requires a terminal normalized state' "$out" "iDA usage dropped the retire paragraph"
  assert_grep 'removes only the volatile iDA metadata/state for that task.' "$out" "iDA usage truncated the final documented paragraph"
  assert_no_grep 'set -u' "$out" "iDA usage leaked past the documented header"
  pass "iDA usage prints the complete documented command header"
}

run_ida_source() {
  local home=$1 fakebin=$2 mode_file=$3
  shift 3
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
    FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
    FM_IDA_FAKE_MODE_FILE="$mode_file" PATH="$fakebin:$BASE_PATH" "$@"
}

ida_result_count() {
  find "$1/state/procevent-inbox" -name "$2.*.result" | wc -l | tr -d '[:space:]'
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
  jq -e '.result_availability == "available" and .result_kind == "text"
    and (.answer | startswith("Verified iDA answer.")) and .artifact_reference == null' "$result" >/dev/null \
    || fail "legacy text result behavior changed while adding structured artifacts"
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

test_structured_final_answer_readback() {
  local home fakebin id=ida-structured-answer sha marker provider observation result seq replay revision result_path mode variant
  home=$(new_home structured-answer); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  new_task "$home" "$id"; : >"$home/bytedcli.log"
  sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}'); marker="firstmate:$id:${sha:0:16}"
  printf '%s\t%s\tcompleted\t%s\n' "$SESSION_ID" "$marker" "$marker" >"$home/sessions.tsv"
  provider=$(jq -cn --arg marker "$marker" '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:"80001",agent_id:"9001",agent_name:"iDA Test",model:"ida-research-test",provider_status:"completed"}')
  FM_HOME="$home" bash -c '
    set -u
    . "$1/bin/fm-remote-agent-lib.sh"
    STATE="$2/state"; DATA="$2/data"
    fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5" || exit 10
    fm_remote_meta_write "$3" ida research || exit 11
  ' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "structured-result state fixture failed"

  observation="$home/observe.json"
  FM_IDA_FAKE_MODE=structured-artifact FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
    FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-procevent-ida.sh" observe "$id" >"$observation" \
    || fail "structured final-answer observation failed"
  chmod 0600 "$observation"
  jq -e '
    .terminal == true and .result_availability == "available" and .result_kind == "artifact"
    and .answer == null
    and .artifact_reference.schema == "fm-ida-artifact-reference.v1"
    and .artifact_reference.kind == "deep-research-final-answer"
    and .artifact_reference.part_kinds == ["data","file"]
  ' "$observation" >/dev/null || {
    jq -c '{terminal,result_availability,result_kind,artifact_reference,error_class}' "$observation" >&2
    fail "structured final answer was not normalized as an available artifact"
  }
  if grep -R -E 'PRIVATE_(ARTIFACT|FILE|SHEET|CELL)' "$observation" "$home/bytedcli.log" >/dev/null; then
    fail "structured result content leaked through observation or command logs"
  fi
  for variant in structured-malformed structured-unsupported; do
    FM_IDA_FAKE_MODE="$variant" FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
      FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
      FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
      PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-procevent-ida.sh" observe "$id" >"$home/$variant.json" \
      || fail "$variant observation failed"
  done
  jq -e '.terminal == true and .result_availability == "error" and .error_class == "provider-result-malformed" and .answer == null' \
    "$home/structured-malformed.json" >/dev/null || fail "malformed structured result was not explicit"
  jq -e '.terminal == true and .result_availability == "error" and .error_class == "provider-result-unsupported" and .answer == null' \
    "$home/structured-unsupported.json" >/dev/null || fail "unsupported structured result was not explicit"
  if grep -R -E 'PRIVATE_(MALFORMED|UNSUPPORTED)' "$home/structured-malformed.json" "$home/structured-unsupported.json" "$home/bytedcli.log" >/dev/null; then
    fail "malformed or unsupported structured content leaked through normalization"
  fi

  FM_IDA_FAKE_MODE=structured-artifact run_ida "$home" "$fakebin" adopt "$id" >/dev/null \
    || fail "existing structured-result session adoption failed"
  wait_phase "$home" "$id" terminal-success || fail "structured result did not cross the remote-agent result boundary"
  result_path=$(jq -r '.result_path' "$(state_file "$home" "$id")")
  [ -f "$result_path" ] && [ ! -L "$result_path" ] || fail "structured result was not recovered into the private result boundary"
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f '%Lp' "$result_path"); else mode=$(stat -c '%a' "$result_path"); fi
  [ "$mode" = 600 ] || fail "structured result boundary mode was $mode instead of 600"
  jq -e '.result_availability == "available" and .result_kind == "artifact" and .answer == null' "$result_path" >/dev/null \
    || fail "private structured result did not preserve available artifact identity"
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep 'Result availability: `available`' "$home/data/$id/report.md" "structured result report lost availability"
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep 'Result kind: `artifact`' "$home/data/$id/report.md" "structured result report lost artifact kind"
  assert_no_grep 'exact empty final answer' "$home/data/$id/report.md" "structured result was reported as exact empty"
  if grep -R -E 'PRIVATE_(ARTIFACT|FILE|SHEET|CELL)' "$home/state" "$home/data/$id/report.md" "$home/bytedcli.log" >/dev/null; then
    fail "structured file URI, inline data, or artifact bytes escaped the private normalization boundary"
  fi
  assert_no_grep 'deep-research create' "$home/bytedcli.log" "structured result recovery created a provider session"
  assert_no_grep ' continue ' "$home/bytedcli.log" "structured result recovery continued a provider session"
  assert_no_grep 'completion close' "$home/bytedcli.log" "structured result recovery closed a provider session"

  result=$(find "$home/state/procevent-inbox" -name "ida-$id.*.result" -print -quit)
  seq=${result%.result}; seq=${seq##*.}; revision=$(jq -r '.revision' "$(state_file "$home" "$id")")
  replay=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent-ida.sh" autohandle "ida-$id" "$seq" "$result") || fail "structured-result replay failed"
  assert_contains "$replay" 'duplicate=true' "structured result replay was applied twice"
  [ "$(jq -r '.revision' "$(state_file "$home" "$id")")" = "$revision" ] || fail "structured replay mutated terminal state"
  pass "completed structured final answers are privately recovered as artifacts without provider mutation or content leakage"
}

test_completed_step_answer_fallback() {
  local home fakebin id=ida-step-answer-only readiness prompt state report status_count creates
  home=$(new_home step-answer-only); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  readiness='FM_IDA_READINESS_V1 {"status":"ok","instruction_received":true,"business_data_accessed":false,"external_write_performed":false,"echo":"sg-ida-e2e-20260825-v1"}'
  prompt=$(printf 'Return exactly this readiness record and nothing else:\n%s' "$readiness")
  new_task "$home" "$id" "$prompt"; : >"$home/bytedcli.log"; : >"$home/sessions.tsv"

  FM_IDA_FAKE_MODE=step-answer-only FM_IDA_FAKE_ANSWER="$readiness" \
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
    FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
    PATH="$fakebin:$BASE_PATH" "$DISPATCH" remote-agent/ida "$id" \
      --instructions "$home/data/$id/instructions.txt" >/dev/null \
    || fail "step-only official result did not dispatch"
  wait_phase "$home" "$id" terminal-success || fail "step-only official result did not terminalize"

  state=$(state_file "$home" "$id"); report="$home/data/$id/report.md"
  jq -e --arg task "$REMOTE_TASK_ID" --arg readiness "$readiness" '
    .phase == "terminal-success" and .provider_state.task_id == $task
    and .provider_state.provider_status == "completed"
    and .result_availability == "available"
    and (.result_path | type == "string" and length > 0)
  ' "$state" >/dev/null || {
    jq -c '{phase,outcome,result_availability,result_path,
      provider_status:.provider_state.provider_status,task_id:.provider_state.task_id}' "$state" >&2
    fail "step-only official result lost its normalized terminal state"
  }
  jq -e --arg readiness "$readiness" '
    .terminal == true and .result_availability == "available" and .result_kind == "text"
    and (.answer | split("\n")[0]) == $readiness
    and .artifact_reference == null and .error_class == null
  ' "$(jq -r '.result_path' "$state")" >/dev/null \
    || fail "step-only official result did not preserve the exact readiness marker"
  assert_grep "$readiness" "$report" "step-only official result was absent from the report"
  assert_no_grep 'exact empty final answer' "$report" "step-only official result was reported as exact zero"
  if grep -R -F 'Return exactly this readiness record' "$home/state" "$report" "$home/bytedcli.log" >/dev/null; then
    fail "private readiness instruction leaked through step-only normalization"
  fi
  status_count=$(grep -F -c 'done: iDA remote research complete' "$home/state/$id.status" || true)
  [ "$status_count" -eq 1 ] || fail "step-only official result emitted $status_count terminal notifications"
  creates=$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 1 ] || fail "step-only official result crossed $creates create boundaries"
  pass "task-bound completed-step text fills exact-zero session readback without leakage or duplicate creation"
}

test_task_bound_terminal_and_monotonic_generations() {
  local home fakebin id=ida-task-bound sha marker provider unavailable source mode_file result seq
  local report state revision report_sha status_count result_count
  home=$(new_home task-bound-terminal); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  new_task "$home" "$id"; : >"$home/bytedcli.log"
  sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}')
  marker="firstmate:$id:${sha:0:16}"
  printf '%s\t%s\terror\t%s\n' "$SESSION_ID" "$marker" "$marker" >"$home/sessions.tsv"
  provider=$(jq -cn --arg marker "$marker" \
    '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:"80001",
      agent_id:"9001",agent_name:"iDA Test",model:null,provider_status:null}')
  FM_HOME="$home" bash -c '
    set -u
    . "$1/bin/fm-remote-agent-lib.sh"
    STATE="$2/state"; DATA="$2/data"
    fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5" || exit 10
    fm_remote_meta_write "$3" ida research || exit 11
  ' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "task-bound state fixture failed"

  unavailable="$home/recorded-task-unavailable.json"
  FM_IDA_FAKE_MODE=recorded-task-missing FM_HOME="$home" \
    FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
    FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-procevent-ida.sh" observe "$id" >"$unavailable" \
    || fail "recorded-task-unavailable observation failed"
  jq -e --arg task "$REMOTE_TASK_ID" '
    .task_id_remote == $task and .terminal == false and .ambiguous == false
    and .result_availability == "unavailable" and .error_class == "recorded-task-unavailable"
    and .answer == null
  ' "$unavailable" >/dev/null || fail "a conflicting unrecorded task became authoritative"
  assert_no_grep 'PRIVATE_OTHER_TASK_ANSWER' "$unavailable" "unrecorded task answer escaped normalization"

  FM_IDA_FAKE_MODE=aggregate-error-running run_ida "$home" "$fakebin" adopt "$id" >/dev/null \
    || fail "aggregate-error running observation could not be armed"
  wait_phase "$home" "$id" running || fail "session aggregate error prematurely terminalized the recorded running task"
  state=$(state_file "$home" "$id")
  jq -e --arg task "$REMOTE_TASK_ID" '
    .phase == "running" and .provider_state.task_id == $task
    and .provider_state.provider_status == "running"
    and .report_path == null
  ' "$state" >/dev/null || fail "task-level running authority was not preserved over aggregate error"
  run_ida "$home" "$fakebin" interrupt-wait "$id" >/dev/null || fail "task-bound running waiter cleanup failed"

  FM_IDA_FAKE_MODE=recorded-task-conflict run_ida "$home" "$fakebin" adopt "$id" >/dev/null \
    || fail "recorded task success could not be armed"
  wait_phase "$home" "$id" terminal-success || fail "same recorded task success did not terminalize"
  report="$home/data/$id/report.md"
  assert_grep 'FM_IDA_READINESS_V1 {"status":"ok","instruction_received":true,"business_data_accessed":false,"external_write_performed":false,"echo":"sg-ida-e2e-20260825-v1"}' \
    "$report" "structured readiness marker was not preserved exactly"
  if grep -R -F 'PRIVATE_OTHER_TASK_ANSWER' "$home/state" >/dev/null; then
    fail "conflicting task answer leaked into normalized state"
  fi
  assert_no_grep 'PRIVATE_OTHER_TASK_ANSWER' "$report" "conflicting task answer leaked into the report"
  jq -e --arg task "$REMOTE_TASK_ID" '
    .phase == "terminal-success" and .provider_state.task_id == $task
    and .provider_state.provider_status == "success"
    and .result_availability == "available"
  ' "$state" >/dev/null || fail "recorded task success lost its exact normalized terminal state"
  revision=$(jq -r '.revision' "$state")
  report_sha=$(sha256sum "$report" | awk '{print $1}')
  status_count=$(grep -F -c 'done: iDA remote research complete' "$home/state/$id.status" || true)
  [ "$status_count" -eq 1 ] || fail "recorded task success emitted $status_count terminal notifications"

  source="ida-$id"; mode_file="$home/mode"
  for mode in aggregate-error-running recorded-task-conflict; do
    printf '%s\n' "$mode" >"$mode_file"
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" \
      register ida "$source" -- "$ROOT/bin/fm-procevent-ida.sh" observe "$id" >/dev/null \
      || fail "could not register post-terminal $mode generation"
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null \
      || fail "could not capture post-terminal $mode generation"
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
      "$ROOT/bin/fm-procevent-ida.sh" retire "$id" >/dev/null \
      || fail "could not retire post-terminal $mode source"
  done
  find "$home/state/procevent-inbox" -name "$source.*.result" -print | while IFS= read -r result; do
    [ -f "${result%.result}.handled" ] && continue
    seq=${result%.result}; seq=${seq##*.}
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
      "$ROOT/bin/fm-procevent-ida.sh" autohandle "$source" "$seq" "$result" >/dev/null \
      || exit 1
  done || fail "a queued task-bound generation could not be handled idempotently"
  [ "$(jq -r '.revision' "$state")" = "$revision" ] || fail "post-terminal generation regressed durable state"
  [ "$(sha256sum "$report" | awk '{print $1}')" = "$report_sha" ] || fail "duplicate generation rewrote the terminal report"
  status_count=$(grep -F -c 'done: iDA remote research complete' "$home/state/$id.status" || true)
  [ "$status_count" -eq 1 ] || fail "duplicate generation emitted another terminal notification"
  result_count=$(find "$home/state/procevent-inbox" -name "$source.*.result" | wc -l | tr -d '[:space:]')
  [ "$result_count" -ge 3 ] || fail "task-bound timeline did not exercise distinct process-event generations"
  find "$home/state/procevent-inbox" -name "$source.*.result" -print | while IFS= read -r result; do
    [ -f "${result%.result}.handled" ] || exit 1
  done || fail "a duplicate or post-terminal generation remained unacknowledged"
  if grep -R -E 'PRIVATE_(PROMPT|OTHER_TASK)|OECID_sensitive' "$home/state" "$report" "$home/bytedcli.log" >/dev/null; then
    fail "private provider or prompt content leaked through task-bound handling"
  fi
  pass "recorded task authority survives aggregate conflicts and post-terminal generations without empty results, regression, duplicate notification, or leakage"
}

test_terminal_outcomes_with_visible_answer() {
  local home fakebin id mode phase availability class status outcome sha marker provider result
  home=$(new_home answered-terminal); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  for id in ida-failed-answered ida-cancelled-answered ida-closed-answered; do
    case "$id" in
      ida-failed-answered) mode=failed-answered; phase=terminal-failure; availability=error; class="provider-terminal-failure"; status=failed; outcome=failed ;;
      ida-cancelled-answered) mode=cancelled-answered; phase=terminal-cancelled; availability=unavailable; class="provider-cancelled"; status=cancelled; outcome=cancelled ;;
      ida-closed-answered) mode=closed-answered; phase=terminal-cancelled; availability=unavailable; class="provider-cancelled"; status=closed; outcome=cancelled ;;
    esac
    new_task "$home" "$id"; : >"$home/bytedcli.log"
    sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}'); marker="firstmate:$id:${sha:0:16}"
    printf '%s\t%s\tcompleted\t%s\n' "$SESSION_ID" "$marker" "$marker" >"$home/sessions.tsv"
    provider=$(jq -cn --arg marker "$marker" '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:"80001",agent_id:"9001",agent_name:"iDA Test",model:"ida-research-test",provider_status:"completed"}')
    FM_HOME="$home" bash -c '
      set -u
      . "$1/bin/fm-remote-agent-lib.sh"
      STATE="$2/state"; DATA="$2/data"
      fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5" || exit 10
      fm_remote_meta_write "$3" ida research || exit 11
    ' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "answered-terminal state fixture failed for $id"
    FM_IDA_FAKE_MODE="$mode" run_ida "$home" "$fakebin" adopt "$id" >/dev/null \
      || fail "$id adoption failed with a visible terminal answer"
    wait_phase "$home" "$id" "$phase" || fail "$id with a visible answer did not reach $phase"
    result=$(find "$home/state/procevent-inbox" -name "ida-$id.*.result" -print -quit)
    jq -e --arg availability "$availability" --arg class "$class" --arg status "$status" '
      .terminal == true and .ambiguous == false
      and .result_availability == $availability and .result_kind == "text"
      and .error_class == $class and .provider_status == $status
      and (.answer | startswith("Verified iDA answer.") and contains("[REDACTED"))
      and .artifact_reference == null
    ' "$result" >/dev/null || fail "$id lost its legacy redacted text answer or distinct non-available outcome"
    # shellcheck disable=SC2016 # Backticks are literal Markdown.
    assert_grep "Outcome: \`$outcome\`" "$home/data/$id/report.md" "$id report outcome drifted"
    # shellcheck disable=SC2016 # Backticks are literal Markdown.
    assert_grep 'Result kind: `text`' "$home/data/$id/report.md" "$id report lost its text result kind"
    if grep -R -E 'top-secret|123456789012345678|user@example\.com' "$home/state" "$home/data/$id/report.md" >/dev/null; then
      fail "$id legacy answer payload leaked unredacted into state or report"
    fi
  done
  pass "failed, cancelled, and closed sessions keep visible text answers terminal without wedging readback"
}

test_provider_states_and_zero_result() {
  local home fakebin id out observation provider_calls
  home=$(new_home states); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"
  id=ida-zero; new_task "$home" "$id"; : >"$home/sessions.tsv"
  FM_IDA_FAKE_MODE=zero dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "zero-result dispatch failed"
  wait_phase "$home" "$id" terminal-success
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  assert_grep 'Result availability: `zero`' "$home/data/$id/report.md" "zero result was conflated"
  observation="$home/structured-empty.json"
  FM_IDA_FAKE_MODE=structured-empty FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
    FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-procevent-ida.sh" observe "$id" >"$observation"
  jq -e '.terminal == true and .result_availability == "zero" and .result_kind == null and .answer == null' "$observation" >/dev/null \
    || fail "exact-empty supported structured final answer was not retained as zero"

  id=ida-live; new_task "$home" "$id"; marker="firstmate:$id:1234567890abcdef"
  sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}'); marker="firstmate:$id:${sha:0:16}"
  printf '%s\t%s\trunning\n' "$SESSION_ID" "$marker" >"$home/sessions.tsv"
  provider=$(jq -cn --arg marker "$marker" '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:null,agent_id:"9001",agent_name:null,model:"ida-research-test",provider_status:"running"}')
  FM_HOME="$home" bash -c '. "$1/bin/fm-remote-agent-lib.sh"; STATE="$2/state"; DATA="$2/data"; fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5"; fm_remote_meta_write "$3" ida research' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "state fixture failed"
  staged="$home/state-$id.json"
  jq '.phase="running" | .provider_checkpoint="provider-running"' "$(state_file "$home" "$id")" >"$staged"
  chmod 0600 "$staged"; mv "$staged" "$(state_file "$home" "$id")"
  provider_calls=$(wc -l < "$home/bytedcli.log" | tr -d ' ')
  FM_IDA_FAKE_MODE=list-unavailable out=$(run_ida "$home" "$fakebin" state "$id" --durable-only)
  assert_contains "$out" \
    "state: working · source: remote-state · provider=ida phase=running outcome=none freshness=durable-local remote-readback=deferred" \
    "durable-only iDA state omitted its freshness gap"
  [ "$(wc -l < "$home/bytedcli.log" | tr -d ' ')" -eq "$provider_calls" ] \
    || fail "durable-only iDA state reached the provider"
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

test_local_readback_failure_and_recovery() {
  local mode class home fakebin id source mode_file sha marker provider state first status before tries expected_phase recovery_seq
  for mode in launch-126 launch-127 empty malformed multiple exit-error structure session-mismatch; do
    case "$mode" in
      launch-126|launch-127) class=cli-exit-error ;;
      empty) class=response-empty ;;
      malformed|multiple) class=response-invalid-json ;;
      exit-error) class=cli-exit-error ;;
      structure) class=response-invalid-structure ;;
      session-mismatch) class=session-identity-mismatch ;;
    esac
    id="ida-local-$mode"; source="ida-$id"
    home=$(new_home "$id"); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
    mode_file="$home/mode"; printf 'get-%s\n' "$mode" >"$mode_file"
    sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}')
    marker="firstmate:$id:${sha:0:16}"
    printf '%s\t%s\tcompleted\t%s\n' "$SESSION_ID" "$marker" "$marker" >"$home/sessions.tsv"
    provider=$(jq -cn --arg marker "$marker" '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:"80001",agent_id:"9001",agent_name:"iDA Test",model:null,provider_status:"running"}')
    expected_phase="result-unavailable"
    if [ "$mode" = empty ]; then
      # A failed first read after create must retain the create response's exact identity.
      provider=$(printf '%s' "$provider" | jq '.session_id=null | .task_id=null')
      : >"$home/sessions.tsv"
      expected_phase="submission-unknown"
    fi
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-remote-agent-lib.sh"
      STATE="$2/state"; DATA="$2/data"
      fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5" || exit 1
      fm_remote_meta_write "$3" ida research || exit 1
      fm_remote_state_transition "$3" running "" "" provider-running not-armed unavailable "" "" "{}"
    ' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "local readback fixture failed"
    if [ "$mode" = empty ]; then
      FM_HOME="$home" bash -c '. "$1/bin/fm-remote-agent-lib.sh"; STATE="$2/state"; DATA="$2/data";
        fm_remote_state_transition "$3" submission-not-started "" "" dispatch-durable not-armed unavailable "" "" "{}"
      ' _ "$ROOT" "$home" "$id" || fail "pre-submission fixture checkpoint failed"
    fi
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent-ida.sh" arm "$id" >/dev/null || fail "local source arm failed"
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >"$home/capture.out" 2>"$home/capture.err" \
      || fail "local failure capture failed: $mode"
    state=$(state_file "$home" "$id"); first="$home/state/procevent-inbox/$source.1.result"; status="$home/state/$id.status"
    jq -e --arg class "$class" --arg phase "$expected_phase" '.phase == $phase and .outcome == "unavailable"
      and .waiter == "interrupted" and .error_class == $class and .report_path == null
      and .provider_state.local_readback_blocked == true
      and .provider_state.session_id == "70001" and .provider_state.task_id == "80001"' "$state" >/dev/null \
      || fail "local failure changed remote outcome/identity or lost its class: $mode"
    jq -e --arg class "$class" '.terminal == false and .ambiguous == false and .error_class == $class' "$first" >/dev/null \
      || fail "local failure observation falsely terminalized provider: $mode"
    assert_present "$home/state/procevent-inbox/$source.1.handled" "local failure was not acknowledged"
    assert_absent "$home/state/procevent/$source.source" "local failure silently rearmed"
    assert_absent "$home/state/procevent/$source.runner" "local failure retained a runner"
    assert_grep 'blocked [key=ida-readback-local]' "$status" "local failure did not emit its blocker"
    assert_grep 'use adopt' "$status" "local failure did not explain recovery"
    if grep -E '^failed:|^done:' "$status" >/dev/null; then fail "local failure claimed remote completion"; fi
    assert_grep "procevent ida $source 1" "$home/state/.wake-queue" "local failure notification was not durable"
    before=$(cat "$status")
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent-ida.sh" handle "$id" 1 "$first" >/dev/null || fail "local failure replay failed"
    [ "$(cat "$status")" = "$before" ] || fail "local failure replay duplicated its blocker"
    run_ida_source "$home" "$fakebin" "$mode_file" "$STATE_CMD" "$id" >"$home/current-state"
    assert_grep 'state: blocked' "$home/current-state" "local readback current-state hid actionable failure"
    if grep -R -E 'PRIVATE_LOCAL_STDERR|PRIVATE_LOCAL_STDOUT|synthetic-secret' "$home/state" >/dev/null; then
      fail "raw local failure leaked into durable state"
    fi

    recovery_seq=2
    if [ "$mode" = launch-126 ]; then
      # An intervening remote outage must not close the local recovery obligation.
      printf 'get-unavailable\n' >"$mode_file"
      run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent-ida.sh" arm "$id" >/dev/null || fail "transient retry arm failed"
      run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null || fail "transient retry capture failed"
      jq -e '.provider_state.local_readback_blocked == true and .error_class == "unavailable"' "$state" >/dev/null \
        || fail "remote outage lost the local recovery obligation"
      assert_no_grep 'resolved [key=ida-readback-local]' "$status" "remote outage falsely resolved local readback"
      printf 'recorded-task-missing\n' >"$mode_file"
      run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null || fail "missing-task capture failed"
      jq -e '.provider_state.local_readback_blocked == true' "$state" >/dev/null || fail "missing bound task lost recovery obligation"
      assert_no_grep 'resolved [key=ida-readback-local]' "$status" "sibling-only response resolved bound-task readback"
      recovery_seq=4
    fi
    # Recovery includes another task in the session and must retain the exact binding.
    printf 'recorded-task-conflict\n' >"$mode_file"
    run_ida_source "$home" "$fakebin" "$mode_file" "$IDA" adopt "$id" >"$home/adopt.out" || fail "same-task recovery failed"
    wait_phase "$home" "$id" terminal-success
    tries=300
    while [ ! -f "$home/state/procevent-inbox/$source.$recovery_seq.handled" ] && [ "$tries" -gt 0 ]; do sleep 0.03; tries=$((tries - 1)); done
    [ "$tries" -gt 0 ] || fail "recovery capture was not acknowledged"
    jq -e '.provider_state.task_id == "80001" and .provider_state.session_id == "70001"
      and .provider_state.local_readback_blocked == false and .result_availability == "available"' "$state" >/dev/null \
      || fail "recovery lost exact task or retained the local blocker"
    assert_grep 'resolved [key=ida-readback-local]' "$status" "healthy read did not resolve the blocker"
    [ "$(grep -c '^done:' "$status")" -eq 1 ] || fail "recovery did not emit one completion"
    assert_grep 'FM_IDA_READINESS_V1' "$home/data/$id/report.md" "recovery lost the task answer"
    assert_no_grep 'OTHER_TASK_ANSWER' "$home/data/$id/report.md" "recovery used the sibling answer"
    assert_absent "$home/state/procevent/$source.source" "recovery did not retire the source"
    before=$(cat "$home/data/$id/report.md")
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent-ida.sh" handle "$id" "$recovery_seq" "$home/state/procevent-inbox/$source.$recovery_seq.result" >/dev/null \
      || fail "recovery replay failed"
    [ "$(cat "$home/data/$id/report.md")" = "$before" ] && [ "$(grep -c '^done:' "$status")" -eq 1 ] \
      || fail "recovery replay changed its report or repeated completion"
    if [ "$mode" = empty ]; then
      [ "$(grep -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log")" -eq 1 ] || fail "recovery repeated create"
    else
      assert_no_grep 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" "local recovery repeated create"
    fi
    assert_no_grep 'chat completion close' "$home/bytedcli.log" "local recovery cancelled provider"
  done
  pass "local read failures capture actionable blockers, retire only waiting, and recover the exact task once"
}

test_bytedcli_resolution_and_background_successor() {
  local home fakebin id=ida-background-successor source mode_file sha marker provider state
  local installed_home missing_home unusable_home observation tries
  home=$(new_home background-successor); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  source="ida-$id"; mode_file="$home/mode"; : >"$home/bytedcli.log"
  sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}')
  marker="firstmate:$id:${sha:0:16}"
  printf '%s\t%s\trunning\t%s\n' "$SESSION_ID" "$marker" "$marker" >"$home/sessions.tsv"
  provider=$(jq -cn --arg marker "$marker" '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:"80001",agent_id:"9001",agent_name:"iDA Test",model:null,provider_status:"running"}')
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-remote-agent-lib.sh"
    STATE="$2/state"; DATA="$2/data"
    fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5" || exit 1
    fm_remote_meta_write "$3" ida research || exit 1
    fm_remote_state_transition "$3" running "" "" provider-running not-armed unavailable "" "" "{}"
  ' _ "$ROOT" "$home" "$id" "$sha" "$provider" || fail "background successor fixture failed"
  state=$(state_file "$home" "$id")

  installed_home="$home/installed-home"
  mkdir -p "$installed_home/.npm-global/bin"
  cp "$fakebin/bytedcli" "$installed_home/.npm-global/bin/bytedcli"
  chmod 0755 "$installed_home/.npm-global/bin/bytedcli"
  printf 'running\n' >"$mode_file"
  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent-ida.sh" arm "$id" >/dev/null \
    || fail "background successor source arm failed"
  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null \
    || fail "foreground-path generation failed"
  jq -e '.phase == "running" and .provider_state.session_id == "70001" and .provider_state.task_id == "80001"' "$state" >/dev/null \
    || fail "foreground-path generation lost the exact remote identity"
  assert_present "$home/state/procevent/$source.source" "running generation did not rearm its successor"

  printf 'recorded-task-conflict\n' >"$mode_file"
  HOME="$installed_home" PATH=/usr/bin:/bin \
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    FM_IDA_FAKE_LOG="$home/bytedcli.log" FM_IDA_FAKE_SESSIONS="$home/sessions.tsv" \
    FM_IDA_FAKE_SESSION_ID="$SESSION_ID" FM_IDA_FAKE_TASK_ID="$REMOTE_TASK_ID" \
    FM_IDA_FAKE_MODE_FILE="$mode_file" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
    || fail "background successor reconciliation failed"
  tries=300
  while [ ! -f "$home/state/procevent-inbox/$source.2.handled" ] && [ "$tries" -gt 0 ]; do sleep 0.03; tries=$((tries - 1)); done
  [ "$tries" -gt 0 ] || fail "background successor result was not handled"
  jq -e '.phase == "terminal-success" and .provider_state.session_id == "70001"
    and .provider_state.task_id == "80001" and .result_availability == "available"' "$state" >/dev/null \
    || fail "watcher-environment successor did not recover the exact task result"
  assert_grep 'FM_IDA_READINESS_V1' "$home/data/$id/report.md" "background successor lost the task answer"
  assert_no_grep 'OTHER_TASK_ANSWER' "$home/data/$id/report.md" "background successor selected a sibling answer"

  missing_home="$home/missing-home"; mkdir -p "$missing_home"
  observation="$home/missing-observation.json"
  HOME="$missing_home" PATH=/usr/bin:/bin FM_HOME="$home" \
    "$ROOT/bin/fm-procevent-ida.sh" observe "$id" >"$observation"
  jq -e '.error_class == "cli-not-found"' "$observation" >/dev/null \
    || fail "a genuinely missing bytedcli was not classified as cli-not-found"

  unusable_home="$home/unusable-home"; mkdir -p "$unusable_home/.npm-global/bin"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$unusable_home/.npm-global/bin/bytedcli"
  chmod 0600 "$unusable_home/.npm-global/bin/bytedcli"
  observation="$home/unusable-observation.json"
  HOME="$unusable_home" PATH=/usr/bin:/bin FM_HOME="$home" \
    "$ROOT/bin/fm-procevent-ida.sh" observe "$id" >"$observation"
  jq -e '.error_class == "cli-not-executable"' "$observation" >/dev/null \
    || fail "an unusable installed bytedcli was not classified as cli-not-executable"
  pass "iDA resolves a user-global bytedcli for background successors and preserves lookup versus CLI exit failures"
}

test_transient_readback_coalescing_and_backoff() {
  local home fakebin id=ida-transient source mode_file result_one runner sleep_log sleep_release
  local results wakes artifacts revision replay tries sha marker provider staged
  home=$(new_home transient-readback); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  source="ida-$id"; mode_file="$home/mode"; : >"$home/bytedcli.log"
  cat >"$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -u
if [ -z "${FM_IDA_FAKE_SLEEP_LOG:-}" ]; then exec /bin/sleep "$@"; fi
case "$1" in 0.0*) ;; *) exec /bin/sleep "$@" ;; esac
printf '%s\n' "$1" >>"$FM_IDA_FAKE_SLEEP_LOG"
count=$(wc -l <"$FM_IDA_FAKE_SLEEP_LOG" | tr -d '[:space:]')
if [ "$count" -ge "${FM_IDA_FAKE_SLEEP_BLOCK_AFTER:-1}" ]; then
  while [ ! -e "${FM_IDA_FAKE_SLEEP_RELEASE:?}" ]; do /bin/sleep 0.01; done
fi
SH
  chmod +x "$fakebin/sleep"
  sha=$(sha256sum "$home/data/$id/instructions.txt" | awk '{print $1}')
  marker="firstmate:$id:${sha:0:16}"
  printf '%s\t%s\trunning\t%s\n' "$SESSION_ID" "$marker" "$marker" >"$home/sessions.tsv"
  provider=$(jq -cn --arg marker "$marker" '{region:"sg",identity:"user",session_marker:$marker,session_id:"70001",task_id:"80001",agent_id:"9001",agent_name:"iDA Test",model:"ida-research-test",provider_status:"running"}')
  FM_HOME="$home" bash -c '. "$1/bin/fm-remote-agent-lib.sh"; STATE="$2/state"; DATA="$2/data"; fm_remote_state_initialize "$3" ida research "$2/data/$3/instructions.txt" "$4" "$5"; fm_remote_meta_write "$3" ida research' _ "$ROOT" "$home" "$id" "$sha" "$provider" \
    || fail "transient iDA state fixture failed"
  staged="$home/state-$id.json"
  jq '.phase="running" | .provider_checkpoint="provider-running"' "$(state_file "$home" "$id")" >"$staged"
  chmod 0600 "$staged"; mv "$staged" "$(state_file "$home" "$id")"

  printf 'get-stderr-unavailable\n' >"$mode_file"
  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent-ida.sh" arm "$id" >/dev/null \
    || fail "transient source arm failed"
  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null \
    || fail "initial transient observation failed"
  wait_phase "$home" "$id" result-unavailable || fail "initial transient observation was not applied"
  result_one=$(find "$home/state/procevent-inbox" -name "$source.1.result" -print -quit)
  [ -n "$result_one" ] || fail "initial transient observation was not durably captured"
  [ "$(grep -c "procevent ida $source" "$home/state/.wake-queue" || true)" -eq 1 ] \
    || fail "initial transient threshold did not publish exactly once"

  sleep_log="$home/retry-sleeps"; sleep_release="$home/retry-release"
  : >"$sleep_log"
  FM_IDA_TRANSIENT_BACKOFF_INITIAL_MS=20 FM_IDA_TRANSIENT_BACKOFF_MAX_MS=80 \
    FM_IDA_FAKE_SLEEP_LOG="$sleep_log" FM_IDA_FAKE_SLEEP_RELEASE="$sleep_release" \
    FM_IDA_FAKE_SLEEP_BLOCK_AFTER=4 \
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" \
      >"$home/retry.out" 2>"$home/retry.err" &
  runner=$!
  tries=500
  while [ "$(wc -l <"$sleep_log" | tr -d '[:space:]')" -lt 4 ] && [ "$tries" -gt 0 ]; do sleep 0.02; tries=$((tries - 1)); done
  [ "$tries" -gt 0 ] || fail "transient retry source did not reach bounded backoff: sleeps=$(wc -l <"$sleep_log" | tr -d '[:space:]') results=$(ida_result_count "$home" "$source")"
  [ "$(sed -n '1p' "$sleep_log")" = 0.020 ] \
    && [ "$(sed -n '2p' "$sleep_log")" = 0.040 ] \
    && [ "$(sed -n '3p' "$sleep_log")" = 0.080 ] \
    && [ "$(sed -n '4p' "$sleep_log")" = 0.080 ] \
    || fail "transient retries did not double to and remain at the configured bound"
  results=$(ida_result_count "$home" "$source")
  wakes=$(grep -c "procevent ida $source" "$home/state/.wake-queue" || true)
  artifacts=$(find "$home/state/remote-tasks/$id/artifacts" -name '*-observation.json' | wc -l | tr -d '[:space:]')
  [ "$results:$wakes:$artifacts" = 1:1:1 ] \
    || fail "identical transient retries grew durable state: results=$results wakes=$wakes artifacts=$artifacts"
  if grep -R -E 'token=synthetic-secret|network request failed: HTTP 503' "$home/state" >/dev/null; then
    fail "stderr-only transient leaked into durable state"
  fi

  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" retire "$source" >/dev/null \
    || fail "transient retry restart cleanup failed"
  wait "$runner" 2>/dev/null || true
  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent-ida.sh" arm "$id" >/dev/null \
    || fail "transient source restart arm failed"
  sleep_log="$home/restart-sleeps"; sleep_release="$home/restart-release"
  : >"$sleep_log"
  FM_IDA_TRANSIENT_BACKOFF_INITIAL_MS=20 FM_IDA_TRANSIENT_BACKOFF_MAX_MS=80 \
    FM_IDA_FAKE_SLEEP_LOG="$sleep_log" FM_IDA_FAKE_SLEEP_RELEASE="$sleep_release" \
    FM_IDA_FAKE_SLEEP_BLOCK_AFTER=1 \
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" \
      >"$home/restart.out" 2>"$home/restart.err" &
  runner=$!
  tries=500
  while [ ! -s "$sleep_log" ] && [ "$tries" -gt 0 ]; do sleep 0.02; tries=$((tries - 1)); done
  [ "$tries" -gt 0 ] || fail "restarted transient source did not recover durable retry state"
  results=$(ida_result_count "$home" "$source")
  [ "$results" -eq 1 ] || fail "restart forgot the durable transient and published a duplicate"

  printf 'running\n' >"$mode_file"
  : >"$sleep_release"
  tries=500
  while kill -0 "$runner" 2>/dev/null && [ "$tries" -gt 0 ]; do sleep 0.02; tries=$((tries - 1)); done
  [ "$tries" -gt 0 ] || fail "eventual successful observation did not reset transient backoff"
  wait "$runner" || fail "eventual successful observation was not captured"
  wait_phase "$home" "$id" running || fail "successful observation did not restore running state"
  results=$(ida_result_count "$home" "$source")
  [ "$results" -eq 2 ] || fail "successful state change was coalesced"

  printf 'get-unavailable\n' >"$mode_file"
  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null \
    || fail "materially different transient observation failed"
  [ "$(ida_result_count "$home" "$source")" -eq 3 ] \
    || fail "materially different error was coalesced"

  sleep_log="$home/changed-error-sleeps"; sleep_release="$home/changed-error-release"
  : >"$sleep_log"
  printf 'get-unavailable\n' >"$mode_file"
  FM_IDA_TRANSIENT_BACKOFF_INITIAL_MS=20 FM_IDA_TRANSIENT_BACKOFF_MAX_MS=80 \
    FM_IDA_FAKE_SLEEP_LOG="$sleep_log" FM_IDA_FAKE_SLEEP_RELEASE="$sleep_release" \
    FM_IDA_FAKE_SLEEP_BLOCK_AFTER=1 \
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" \
      >"$home/changed-error.out" 2>"$home/changed-error.err" &
  runner=$!
  tries=500
  while [ ! -s "$sleep_log" ] && [ "$tries" -gt 0 ]; do sleep 0.02; tries=$((tries - 1)); done
  [ "$tries" -gt 0 ] || fail "materially different error fixture did not enter transient backoff"
  printf 'get-provider-error\n' >"$mode_file"
  : >"$sleep_release"
  tries=500
  while kill -0 "$runner" 2>/dev/null && [ "$tries" -gt 0 ]; do sleep 0.02; tries=$((tries - 1)); done
  [ "$tries" -gt 0 ] || fail "materially different transient error remained coalesced"
  wait "$runner" || fail "materially different transient error was not captured"
  [ "$(ida_result_count "$home" "$source")" -eq 4 ] \
    || fail "materially different transient error was coalesced"

  printf 'get-auth\n' >"$mode_file"
  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null \
    || fail "authorization observation failed"
  [ "$(ida_result_count "$home" "$source")" -eq 5 ] \
    || fail "authorization error was coalesced"

  printf 'get-provider-error\n' >"$mode_file"
  run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" >/dev/null \
    || fail "post-authorization transient observation failed"
  [ "$(ida_result_count "$home" "$source")" -eq 6 ] \
    || fail "post-authorization state change was coalesced"

  sleep_log="$home/terminal-sleeps"; sleep_release="$home/terminal-release"
  : >"$sleep_log"
  FM_IDA_TRANSIENT_BACKOFF_INITIAL_MS=20 FM_IDA_TRANSIENT_BACKOFF_MAX_MS=80 \
    FM_IDA_FAKE_SLEEP_LOG="$sleep_log" FM_IDA_FAKE_SLEEP_RELEASE="$sleep_release" \
    FM_IDA_FAKE_SLEEP_BLOCK_AFTER=1 \
    run_ida_source "$home" "$fakebin" "$mode_file" "$ROOT/bin/fm-procevent.sh" start "$source" \
      >"$home/terminal.out" 2>"$home/terminal.err" &
  runner=$!
  tries=500
  while [ ! -s "$sleep_log" ] && [ "$tries" -gt 0 ]; do sleep 0.02; tries=$((tries - 1)); done
  [ "$tries" -gt 0 ] || fail "terminal fixture did not enter transient backoff"
  printf 'failed\n' >"$mode_file"
  : >"$sleep_release"
  tries=500
  while kill -0 "$runner" 2>/dev/null && [ "$tries" -gt 0 ]; do sleep 0.02; tries=$((tries - 1)); done
  [ "$tries" -gt 0 ] || fail "terminal observation remained behind transient coalescing"
  wait "$runner" || fail "terminal observation was not captured"
  wait_phase "$home" "$id" terminal-failure || fail "terminal observation was not applied"
  [ "$(ida_result_count "$home" "$source")" -eq 7 ] \
    || fail "terminal observation was coalesced"

  revision=$(jq -r '.revision' "$(state_file "$home" "$id")")
  replay=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" \
    "$ROOT/bin/fm-procevent-ida.sh" handle "$id" 1 "$result_one") || fail "stale queued generation was not safely handleable"
  assert_contains "$replay" 'duplicate=true' "stale queued generation was not idempotent"
  [ "$(jq -r '.revision' "$(state_file "$home" "$id")")" = "$revision" ] || fail "stale queued generation rewrote current state"
  pass "iDA coalesces identical transient readback retries with bounded backoff while state changes, terminal results, and replay bypass safely"
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
  fm_test_archive_goal "$home" "$id"
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
  fm_test_archive_goal "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >>"$home/state/$id.meta"
  FM_HOME="$home" "$RETIRE" "$id" >/dev/null || fail "decision-complete iDA retirement failed"
  assert_absent "$home/state/$id.meta" "retirement retained iDA metadata"
  assert_present "$home/data/$id/report.md" "retirement removed durable iDA report"
  pass "legacy version state remains readable through adoption, reconciliation, cancellation, and safe retirement"
}

# Exercise the real backlog CLI, including a close that landed before its
# caller saw an error. Retry must preserve evidence and never resurrect work.
test_retirement_pairs_backlog_and_preserves_failed_close() {
  local home fakebin id=ida-close out real_tasks mode rc
  command -v tasks-axi >/dev/null 2>&1 || { printf 'skip: remote backlog pairing needs tasks-axi\n'; return; }
  real_tasks=$(command -v tasks-axi)
  for mode in closed held interrupted; do
    home=$(new_home "retire-$mode"); fakebin=$(make_fake_bytedcli "$home")
    write_ida_config "$home"; new_task "$home" "$id"
    printf 'backend = "markdown"\n' > "$home/.tasks.toml"
    printf '# Tasks\n\n## In flight\n\n- [ ] %s - Remote research (kind: scout) (since 2026-09-24)\n\n## Queued\n\n## Done\n' "$id" > "$home/data/backlog.md"
    : > "$home/sessions.tsv"
    FM_IDA_FAKE_MODE=success dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail "retirement fixture dispatch failed"
    wait_phase "$home" "$id" terminal-success || fail "retirement fixture did not complete"
    fm_test_archive_goal "$home" "$id"
    printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$home/state/$id.meta"
    if [ "$mode" = held ]; then
      TASKS_AXI_BACKEND=markdown tasks-axi hold "$id" --file "$home/data/backlog.md" --kind captain --reason 'Pending independent acceptance' >/dev/null || fail "hold fixture failed"
    elif [ "$mode" = interrupted ]; then
      cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
"${FM_REAL_TASKS:?}" "$@" || exit $?
if [ "$1" = done ] && [ -f "${FM_CLOSE_INTERRUPT:?}" ]; then
  rm "$FM_CLOSE_INTERRUPT"
  exit 1
fi
SH
      chmod +x "$fakebin/tasks-axi"
      : > "$home/interrupt"
      PATH="$fakebin:$BASE_PATH" TASKS_AXI_BACKEND=markdown FM_REAL_TASKS="$real_tasks" FM_CLOSE_INTERRUPT="$home/interrupt" FM_HOME="$home" \
        "$RETIRE" "$id" > "$home/retire.out" 2> "$home/retire.err" && fail "lost close acknowledgement reported success"
      assert_present "$home/state/$id.meta" "failed close lost execution metadata"
      assert_present "$(state_file "$home" "$id")" "failed close lost terminal state"
      assert_present "$home/data/$id/report.md" "failed close lost report"
      assert_grep 'execution evidence retained' "$home/retire.err" "failed close lacked actionable diagnostic"
      out=$(FM_HOME="$home" "$STATE_CMD" progress "$id") \
        || fail "interrupted close lost readable compact progress"
      [ "$(printf '%s' "$out" | jq -r .goal)" = 'Remote research' ] \
        || fail "report-link decoration replaced the original compact goal"
      [ "$(printf '%s' "$out" | jq -r .context_relation)" = disposition_only ] \
        || fail "interrupted close changed more than compact task disposition"
    fi
    PATH="$fakebin:$BASE_PATH" TASKS_AXI_BACKEND=markdown FM_REAL_TASKS="$real_tasks" FM_CLOSE_INTERRUPT="$home/interrupt" FM_HOME="$home" \
      "$RETIRE" "$id" >/dev/null || fail "remote retirement/retry failed for $mode"
    out=$(TASKS_AXI_BACKEND=markdown tasks-axi show "$id" --file "$home/data/backlog.md" --full)
    if [ "$mode" = held ]; then
      assert_contains "$out" 'state: queued' "retirement closed an independent captain call"
      assert_contains "$out" 'hold_kind: captain' "retirement lost captain hold"
    else
      assert_contains "$out" 'state: done' "retirement left a stale in-flight row"
    fi
    assert_present "$home/data/$id/report.md" "retirement lost durable report"
    assert_absent "$home/state/$id.meta" "retirement retained execution metadata"
    assert_contains "$out" "data/$id/report.md" "retirement lost report link"
    assert_present "$home/data/$id/remote-execution.json" \
      "retirement lost immutable iDA execution identity"
    if [ "$mode" = closed ]; then
      TASKS_AXI_BACKEND=markdown tasks-axi reopen "$id" --file "$home/data/backlog.md" >/dev/null \
        || fail "iDA identity-reuse fixture could not reopen the row"
      TASKS_AXI_BACKEND=markdown tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null \
        || fail "iDA identity-reuse fixture could not restart the row"
      rc=0
      dispatch_ida "$home" "$fakebin" "$id" >"$home/reuse.out" 2>"$home/reuse.err" || rc=$?
      [ "$rc" -eq 6 ] || fail "retired iDA id reuse exited $rc instead of 6"
      assert_grep 'retained remote execution identity' "$home/reuse.err" \
        "retired iDA id reuse lost its identity blocker"
      assert_absent "$(state_file "$home" "$id")" "retired iDA id reuse created provider state"
    fi
  done
  pass "remote retirement pairs closed/held backlog state and retries interrupted close without losing evidence"
}

test_aime_compatibility_and_local_unchanged() {
  local home fakebin out rc=0
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
  new_task "$home" aime-model-refused
  : >"$home/bytedcli.log"
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$DISPATCH" remote-agent/aime aime-model-refused \
      --instructions "$home/data/aime-model-refused/instructions.txt" --model ida-explicit-test \
      >"$home/aime-model.out" 2>"$home/aime-model.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "AIME silently accepted the iDA-only model option"
  assert_grep 'supported only by remote-agent/ida' "$home/aime-model.err" "AIME model refusal was not actionable"
  [ ! -s "$home/bytedcli.log" ] || fail "AIME model refusal reached a provider call"
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

test_followup_identity_and_unknown_submission() {
  local home fakebin id=ida-followup old_sha creates outcome rc=0
  home=$(new_home followup); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : > "$home/bytedcli.log"; : > "$home/sessions.tsv"
  dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail 'initial followup fixture dispatch'
  wait_phase "$home" "$id" terminal-success || fail 'initial followup fixture terminal'
  old_sha=$(shasum -a 256 "$home/data/$id/report.md" | cut -d' ' -f1)
  printf 'Read existing artifacts only; retain the original query identities. Supply the missing CSV link.\n' > "$home/data/$id/followup.txt"
  chmod 600 "$home/data/$id/followup.txt"
  local REMOTE_TASK_ID=80002
  if FM_IDA_FAKE_NO_FOLLOWUP=1 run_ida "$home" "$fakebin" followup "$id" --action-id "$id.g1.a1" --expected-terminal-generation 1 --instructions "$home/data/$id/followup.txt" > "$home/unsupported.out" 2>&1; then fail 'unsupported continuation accepted'; fi
  assert_grep 'unsupported-continuation' "$home/unsupported.out" 'missing capability reason'
  [ "$(grep -c '^command:ida-region-sg-deep-research-create$' "$home/bytedcli.log")" = 1 ] || fail 'capability refusal created a remote turn'
  pass 'unsupported continuation refuses before create without fallback'
  outcome=$(run_ida "$home" "$fakebin" followup "$id" --action-id "$id.g1.a1" --expected-terminal-generation 1 --instructions "$home/data/$id/followup.txt" 2>&1) || fail "followup: $outcome"
  jq -e '.generation==2 and .provider_state.task_id=="80002" and .provider_state.parent_task_id=="80001"' "$(state_file "$home" "$id")" >/dev/null || fail 'followup did not bind new turn'
  jq -e '.phase=="terminal-success" and .provider_state.task_id=="80001"' "$home/state/remote-tasks/$id/generations/1.json" >/dev/null || fail 'prior terminal overwritten'
  [ "$old_sha" = "$(shasum -a 256 "$home/data/$id/turn-1-report.md" | cut -d' ' -f1)" ] || fail 'prior report changed'
  run_ida "$home" "$fakebin" followup "$id" --action-id "$id.g1.a1" --expected-terminal-generation 1 --instructions "$home/data/$id/followup.txt" >/dev/null || fail 'same followup replay'
  creates=$(grep -c '^command:ida-region-sg-deep-research-create$' "$home/bytedcli.log")
  [ "$creates" = 2 ] || fail "followup replay created $creates total requests"
  pass 'same-session followup freezes prior terminal/report and replays without duplicate create'

  # A second fresh fixture loses the create response. Session message order
  # and one new turn cannot establish the marker/turn binding.
  id=ida-followup-unknown
  home=$(new_home followup-unknown); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : > "$home/bytedcli.log"; : > "$home/sessions.tsv"
  REMOTE_TASK_ID=80001
  dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail 'unknown fixture dispatch'
  wait_phase "$home" "$id" terminal-success
  printf 'Read existing artifacts only\n' > "$home/data/$id/followup.txt"
  chmod 600 "$home/data/$id/followup.txt"
  REMOTE_TASK_ID=80002
  FM_IDA_FAKE_MODE=timeout-created run_ida "$home" "$fakebin" followup "$id" --action-id "$id.g1.a1" --expected-terminal-generation 1 --instructions "$home/data/$id/followup.txt" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail 'lost response reported success'
  if run_ida "$home" "$fakebin" followup "$id" --action-id "$id.g1.a1" --expected-terminal-generation 1 --instructions "$home/data/$id/followup.txt" > "$home/replay" 2>&1; then fail 'ambiguous turn adopted by order'; fi
  [ "$(grep -c '^command:ida-region-sg-deep-research-create$' "$home/bytedcli.log")" = 2 ] || fail 'ambiguous followup was created twice'
  [ "$(phase_of "$home" "$id")" = submission-unknown ] || fail 'unknown submission lost'
  jq -e '.phase=="submission-unknown" and .generation==2 and
    .provider_state.followup_action_id=="ida-followup-unknown.g1.a1" and
    .provider_state.parent_generation==1 and .provider_state.submit_attempted==true' \
    "$(state_file "$home" "$id")" >/dev/null || fail 'ambiguous submission lost its exact operation identity'
  assert_absent "$home/data/$id/lifecycle.json" 'followup operation created rich lifecycle state'
  pass 'lost followup response remains unknown; replay performs reads only and never repeats create'
}

test_terminal_disposition_guards_remote_effects() {
  local home fakebin id rc creates

  id=ida-terminal-dispatch
  home=$(new_home terminal-dispatch); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  tasks-axi "done" "$id" --file "$home/data/backlog.md" >/dev/null \
    || fail 'terminal-dispatch task could not become Done'
  rc=0
  dispatch_ida "$home" "$fakebin" "$id" >"$home/dispatch.out" 2>"$home/dispatch.err" || rc=$?
  [ "$rc" -eq 6 ] || fail "terminal iDA dispatch exited $rc instead of 6"
  assert_grep 'explicitly terminal (done)' "$home/dispatch.err" 'terminal iDA dispatch lost its disposition blocker'
  assert_absent "$(state_file "$home" "$id")" 'terminal iDA dispatch created provider state'
  [ ! -s "$home/bytedcli.log" ] || fail 'terminal iDA dispatch reached the provider'

  id=ida-terminal-at-submit
  home=$(new_home terminal-at-submit); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  rc=0
  FM_IDA_FAKE_LIST_DONE_TASK="$id" FM_IDA_FAKE_LIST_DONE_CLAIM="$home/list-done.claim" \
    dispatch_ida "$home" "$fakebin" "$id" >"$home/dispatch.out" 2>"$home/dispatch.err" || rc=$?
  creates=$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 0 ] || fail 'iDA created a provider task after the backlog became terminal'
  [ "$(phase_of "$home" "$id")" = submission-not-started ] \
    || fail 'terminal request-boundary refusal crossed the durable submission checkpoint'

  id=ida-terminal-followup
  home=$(new_home terminal-followup); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail 'terminal-followup initial dispatch failed'
  wait_phase "$home" "$id" terminal-success || fail 'terminal-followup initial turn did not finish'
  printf 'This archived task must not continue.\n' >"$home/data/$id/followup.txt"
  chmod 600 "$home/data/$id/followup.txt"
  tasks-axi "done" "$id" --file "$home/data/backlog.md" >/dev/null \
    || fail 'terminal-followup task could not become Done'
  rc=0
  run_ida "$home" "$fakebin" followup "$id" --action-id "$id.g1.a1" \
    --expected-terminal-generation 1 --instructions "$home/data/$id/followup.txt" \
    >"$home/followup.out" 2>"$home/followup.err" || rc=$?
  [ "$rc" -eq 6 ] || fail "terminal iDA followup exited $rc instead of 6"
  assert_grep 'explicitly terminal (done)' "$home/followup.err" 'terminal iDA followup lost its disposition blocker'
  creates=$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)
  [ "$creates" -eq 1 ] || fail 'terminal iDA followup issued another provider create'

  id=ida-historical-retire
  home=$(new_home historical-retire); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  dispatch_ida "$home" "$fakebin" "$id" >/dev/null || fail 'historical-retire dispatch failed'
  wait_phase "$home" "$id" terminal-success || fail 'historical-retire turn did not finish'
  printf '## In flight\n\n## Queued\n\n## Done\n' >"$home/data/backlog.md"
  jq -n --arg id "$id" '{schema:"fm-task-lifecycle.v2",task_id:$id,execution_generation:"remote-1",disposition:"open"}' \
    >"$home/data/$id/lifecycle.json"
  rc=0
  run_ida "$home" "$fakebin" retire "$id" >"$home/retire.out" 2>"$home/retire.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'iDA retirement accepted open retained history'
  assert_grep 'neither MAIN-accepted compact progress nor explicit archived completion' "$home/retire.err" \
    'iDA historical retirement lost its terminal-fact blocker'
  assert_present "$(state_file "$home" "$id")" 'iDA historical retirement removed provider state'

  id=ida-retained-execution
  home=$(new_home retained-execution); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  printf '## In flight\n\n## Queued\n\n## Done\n' >"$home/data/backlog.md"
  jq -n --arg id "$id" '{schema:"fm-task-lifecycle.v2",task_id:$id,execution_generation:"remote-7",disposition:"archived"}' \
    >"$home/data/$id/lifecycle.json"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  rc=0
  dispatch_ida "$home" "$fakebin" "$id" >"$home/redispatch.out" 2>"$home/redispatch.err" || rc=$?
  [ "$rc" -eq 6 ] || fail "retained-execution redispatch exited $rc instead of 6"
  assert_grep 'already has a retained execution identity' "$home/redispatch.err" \
    'retained-execution redispatch lost its identity blocker'
  assert_absent "$(state_file "$home" "$id")" 'retained-execution redispatch replaced provider state'
  [ ! -s "$home/bytedcli.log" ] || fail 'retained-execution redispatch reached the provider'

  id=ida-current-over-retained
  home=$(new_home current-over-retained); fakebin=$(make_fake_bytedcli "$home"); write_ida_config "$home"; new_task "$home" "$id"
  jq -n --arg id "$id" '{schema:"fm-task-lifecycle.v2",task_id:$id,execution_generation:"remote-old",disposition:"archived"}' \
    >"$home/data/$id/lifecycle.json"
  : >"$home/bytedcli.log"; : >"$home/sessions.tsv"
  dispatch_ida "$home" "$fakebin" "$id" >/dev/null \
    || fail 'retained rich execution identity controlled a current task dispatch'
  wait_phase "$home" "$id" terminal-success || fail 'current task over retained history did not finish'
  [ "$(grep -F -c 'command:ida-region-sg-deep-research-create' "$home/bytedcli.log" || true)" -eq 1 ] \
    || fail 'current task over retained history did not issue exactly one provider create'
  pass 'iDA terminal admission blocks dispatch, followup, retirement, and task-id reuse without provider replay'
}

case "${FM_REMOTE_TEST_CASE:-}" in
  followup)
    test_followup_identity_and_unknown_submission
    exit 0
    ;;
  retirement)
    test_retirement_pairs_backlog_and_preserves_failed_close
    exit 0
    ;;
  terminal)
    test_terminal_disposition_guards_remote_effects
    exit 0
    ;;
esac

test_followup_identity_and_unknown_submission
test_terminal_disposition_guards_remote_effects
test_artifact_discovery_projects_before_stdout
test_dispatch_model_selection_and_validation
test_ida_usage_help_boundary
test_dispatch_success_and_redaction
test_legacy_version_and_proxy_do_not_block_readiness
test_provider_rename_and_structured_empty_result
test_structured_final_answer_readback
test_completed_step_answer_fallback
test_task_bound_terminal_and_monotonic_generations
test_terminal_outcomes_with_visible_answer
test_provider_states_and_zero_result
test_timeout_reconciliation_and_no_duplicate
test_local_readback_failure_and_recovery
test_bytedcli_resolution_and_background_successor
test_transient_readback_coalescing_and_backoff
test_artifact_store_idempotency
test_abandon_after_authoritative_zero_match
test_pre_submission_unavailable_recovers_without_duplicate
test_cancellation_and_retirement_authority
test_retirement_pairs_backlog_and_preserves_failed_close
test_aime_compatibility_and_local_unchanged
test_remote_aime_dispatch_metadata
printf '# fm-remote-agent.test.sh: all assertions passed\n'
