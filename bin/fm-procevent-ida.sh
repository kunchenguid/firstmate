#!/usr/bin/env bash
# iDA adapter for Firstmate's generic process-event runner.
#
# Usage:
#   fm-procevent-ida.sh arm <task-id>
#   fm-procevent-ida.sh source <task-id>       # may perform first submission
#   fm-procevent-ida.sh observe <task-id>      # read-only provider observation
#   fm-procevent-ida.sh handle <task-id> <sequence> <result-file>
#   fm-procevent-ida.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-ida.sh terminal <result-file>
#   fm-procevent-ida.sh retire <task-id>
#
# `source` first reconciles the durable session marker through official iDA raw
# session-list and session-get reads. Only a unique zero-match, non-truncated
# result from the initial submission-not-started phase can cross the durable
# request boundary and call Deep Research. submission-unknown never retries: it
# keeps reconciling the exact legacy name or private first-message marker so a
# timeout or SG's automatic session rename cannot silently create a duplicate.
#
# The Deep Research prompt is passed through fm-bytedcli-mcp-call.sh over stdin.
# Provider responses are reduced to fm-ida-observation.v1 before stdout reaches
# process-event capture; raw MCP, SSE, message payloads, credentials, and prompt
# bytes are never captured.
# A recorded remote task id selects task-level terminalStatus and the matching
# visible text, structured deep_research_content.finalAnswer, or completed step
# content used by SG for small text-only results; unstable session aggregates
# and other tasks in the same session never terminalize that record.
# Once handling reaches a terminal phase, later captured generations are only
# acknowledged, so they cannot rewrite the report, regress state, or notify twice.
#
# After the first applied nonterminal transient read failure, `source` keeps
# semantically identical retries inside this adapter and polls with bounded
# exponential backoff. A changed observation returns immediately through the
# ordinary capture, publication, automatic-application, and acknowledgement
# path. The durable prior observation makes restart converge without rewriting
# or discarding any captured generation or queued wake.
# The retry delay defaults to 5000 ms, doubles to a 60000 ms cap, and is tuned
# only through FM_IDA_TRANSIENT_BACKOFF_INITIAL_MS and
# FM_IDA_TRANSIENT_BACKOFF_MAX_MS.
# Local CLI or invalid-response failures end only the current waiter, publish
# an ida-readback-local blocker, and preserve remote identity and nonterminal
# state. After repairing local readback, adopt retries the same task; a healthy
# observation resolves the blocker. provider_state.local_readback_blocked is
# the durable recovery marker, retained across retries until that observation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-remote-agent-lib.sh
. "$SCRIPT_DIR/fm-remote-agent-lib.sh"
# shellcheck source=bin/fm-ida-remote-lib.sh
. "$SCRIPT_DIR/fm-ida-remote-lib.sh"

IDA_PAGE_SIZE=${FM_IDA_SESSION_PAGE_SIZE:-100}
IDA_WAIT_TIMEOUT_MS=${FM_IDA_DEEP_RESEARCH_TIMEOUT_MS:-900000}
IDA_MARKER_SCAN_GRACE_SECONDS=300
IDA_TRANSIENT_BACKOFF_INITIAL_MS=${FM_IDA_TRANSIENT_BACKOFF_INITIAL_MS:-5000}
IDA_TRANSIENT_BACKOFF_MAX_MS=${FM_IDA_TRANSIENT_BACKOFF_MAX_MS:-60000}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 2; }
for ida_bound in "$IDA_PAGE_SIZE" "$IDA_WAIT_TIMEOUT_MS" "$IDA_MARKER_SCAN_GRACE_SECONDS" \
    "$IDA_TRANSIENT_BACKOFF_INITIAL_MS" "$IDA_TRANSIENT_BACKOFF_MAX_MS"; do
  case "$ida_bound" in ''|*[!0-9]*|0) die "iDA bounds must be positive integers" ;; esac
done
[ "$IDA_TRANSIENT_BACKOFF_INITIAL_MS" -le "$IDA_TRANSIENT_BACKOFF_MAX_MS" ] \
  || die "iDA transient backoff initial milliseconds exceed the maximum"
[ "$IDA_TRANSIENT_BACKOFF_MAX_MS" -le 3600000 ] || die "iDA transient backoff exceeds one hour"

temp_root() {
  local root
  root=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-ida.XXXXXX") || die "cannot create private iDA temporary storage"
  printf '%s\n' "$root"
}

run_ida_json() { # <stdout> <stderr> <args...>
  local out=$1 err=$2
  shift 2
  : >"$out"; : >"$err"
  if fm_ida_run_bytedcli --json --as user ida --region sg "$@" >"$out" 2>"$err"; then IDA_RC=0; else IDA_RC=$?; fi
  IDA_READ_ERROR=$(fm_ida_read_error_classify "$out" "$err" "$IDA_RC")
}

error_observation() { # <id> <kind> <class> [known-session-id] [known-task-id]
  jq -cn --arg schema "$IDA_OBSERVATION_SCHEMA" --arg id "$1" --arg marker "$IDA_STATE_MARKER" \
    --arg kind "$2" --arg class "$3" --arg session "${4:-}" --arg task "${5:-}" '
      {schema:$schema,task_id:$id,provider:"ida",region:"sg",kind:$kind,session_marker:$marker,
       session_id:(if $session=="" then null else $session end),
       task_id_remote:(if $task=="" then null else $task end),
       agent_id:null,agent_name:null,model:null,provider_status:null,
       terminal:false,ambiguous:false,result_availability:"error",result_kind:null,answer:null,
       artifact_reference:null,error_class:$class,observed_at:(now|todateiso8601)}'
}

ambiguous_observation() { # <id> <kind> <class> [count] [session-id]
  jq -cn --arg schema "$IDA_OBSERVATION_SCHEMA" --arg id "$1" --arg marker "$IDA_STATE_MARKER" \
    --arg kind "$2" --arg class "$3" --arg count "${4:-0}" --arg session_id "${5:-}" '
      {schema:$schema,task_id:$id,provider:"ida",region:"sg",kind:$kind,session_marker:$marker,
       session_id:(if $session_id=="" then null else $session_id end),task_id_remote:null,
       agent_id:null,agent_name:null,model:null,provider_status:null,
       terminal:false,ambiguous:true,result_availability:"unavailable",result_kind:null,answer:null,
       artifact_reference:null,error_class:$class,
       match_count:($count|tonumber),observed_at:(now|todateiso8601)}'
}

list_marker() { # <id> <root> ; sets LIST_* and leaves normalized list in root
  local id=$1 root=$2 out err normalized raw_normalized candidates matches agent_id created_epoch session_id name get prefix
  out="$root/list.out"; err="$root/list.err"; normalized="$root/list.json"; raw_normalized="$root/list-raw.json"
  agent_id=$IDA_STATE_AGENT_ID
  if [ -z "$agent_id" ]; then
    run_ida_json "$out" "$err" agent get
    agent_id=$(jq -r 'if .status=="success" and .error==null and .data.deep_research_enabled==true then .data.id // empty else empty end | tostring' "$out" 2>/dev/null)
    if [ -n "$IDA_READ_ERROR" ] || ! fm_ida_numeric_id "$agent_id"; then
      LIST_OK=false; LIST_CLASS=${IDA_READ_ERROR:-response-invalid-structure}; LIST_COUNT=0; LIST_TRUNCATED=true
      return 1
    fi
  fi
  run_ida_json "$out" "$err" session raw list --agent-id "$agent_id" --page-size "$IDA_PAGE_SIZE"
  if [ -n "$IDA_READ_ERROR" ] \
      || ! jq -e '.data.sessions.sessionList | type == "array"' "$out" >/dev/null 2>&1; then
    LIST_OK=false
    LIST_CLASS=${IDA_READ_ERROR:-response-invalid-structure}
    LIST_COUNT=0
    LIST_TRUNCATED=true
    return 1
  fi
  jq --argjson requested "$IDA_PAGE_SIZE" '
    {sessions:[.data.sessions.sessionList[]
      | {id:(.id|tostring),name:(.name // ""),
         agent_id:(.agentInfo.id // null | if . == null then null else tostring end),
         agent_name:(.agentInfo.name // null),latest_task_status:(.latestTaskStatus // null),
         create_time:(.createTime // null)}],
     truncated:((.data.sessions.sessionList | length) >= $requested)}' "$out" >"$raw_normalized" || return 1
  created_epoch=$(jq -r '.created_at | fromdateiso8601' "$REMOTE_STATE_FILE") || return 1
  candidates="$root/list-candidates"; matches="$root/list-matches.ndjson"; : >"$matches"
  jq -r --arg marker "$IDA_STATE_MARKER" --argjson created "$created_epoch" --argjson grace "$IDA_MARKER_SCAN_GRACE_SECONDS" '
    [.sessions[] | select(
      .name == $marker
      or ((try (.create_time | gsub(" ";"T") + "Z" | fromdateiso8601) catch 0) >= ($created - $grace))
    )] | unique_by(.id) | .[].id' "$raw_normalized" >"$candidates" || return 1
  prefix="[Firstmate session marker: $IDA_STATE_MARKER]"
  while IFS= read -r session_id; do
    [ -n "$session_id" ] || continue
    name=$(jq -r --arg sid "$session_id" '.sessions[] | select(.id==$sid) | .name' "$raw_normalized")
    if [ "$name" != "$IDA_STATE_MARKER" ]; then
      get="$root/get-$session_id.out"
      run_ida_json "$get" "$err" session get --session-id "$session_id"
      [ -n "$IDA_READ_ERROR" ] || IDA_READ_ERROR=$(fm_ida_session_response_error "$get" "$session_id")
      if [ -n "$IDA_READ_ERROR" ]; then
        LIST_OK=false; LIST_CLASS=$IDA_READ_ERROR; LIST_COUNT=0; LIST_TRUNCATED=true
        return 1
      fi
      if ! jq -e --arg prefix "$prefix" '
            ([.data.messages[]? | select(.type == 0 and (.text | type == "string")) | .text]
              | any(. == $prefix or startswith($prefix + "\n")))
          ' "$get" >/dev/null 2>&1; then
        continue
      fi
    fi
    jq -c --arg sid "$session_id" '.sessions[] | select(.id==$sid)' "$raw_normalized" >>"$matches" || return 1
  done <"$candidates"
  jq -s --argjson truncated "$(jq '.truncated' "$raw_normalized")" '{sessions:.,truncated:$truncated}' "$matches" >"$normalized" || return 1
  LIST_OK=true
  LIST_CLASS=
  LIST_COUNT=$(jq '.sessions | length' "$normalized")
  LIST_TRUNCATED=$(jq -r '.truncated' "$normalized")
}

session_payload_has_marker() { # <structured session get>
  local file=$1 prefix="[Firstmate session marker: $IDA_STATE_MARKER]"
  jq -e --arg marker "$IDA_STATE_MARKER" --arg prefix "$prefix" '
    .data.session.name == $marker
    or ([.data.messages[]? | select(.type == 0 and (.text | type == "string")) | .text]
      | any(. == $prefix or startswith($prefix + "\n")))
  ' "$file" >/dev/null 2>&1
}

session_observation() { # <id> <session-id> <kind> [recorded-task-id]
  local id=$1 session_id=$2 kind=$3 expected_task_id=${4:-$IDA_STATE_TASK_ID}
  local root out err task_summary task_id task_count task_found task_status status_kind allow_untagged
  local answer answer_file availability terminal ambiguous=false class="" agent_id agent_name
  local result_kind="" artifact_reference=null structured structured_state=empty
  root=$(temp_root); out="$root/get.out"; err="$root/get.err"
  run_ida_json "$out" "$err" session get --session-id "$session_id"
  class=$IDA_READ_ERROR
  [ -n "$class" ] || class=$(fm_ida_session_response_error "$out" "$session_id")
  if [ -n "$class" ]; then
    rm -rf -- "$root"
    error_observation "$id" "$kind" "$class" "$session_id" "$expected_task_id"
    return 0
  fi
  if ! session_payload_has_marker "$out"; then
    rm -rf -- "$root"
    ambiguous_observation "$id" "$kind" session-marker-mismatch 1
    return 0
  fi
  task_summary=$(jq -c --arg expected "$expected_task_id" '
    def remote_task_id:
      .deep_research_content?
      | select(type == "object")
      | .taskId?
      | select(. != null)
      | tostring
      | select(length > 0);
    . as $root
    | [$root.data.messages[]? | remote_task_id] | unique as $ids
    | (if $expected != "" then $expected elif ($ids | length) == 1 then $ids[0] else "" end) as $selected
    | {task_ids:$ids,task_count:($ids | length),selected:$selected,
       found:($selected != "" and any($ids[]; . == $selected)),
       status:([$root.data.messages[]?
         | select((remote_task_id // "") == $selected)
         | .deep_research_content.terminalStatus?
         | select(type == "string" and length > 0)] | last // "")}
  ' "$out") || die "cannot reconcile recorded iDA task"
  task_count=$(printf '%s' "$task_summary" | jq -r '.task_count')
  if [ -z "$expected_task_id" ] && [ "$task_count" -gt 1 ]; then
    rm -rf -- "$root"
    ambiguous_observation "$id" "$kind" duplicate-remote-task-identity "$task_count" "$session_id"
    return 0
  fi
  task_id=$(printf '%s' "$task_summary" | jq -r '.selected')
  task_found=$(printf '%s' "$task_summary" | jq -r '.found')
  task_status=$(printf '%s' "$task_summary" | jq -r '.status')
  if [ "$task_count" -eq 1 ] && [ "$task_found" = true ]; then allow_untagged=true; else allow_untagged=false; fi
  status_kind=$(fm_ida_status_kind "$task_status")
  answer_file="$root/answer.txt"
  jq -j --arg task "$task_id" --arg status_kind "$status_kind" \
    --argjson allow_untagged "$allow_untagged" '
    def remote_task_id:
      .deep_research_content?
      | select(type == "object")
      | .taskId?
      | select(. != null)
      | tostring
      | select(length > 0);
    def owns_task:
      ((remote_task_id // "") == $task)
      or ($allow_untagged and ((remote_task_id // "") == ""));
    def final_text:
      if type == "string" then select(length > 0)
      elif type == "array" then ([.[] | final_text] | join("")) | select(length > 0)
      elif type == "object" then
        . as $value
        | (["answer","chat_msg","content","text","markdown","summary","final_answer","finalAnswer"] as $keys
          | [$keys[] as $key
            | select($value | has($key))
            | ($value[$key] | final_text)]
          | if length > 0 then .[0]
            else (["data","v","message","result","payload","deepResearchContent"] as $nested
              | [$nested[] as $key
                | select($value | has($key))
                | ($value[$key] | final_text)]
              | .[0] // empty)
            end)
      else empty
      end;
    [.data.messages[]?
      | select(.visible == true and .type == 8 and owns_task)
      | .text?
      | select(type == "string" and length > 0)] as $visible_text
    | if ($visible_text | length) > 0 then $visible_text[-1]
      else ([.data.messages[]?
        | select(.visible == true and .type == 8 and owns_task)
        | .deep_research_content?
        | select(type == "object" and has("finalAnswer"))
        | .finalAnswer
        | final_text] | last // "") as $final_answer_text
      | if $final_answer_text != "" then $final_answer_text
        elif $status_kind == "success" then
          ([.data.messages[]?
            | select(.visible == true and .type == 8 and owns_task)
            | .deep_research_content?
            | select(type == "object" and (has("finalAnswer") | not))
            | .steps?
            | select(type == "array")
            | .[]
            | select(type == "object"
                and (.status == 1 or .status == "completed" or .status == "success"))
            | .content?
            | select(type == "string" and length > 0)] | last // "")
        else ""
        end
      end
  ' "$out" | fm_remote_redact_result_text "$REMOTE_STATE_INSTRUCTION_FILE" >"$answer_file" \
    || die "cannot normalize iDA final answer"
  answer=$(<"$answer_file")
  if [ -n "$answer" ]; then
    result_kind=text
  else
    structured=$(jq -c --arg task "$task_id" --argjson allow_untagged "$allow_untagged" '
      def remote_task_id:
        .deep_research_content?
        | select(type == "object")
        | .taskId?
        | select(. != null)
        | tostring
        | select(length > 0);
      def owns_task:
        ((remote_task_id // "") == $task)
        or ($allow_untagged and ((remote_task_id // "") == ""));
      def meaningful:
        if type == "null" then false
        elif type == "string" then length > 0
        elif type == "array" then any(.[]; meaningful)
        elif type == "object" then any(.[]; meaningful)
        else true
        end;
      def part_summary:
        if type != "object" then {state:"malformed"}
        elif has("file") and has("data") then {state:"unsupported"}
        elif has("file") then
          if ((.type? // "file") != "file") then {state:"unsupported"}
          elif (.file | type) != "object" then {state:"malformed"}
          elif (.file | meaningful | not) then {state:"empty",kind:"file"}
          elif ([.file.fileUri?,.file.file_uri?,.file.uri?]
            | any(.[]; type == "string" and length > 0)) then {state:"available",kind:"file"}
          else {state:"unsupported"}
          end
        elif has("data") then
          if ((.type? // "data") != "data") then {state:"unsupported"}
          elif (.data | type) != "object" then {state:"malformed"}
          elif (.data | meaningful | not) then {state:"empty",kind:"data"}
          elif (.data | has("sheets") | not) then {state:"unsupported"}
          elif (.data.sheets | type) != "array" then {state:"malformed"}
          elif (.data.sheets | meaningful) then {state:"available",kind:"data"}
          else {state:"empty",kind:"data"}
          end
        elif ((.type? // "") == "file" or (.type? // "") == "data") then {state:"malformed"}
        else {state:"unsupported"}
        end;
      def artifact_summary:
        if type != "object" then {state:"malformed"}
        elif (has("artifact") | not) then {state:"unsupported"}
        elif (.artifact | type) != "object" then {state:"malformed"}
        elif (.artifact | has("parts") | not) then {state:"malformed"}
        elif (.artifact.parts | type) != "array" then {state:"malformed"}
        else [.artifact.parts[] | part_summary] as $parts
          | if any($parts[]; .state == "malformed") then {state:"malformed"}
            elif any($parts[]; .state == "unsupported") then {state:"unsupported"}
            elif any($parts[]; .state == "available") then
              {state:"available",part_count:($parts | length),
               part_kinds:([$parts[] | select(.kind != null) | .kind] | unique)}
            else {state:"empty"}
            end
        end;
      def final_answer_summary:
        if . == null then {state:"empty"}
        elif type == "string" then
          if length == 0 then {state:"empty"} else {state:"unsupported"} end
        elif type != "array" then {state:"malformed"}
        elif length == 0 then {state:"empty"}
        else [.[] | artifact_summary] as $artifacts
          | if any($artifacts[]; .state == "malformed") then {state:"malformed"}
            elif any($artifacts[]; .state == "unsupported") then {state:"unsupported"}
            elif any($artifacts[]; .state == "available") then
              {state:"available",artifact_count:($artifacts | length),
               part_count:([$artifacts[] | .part_count // 0] | add),
               part_kinds:([$artifacts[] | .part_kinds[]?] | unique)}
            else {state:"empty"}
            end
        end;
      [.data.messages[]?
        | select(.visible == true and .type == 8 and owns_task and has("deep_research_content"))
        | if .deep_research_content == null then {state:"empty"}
          elif (.deep_research_content | type) != "object" then {state:"malformed"}
          elif (.deep_research_content | has("finalAnswer") | not) then {state:"empty"}
          else (.deep_research_content.finalAnswer | final_answer_summary)
          end
      ] as $results
      | ([$results[] | select(.state != "empty")] | last // {state:"empty"}) as $selected
      | if $selected.state == "available" then
          {state:"available",reference:{schema:"fm-ida-artifact-reference.v1",
           kind:"deep-research-final-answer",readback:"session-get",
           artifact_count:$selected.artifact_count,part_count:$selected.part_count,
           part_kinds:$selected.part_kinds}}
        else {state:$selected.state}
        end
    ' "$out") || die "cannot classify iDA structured final answer"
    structured_state=$(printf '%s' "$structured" | jq -r '.state')
    if [ "$structured_state" = available ]; then
      result_kind=artifact
      artifact_reference=$(printf '%s' "$structured" | jq -c '.reference')
    fi
  fi
  agent_id=$(jq -r '.data.session.agent_id // "" | tostring' "$out")
  agent_name=$(jq -r '.data.session.agent_name // ""' "$out")
  if [ -z "$task_id" ] || [ "$task_found" != true ]; then
    terminal=false; availability=unavailable; class='recorded-task-unavailable'
  elif [ -z "$task_status" ]; then
    terminal=false; availability=unavailable; class='recorded-task-status-unavailable'
  else case "$status_kind" in
    success)
      terminal=true
      if [ -n "$answer" ] || [ "$structured_state" = available ]; then availability=available
      elif [ "$structured_state" = malformed ]; then availability=error; class='provider-result-malformed'
      elif [ "$structured_state" = unsupported ]; then availability=error; class='provider-result-unsupported'
      else availability=zero
      fi
      ;;
    failure) terminal=true; availability=error; class='provider-terminal-failure' ;;
    cancelled) terminal=true; availability=unavailable; class='provider-cancelled' ;;
    running) terminal=false; availability=unavailable ;;
    ambiguous) terminal=false; ambiguous=true; availability=unavailable; class='provider-status-ambiguous' ;;
  esac; fi
  jq -cn --arg schema "$IDA_OBSERVATION_SCHEMA" --arg id "$id" --arg marker "$IDA_STATE_MARKER" \
    --arg kind "$kind" --arg session_id "$session_id" --arg agent_id "$agent_id" \
    --arg agent_name "$agent_name" --arg model "$IDA_STATE_MODEL" --arg status "$task_status" \
    --arg task_id_remote "$task_id" --rawfile answer "$answer_file" \
    --arg result_kind "$result_kind" --arg availability "$availability" --arg class "$class" \
    --argjson artifact_reference "$artifact_reference" --argjson terminal "$terminal" --argjson ambiguous "$ambiguous" '
      {schema:$schema,task_id:$id,provider:"ida",region:"sg",kind:$kind,session_marker:$marker,
       session_id:$session_id,task_id_remote:(if $task_id_remote=="" then null else $task_id_remote end),
       agent_id:(if $agent_id=="" then null else $agent_id end),
       agent_name:(if $agent_name=="" then null else $agent_name end),model:(if $model=="" then null else $model end),
       provider_status:(if $status=="" then null else $status end),terminal:$terminal,ambiguous:$ambiguous,
       result_availability:$availability,result_kind:(if $result_kind=="" then null else $result_kind end),
       answer:(if $answer=="" then null else $answer end),artifact_reference:$artifact_reference,
       error_class:(if $class=="" then null else $class end),observed_at:(now|todateiso8601)}'
  rm -rf -- "$root"
}

checkpoint_submission_boundary() {
  local id=$1 lock
  lock=$(fm_remote_task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_ida_state_load "$id" || [ "$REMOTE_STATE_PHASE" != submission-not-started ]; then
    fm_lock_release "$lock"
    return 1
  fi
  fm_remote_state_transition "$id" submission-unknown "" "" submission-request-in-flight armed "" "" "" '{}'
  local rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

submit_observation() { # <id> <root>
  local id=$1 root=$2 arguments out err
  local class session_id task_id agent_id_arg model_arg detail_session detail_task
  arguments="$root/arguments.json"; out="$root/submit.out"; err="$root/submit.err"
  fm_remote_instruction_validate "$id" "$REMOTE_STATE_INSTRUCTION_FILE" || return 1
  [ "$(fm_remote_sha256_file "$REMOTE_STATE_INSTRUCTION_FILE")" = "$REMOTE_STATE_INSTRUCTION_SHA256" ] || die "iDA instruction file changed before submission"
  checkpoint_submission_boundary "$id" || die "iDA submission state changed before the request boundary"
  agent_id_arg=$IDA_STATE_AGENT_ID; model_arg=$IDA_STATE_MODEL
  jq -n --rawfile content "$REMOTE_STATE_INSTRUCTION_FILE" --arg name "$IDA_STATE_MARKER" \
    --arg timeout "$IDA_WAIT_TIMEOUT_MS" --arg agent_id "$agent_id_arg" --arg model "$model_arg" '
      {content:$content,name:$name,timeoutMs:$timeout}
      + (if $agent_id == "" then {} else {agentId:$agent_id} end)
      + (if $model == "" then {} else {model:$model} end)' >"$arguments" || die "cannot stage private iDA submission"
  chmod 0600 "$arguments"
  if "$SCRIPT_DIR/fm-bytedcli-mcp-call.sh" ida_deep_research_create "$arguments" >"$out" 2>"$err"; then IDA_RC=0; else IDA_RC=$?; fi
  rm -f -- "$arguments"
  if [ "$IDA_RC" -eq 0 ] && fm_ida_structured_success "$out" \
      && fm_ida_numeric_id "$(jq -r '.data.session_id // "" | tostring' "$out")" \
      && [ -n "$(jq -r '.data.task_id // "" | tostring' "$out")" ]; then
    session_id=$(jq -r '.data.session_id | tostring' "$out")
    task_id=$(jq -r '.data.task_id | tostring' "$out")
    session_observation "$id" "$session_id" submission "$task_id"
    return 0
  fi
  detail_session=$(jq -r '.error.details.session_id // "" | tostring' "$out" 2>/dev/null)
  detail_task=$(jq -r '.error.details.task_id // "" | tostring' "$out" 2>/dev/null)
  if fm_ida_numeric_id "$detail_session" && [ -n "$detail_task" ]; then
    session_observation "$id" "$detail_session" submission "$detail_task"
    return 0
  fi
  fm_ida_normalize_error "$out" "$err" "$root/error.json"
  class=$(fm_remote_error_classify "$root/error.json")
  # A timeout/error may follow remote acceptance. Reconcile the unique marker
  # before deciding; never issue a second Deep Research create from this phase.
  fm_ida_state_load "$id" || die "cannot reload iDA state after submission"
  if list_marker "$id" "$root" && [ "$LIST_COUNT" -eq 1 ] && [ "$LIST_TRUNCATED" = false ]; then
    session_id=$(jq -r '.sessions[0].id' "$root/list.json")
    session_observation "$id" "$session_id" reconcile
  elif [ "$LIST_OK" = true ] && [ "$LIST_COUNT" -eq 0 ] && [ "$LIST_TRUNCATED" = false ] \
      && { [ "$class" = auth ] || [ "$class" = unsupported ] || [ "$class" = rate-limited ]; }; then
    jq -cn --arg schema "$IDA_OBSERVATION_SCHEMA" --arg id "$id" --arg marker "$IDA_STATE_MARKER" --arg class "$class" '
      {schema:$schema,task_id:$id,provider:"ida",region:"sg",kind:"submission",session_marker:$marker,
       session_id:null,task_id_remote:null,agent_id:null,agent_name:null,model:null,provider_status:"rejected",
       terminal:true,ambiguous:false,result_availability:"error",result_kind:null,answer:null,
       artifact_reference:null,error_class:$class,observed_at:(now|todateiso8601)}'
  else
    ambiguous_observation "$id" submission "submission-acceptance-unknown-$class" "${LIST_COUNT:-0}"
  fi
}

observe_or_submit() ( # <id> <allow-submit:true|false>
  local id=$1 allow_submit=$2 root session_id
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  if jq -e '.provider_state.followup_action_id != null and .provider_state.task_id == null' "$REMOTE_STATE_FILE" >/dev/null; then
    ambiguous_observation "$id" reconcile followup-turn-identity-unproven 0 "$IDA_STATE_SESSION_ID"
    return
  fi
  if [ -n "$IDA_STATE_SESSION_ID" ]; then session_observation "$id" "$IDA_STATE_SESSION_ID" session; return; fi
  root=$(temp_root)
  trap 'rm -rf -- "$root"' EXIT
  if ! list_marker "$id" "$root"; then
    error_observation "$id" reconcile "$LIST_CLASS"
  elif [ "$LIST_COUNT" -eq 1 ] && [ "$LIST_TRUNCATED" = false ]; then
    session_id=$(jq -r '.sessions[0].id' "$root/list.json")
    session_observation "$id" "$session_id" reconcile
  elif [ "$LIST_COUNT" -gt 1 ]; then
    ambiguous_observation "$id" reconcile duplicate-session-marker "$LIST_COUNT"
  elif [ "$LIST_TRUNCATED" = true ]; then
    ambiguous_observation "$id" reconcile truncated-session-list 0
  elif [ "$allow_submit" = true ] && [ "$REMOTE_STATE_PHASE" = submission-not-started ]; then
    # shellcheck source=bin/fm-task-lifecycle-lib.sh
    . "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
    fm_task_lifecycle_execution_allowed "$id" || die 'task disposition forbids provider submission'
    submit_observation "$id" "$root"
  else
    ambiguous_observation "$id" reconcile session-marker-not-found 0
  fi
)

transient_observation_repeatable() { # <observation>
  jq -e '
    .terminal == false
    and .ambiguous == false
    and .result_availability == "error"
    and .answer == null
    and (.error_class == "provider-error"
      or .error_class == "timeout"
      or .error_class == "unavailable"
      or .error_class == "rate-limited")
  ' "$1" >/dev/null 2>&1
}

observations_semantically_equal() { # <older> <newer>
  jq -s -e '((.[0] | del(.observed_at)) == (.[1] | del(.observed_at)))' "$1" "$2" >/dev/null 2>&1
}

state_semantic_signature() { # <state-file>
  jq -cS '{task_id,provider,phase,outcome,error_class,provider_checkpoint,result_availability,provider_state}' "$1"
}

durable_transient_matches() { # <id> <observation>
  local id=$1 observation=$2 task_dir previous
  case "$REMOTE_STATE_PHASE" in result-unavailable|submission-not-started) ;; *) return 1 ;; esac
  transient_observation_repeatable "$observation" || return 1
  previous=$REMOTE_STATE_RESULT_PATH
  task_dir=$(fm_remote_task_dir "$id") || return 1
  case "$previous" in "$task_dir"/artifacts/*-observation.json) ;; *) return 1 ;; esac
  fm_remote_private_file_safe "$previous" || return 1
  fm_ida_observation_validate "$previous" "$id" "$IDA_STATE_MARKER" || return 1
  transient_observation_repeatable "$previous" || return 1
  observations_semantically_equal "$previous" "$observation"
}

sleep_milliseconds() { # <positive-ms>
  local seconds
  printf -v seconds '%s.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"
  sleep "$seconds"
}

source_observe_with_backoff() ( # <id>
  local id=$1 root current previous state_signature next_signature delay
  root=$(temp_root); current="$root/current.json"; previous="$root/previous.json"
  trap 'rm -rf -- "$root"' EXIT
  observe_or_submit "$id" true >"$current"
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  if ! durable_transient_matches "$id" "$current"; then cat "$current"; return; fi
  cp "$current" "$previous" || die "cannot stage iDA transient observation"
  state_signature=$(state_semantic_signature "$REMOTE_STATE_FILE") || die "cannot identify iDA transient state"
  delay=$IDA_TRANSIENT_BACKOFF_INITIAL_MS
  while :; do
    sleep_milliseconds "$delay"
    observe_or_submit "$id" true >"$current"
    fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
    next_signature=$(state_semantic_signature "$REMOTE_STATE_FILE") || die "cannot identify iDA transient state"
    if [ "$next_signature" != "$state_signature" ] \
        || ! transient_observation_repeatable "$current" \
        || ! observations_semantically_equal "$previous" "$current"; then
      cat "$current"
      return
    fi
    cp "$current" "$previous" || die "cannot stage iDA transient observation"
    if [ "$delay" -lt "$IDA_TRANSIENT_BACKOFF_MAX_MS" ]; then
      if [ "$delay" -gt "$((IDA_TRANSIENT_BACKOFF_MAX_MS / 2))" ]; then
        delay=$IDA_TRANSIENT_BACKOFF_MAX_MS
      else
        delay=$((delay * 2))
      fi
    fi
  done
)

write_report() { # <id> <observation> <outcome>
  local id=$1 observation=$2 outcome=$3 report answer availability class result_kind
  report=$(fm_remote_report_path "$id") || return 1
  fm_remote_report_replaceable "$id" || return 1
  answer=$(jq -r '.answer // ""' "$observation")
  availability=$(jq -r '.result_availability' "$observation")
  result_kind=$(jq -r '.result_kind // ""' "$observation")
  class=$(jq -r '.error_class // ""' "$observation")
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  {
    printf '# iDA remote-agent report\n\n'
    printf -- '- Task: `%s`\n- Executor: `remote-agent`\n- Provider: `ida`\n- Region: `sg`\n' "$id"
    printf -- '- Session marker: `%s`\n- Session: `%s`\n- Remote task: `%s`\n' "$IDA_STATE_MARKER" \
      "$(jq -r '.session_id // "unavailable"' "$observation")" "$(jq -r '.task_id_remote // "unavailable"' "$observation")"
    printf -- '- Agent: `%s`\n- Model: `%s`\n' \
      "$(jq -r '.agent_name // .agent_id // "unavailable"' "$observation")" \
      "$(jq -r '.model // "unavailable"' "$observation")"
    [ -z "$REMOTE_STATE_BYTEDCLI_VERSION" ] || printf -- '- Legacy bytedcli version: `%s` (informational)\n' "$REMOTE_STATE_BYTEDCLI_VERSION"
    printf -- '- Outcome: `%s`\n- Result availability: `%s`\n' "$outcome" "$availability"
    [ -z "$result_kind" ] || printf -- '- Result kind: `%s`\n' "$result_kind"
    [ -z "$class" ] || printf -- '- Error class: `%s`\n' "$class"
    printf '\n## Provider Result\n\n'
    if [ "$availability:$result_kind" = available:artifact ]; then printf '%s\n' 'A structured Deep Research final-answer artifact is available through the recorded iDA session.';
    elif [ "$availability" = available ]; then printf '%s\n' "$answer";
    elif [ "$availability" = zero ]; then printf '%s\n' 'The provider completed successfully but returned an exact empty final answer.';
    elif [ "$availability" = unavailable ]; then printf '%s\n' 'No final provider answer is available for this terminal outcome.';
    else printf '%s\n' 'The provider returned an error; no final answer was recovered.'; fi
    printf '\n## Evidence Boundary\n\n'
    printf '%s\n' '- This report contains only normalized iDA identity, terminal state, final-answer text, or a safe structured-artifact reference.'
    printf '%s\n' '- Private prompts, credentials, tokens, PII-bearing payloads, and raw event streams are not preserved.'
    printf '%s\n' '- Provider output grants no implementation, publication, merge, destructive, legal, or security authority.'
  } >"$report" || return 1
  chmod 0600 "$report" || return 1
  printf '%s\n' "$report"
}

cmd_handle_locked() {
  local id=$1 seq=$2 result=$3 source artifact patch report outcome availability class status_kind session_id next_phase
  source=$(fm_remote_source_id ida "$id") || die "invalid iDA task id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be nonnegative" ;; esac
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  if ! fm_ida_observation_validate "$result" "$id" "$IDA_STATE_MARKER"; then
    local prior prior_marker old_match=0
    for prior in "$(fm_remote_task_dir "$id")/generations/"*.json; do
      fm_remote_state_validate_file "$prior" || continue
      prior_marker=$(jq -r '.provider_state.session_marker' "$prior")
      fm_ida_observation_validate "$result" "$id" "$prior_marker" || continue
      old_match=$((old_match+1))
    done
    [ "$old_match" = 1 ] || die 'iDA observation identity is unproven'
    # The captured old result and frozen terminal remain durable; acknowledge
    # this exact late event without applying it to the new turn's state.
    if ! fm_procevent_is_handled "$STATE" "$source" "$seq"; then
      local late_note="note: retained earlier iDA turn evidence source=$source sequence=$seq; current execution unchanged"
      grep -Fx "$late_note" "$STATE/$id.status" >/dev/null 2>&1 || fm_remote_status_append "$id" "$late_note" || die 'cannot publish retained earlier-turn evidence'
      "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null || die 'cannot acknowledge retained earlier-turn result'
    fi
    printf 'handled: %s earlier-turn-preserved=true\n' "$id"
    return 0
  fi
  if fm_procevent_is_handled "$STATE" "$source" "$seq"; then printf 'handled: %s duplicate=true\n' "$id"; return 0; fi
  case "$REMOTE_STATE_PHASE" in
    terminal-success|terminal-failure|terminal-cancelled)
      "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
        || die "cannot acknowledge stale post-terminal iDA observation"
      printf 'handled: %s terminal-preserved=true\n' "$id"
      return 0
      ;;
  esac
  if [ "$REMOTE_STATE_OUTCOME" = cancellation-requested ] \
      && jq -e '.terminal == false' "$result" >/dev/null 2>&1; then
    "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
      || die "cannot acknowledge stale iDA observation after cancellation request"
    printf 'handled: %s cancellation-preserved=true\n' "$id"
    return 0
  fi
  artifact=$(fm_remote_artifact_store "$id" observation "$result") || die "cannot store normalized iDA observation"
  session_id=$(jq -r '.session_id // ""' "$result")
  patch=$(jq -c '{session_id:.session_id,task_id:.task_id_remote,agent_id:.agent_id,agent_name:.agent_name,model:.model,provider_status:.provider_status,result_kind:.result_kind} | with_entries(select(.value != null))' "$result")
  availability=$(jq -r '.result_availability' "$result")
  class=$(jq -r '.error_class // ""' "$result")
  if jq -e '.provider_state.local_readback_blocked == true' "$REMOTE_STATE_FILE" >/dev/null \
      && jq -e '.ambiguous == false and (.error_class == null or .terminal == true)' "$result" >/dev/null; then
    fm_remote_status_append "$id" "resolved [key=ida-readback-local]: iDA readback recovered for the original task" \
      || die "cannot resolve iDA readback blocker"
    patch=$(printf '%s' "$patch" | jq '. + {local_readback_blocked:false}')
  fi
  if jq -e '.ambiguous == true' "$result" >/dev/null; then
    fm_remote_state_transition "$id" ambiguous submission-acceptance-unknown "$class" reconcile-ambiguous interrupted "$availability" "$artifact" "" "$patch" || die "cannot checkpoint ambiguous iDA state"
    fm_remote_status_append "$id" "blocked [key=ida-submission-ambiguous]: iDA session identity is ambiguous; reconcile or adopt before any retry" || die "cannot append iDA blocker"
  elif jq -e '.terminal == false' "$result" >/dev/null; then
    if [ "$availability" = error ]; then
      next_phase="result-unavailable"
      case "$REMOTE_STATE_PHASE" in submission-not-started|submission-unknown) next_phase=$REMOTE_STATE_PHASE ;; esac
      if fm_ida_local_read_error "$class"; then
        patch=$(printf '%s' "$patch" | jq '. + {local_readback_blocked:true}')
        fm_remote_state_transition "$id" "$next_phase" unavailable "$class" provider-readback-blocked interrupted "$availability" "$artifact" "" "$patch" \
          || die "cannot checkpoint local iDA readback failure"
        fm_remote_status_append "$id" "blocked [key=ida-readback-local]: iDA local readback failed ($class); repair CLI execution or response validation, then use adopt for this task; remote outcome is unconfirmed" \
          || die "cannot append iDA readback blocker"
        "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null || die "cannot acknowledge local iDA readback failure"
        printf 'handled: %s readback-blocked=%s\n' "$id" "$class"
        return 0
      fi
      fm_remote_state_transition "$id" "$next_phase" unavailable "$class" provider-readback-unavailable rearming "$availability" "$artifact" "" "$patch" || die "cannot checkpoint unavailable iDA readback"
    else
      fm_remote_state_transition "$id" running "" "" provider-running rearming "$availability" "$artifact" "" "$patch" || die "cannot checkpoint running iDA state"
    fi
    cmd_arm_locked "$id" >/dev/null || die "cannot re-arm iDA readback"
  else
    status_kind=$(fm_ida_status_kind "$(jq -r '.provider_status // ""' "$result")")
    case "$status_kind:$availability:$class" in
      success:error:*) outcome=failed ;;
      success:*:|running:*:) outcome=succeeded ;;
      cancelled:*|*:provider-cancelled) outcome=cancelled ;;
      *) outcome=failed ;;
    esac
    report=$(write_report "$id" "$result" "$outcome") || die "cannot write iDA report"
    case "$outcome" in
      succeeded) fm_remote_state_transition "$id" terminal-success succeeded "" result-verified terminal "$availability" "$artifact" "$report" "$patch" ;;
      cancelled) fm_remote_state_transition "$id" terminal-cancelled cancelled "${class:-provider-cancelled}" cancellation-confirmed terminal "$availability" "$artifact" "$report" "$patch" ;;
      *) fm_remote_state_transition "$id" terminal-failure failed "${class:-provider-terminal-failure}" provider-terminal terminal "$availability" "$artifact" "$report" "$patch" ;;
    esac || die "cannot checkpoint terminal iDA state"
    if [ "$outcome" = succeeded ]; then fm_remote_status_append "$id" "done: iDA remote research complete; see data/$id/report.md";
    elif [ "$outcome" = cancelled ]; then fm_remote_status_append "$id" "failed: iDA remote research cancelled; see data/$id/report.md";
    else fm_remote_status_append "$id" "failed: iDA remote research failed; see data/$id/report.md"; fi || die "cannot append terminal iDA status"
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null || die "cannot acknowledge iDA observation"
  printf 'handled: %s phase=%s session=%s\n' "$id" "$(jq -r '.phase' "$(fm_remote_state_path "$id")")" "${session_id:-unavailable}"
}

cmd_handle() {
  local id=${1-} lock
  [ "$#" -eq 3 ] || usage
  lock=$(fm_remote_task_lock_path "$id")
  ( fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"; trap 'fm_lock_release "$lock"' EXIT; cmd_handle_locked "$@" )
}

cmd_arm_locked() {
  local id=$1 source
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  case "$REMOTE_STATE_PHASE" in terminal-success|terminal-failure|terminal-cancelled) die "iDA task is terminal" ;; esac
  source=$(fm_remote_source_id ida "$id") || die "invalid iDA task id"
  "$SCRIPT_DIR/fm-procevent.sh" register ida "$source" -- "$SCRIPT_DIR/fm-procevent-ida.sh" source "$id" || return 1
  fm_remote_state_transition "$id" "$REMOTE_STATE_PHASE" "$REMOTE_STATE_OUTCOME" "$REMOTE_STATE_ERROR_CLASS" waiter-armed armed "$REMOTE_STATE_RESULT_AVAILABILITY" "" "" '{}'
}

cmd_arm() {
  local id=${1-} lock
  [ "$#" -eq 1 ] || usage
  lock=$(fm_remote_task_lock_path "$id")
  ( fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"; trap 'fm_lock_release "$lock"' EXIT; cmd_arm_locked "$id" )
}

cmd_autohandle() {
  local source=${1-} id
  [ "$#" -eq 3 ] || usage
  case "$source" in ida-?*) id=${source#ida-} ;; *) die "not an iDA source" ;; esac
  [ "$(fm_remote_source_id ida "$id")" = "$source" ] || die "noncanonical iDA source"
  cmd_handle "$id" "$2" "$3"
}

cmd_terminal() {
  [ "$#" -eq 1 ] || usage
  jq -e '.schema=="fm-ida-observation.v1"' "$1" >/dev/null 2>&1 || return 1
  jq -e '.terminal==true or .ambiguous==true' "$1" >/dev/null 2>&1 && return 0
  # Ending a failed local waiter never asserts a remote terminal outcome.
  jq -e '.terminal==false and .result_availability=="error"' "$1" >/dev/null 2>&1 \
    && fm_ida_local_read_error "$(jq -r '.error_class // ""' "$1")"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  source) shift; [ "$#" -eq 1 ] || usage; source_observe_with_backoff "$1" ;;
  observe) shift; [ "$#" -eq 1 ] || usage; observe_or_submit "$1" false ;;
  handle) shift; cmd_handle "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  retire) shift; [ "$#" -eq 1 ] || usage; "$SCRIPT_DIR/fm-procevent.sh" retire "$(fm_remote_source_id ida "$1")" ;;
  -h|--help|'') usage ;;
  *) usage ;;
esac
