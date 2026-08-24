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

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
case "$IDA_PAGE_SIZE:$IDA_WAIT_TIMEOUT_MS:$IDA_MARKER_SCAN_GRACE_SECONDS" in *[!0-9:]*|0:*|*:0:*|*:0|*::*) die "iDA bounds must be positive integers" ;; esac

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
}

error_observation() { # <id> <kind> <class>
  jq -cn --arg schema "$IDA_OBSERVATION_SCHEMA" --arg id "$1" --arg marker "$IDA_STATE_MARKER" \
    --arg kind "$2" --arg class "$3" '
      {schema:$schema,task_id:$id,provider:"ida",region:"sg",kind:$kind,session_marker:$marker,
       session_id:null,task_id_remote:null,agent_id:null,agent_name:null,model:null,provider_status:null,
       terminal:false,ambiguous:false,result_availability:"error",answer:null,error_class:$class,observed_at:(now|todateiso8601)}'
}

ambiguous_observation() { # <id> <kind> <class> [count]
  jq -cn --arg schema "$IDA_OBSERVATION_SCHEMA" --arg id "$1" --arg marker "$IDA_STATE_MARKER" \
    --arg kind "$2" --arg class "$3" --arg count "${4:-0}" '
      {schema:$schema,task_id:$id,provider:"ida",region:"sg",kind:$kind,session_marker:$marker,
       session_id:null,task_id_remote:null,agent_id:null,agent_name:null,model:null,provider_status:null,
       terminal:false,ambiguous:true,result_availability:"unavailable",answer:null,error_class:$class,
       match_count:($count|tonumber),observed_at:(now|todateiso8601)}'
}

list_marker() { # <id> <root> ; sets LIST_* and leaves normalized list in root
  local id=$1 root=$2 out err normalized raw_normalized candidates matches agent_id created_epoch session_id name get prefix
  out="$root/list.out"; err="$root/list.err"; normalized="$root/list.json"; raw_normalized="$root/list-raw.json"
  agent_id=$IDA_STATE_AGENT_ID
  if [ -z "$agent_id" ]; then
    run_ida_json "$out" "$err" agent get
    agent_id=$(jq -r 'if .status=="success" and .error==null and .data.deep_research_enabled==true then .data.id // empty else empty end | tostring' "$out" 2>/dev/null)
    if [ "$IDA_RC" -ne 0 ] || ! fm_ida_numeric_id "$agent_id"; then
      fm_ida_normalize_error "$out" "$err" "$normalized"
      LIST_OK=false; LIST_CLASS=$(fm_remote_error_classify "$normalized"); LIST_COUNT=0; LIST_TRUNCATED=true
      return 1
    fi
  fi
  run_ida_json "$out" "$err" session raw list --agent-id "$agent_id" --page-size "$IDA_PAGE_SIZE"
  if [ "$IDA_RC" -ne 0 ] || ! fm_ida_structured_success "$out" \
      || ! jq -e '.data.sessions.sessionList | type == "array"' "$out" >/dev/null 2>&1; then
    fm_ida_normalize_error "$out" "$err" "$normalized"
    LIST_OK=false
    LIST_CLASS=$(fm_remote_error_classify "$normalized")
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
      if [ "$IDA_RC" -ne 0 ] || ! fm_ida_structured_success "$get" \
          || ! jq -e --arg sid "$session_id" --arg prefix "$prefix" '
            (.data.session.id | tostring) == $sid
            and ([.data.messages[]? | select(.type == 0 and (.text | type == "string")) | .text]
              | any(. == $prefix or startswith($prefix + "\n")))
          ' "$get" >/dev/null 2>&1; then
        if [ "$IDA_RC" -ne 0 ] || ! fm_ida_structured_success "$get"; then
          fm_ida_normalize_error "$get" "$err" "$normalized"
          LIST_OK=false; LIST_CLASS=$(fm_remote_error_classify "$normalized"); LIST_COUNT=0; LIST_TRUNCATED=true
          return 1
        fi
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

session_observation() { # <id> <session-id> <kind>
  local id=$1 session_id=$2 kind=$3 root out err normalized status status_kind answer availability terminal ambiguous=false class=""
  local agent_id agent_name
  root=$(temp_root); out="$root/get.out"; err="$root/get.err"; normalized="$root/error.json"
  run_ida_json "$out" "$err" session get --session-id "$session_id"
  if [ "$IDA_RC" -ne 0 ] || ! fm_ida_structured_success "$out" \
      || [ "$(jq -r '.data.session.id // "" | tostring' "$out" 2>/dev/null)" != "$session_id" ]; then
    fm_ida_normalize_error "$out" "$err" "$normalized"
    class=$(fm_remote_error_classify "$normalized")
    rm -rf -- "$root"
    error_observation "$id" "$kind" "$class"
    return 0
  fi
  if ! session_payload_has_marker "$out"; then
    rm -rf -- "$root"
    ambiguous_observation "$id" "$kind" session-marker-mismatch 1
    return 0
  fi
  status=$(jq -r '.data.session.latest_task_status // ""' "$out")
  status_kind=$(fm_ida_status_kind "$status")
  answer=$(jq -r '[.data.messages[]? | select(.visible == true and .type == 8 and (.text | type == "string" and length > 0)) | .text] | last // ""' "$out" \
    | fm_remote_redact_result_text "$REMOTE_STATE_INSTRUCTION_FILE") || die "cannot normalize iDA final answer"
  agent_id=$(jq -r '.data.session.agent_id // "" | tostring' "$out")
  agent_name=$(jq -r '.data.session.agent_name // ""' "$out")
  case "$status_kind" in
    success) terminal=true; [ -n "$answer" ] && availability=available || availability=zero ;;
    failure) terminal=true; availability=error; class='provider-terminal-failure' ;;
    cancelled) terminal=true; availability=unavailable; class='provider-cancelled' ;;
    running) terminal=false; availability=unavailable ;;
    ambiguous) terminal=false; ambiguous=true; availability=unavailable; class='provider-status-ambiguous' ;;
  esac
  jq -cn --arg schema "$IDA_OBSERVATION_SCHEMA" --arg id "$id" --arg marker "$IDA_STATE_MARKER" \
    --arg kind "$kind" --arg session_id "$session_id" --arg agent_id "$agent_id" \
    --arg agent_name "$agent_name" --arg model "$IDA_STATE_MODEL" --arg status "$status" \
    --arg answer "$answer" --arg availability "$availability" --arg class "$class" \
    --argjson terminal "$terminal" --argjson ambiguous "$ambiguous" '
      {schema:$schema,task_id:$id,provider:"ida",region:"sg",kind:$kind,session_marker:$marker,
       session_id:$session_id,task_id_remote:null,agent_id:(if $agent_id=="" then null else $agent_id end),
       agent_name:(if $agent_name=="" then null else $agent_name end),model:(if $model=="" then null else $model end),
       provider_status:(if $status=="" then null else $status end),terminal:$terminal,ambiguous:$ambiguous,
       result_availability:$availability,answer:(if $answer=="" then null else $answer end),
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
  local class session_id task_id agent_id_arg model_arg detail_session detail_task verified
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
    verified="$root/verified-submission.json"
    session_observation "$id" "$session_id" submission >"$verified"
    jq --arg task_id "$task_id" '.task_id_remote=$task_id' "$verified"
    return 0
  fi
  detail_session=$(jq -r '.error.details.session_id // "" | tostring' "$out" 2>/dev/null)
  detail_task=$(jq -r '.error.details.task_id // "" | tostring' "$out" 2>/dev/null)
  if fm_ida_numeric_id "$detail_session" && [ -n "$detail_task" ]; then
    verified="$root/verified-submission.json"
    session_observation "$id" "$detail_session" submission >"$verified"
    jq --arg task_id "$detail_task" '.task_id_remote=$task_id' "$verified"
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
       terminal:true,ambiguous:false,result_availability:"error",answer:null,error_class:$class,observed_at:(now|todateiso8601)}'
  else
    ambiguous_observation "$id" submission "submission-acceptance-unknown-$class" "${LIST_COUNT:-0}"
  fi
}

observe_or_submit() ( # <id> <allow-submit:true|false>
  local id=$1 allow_submit=$2 root session_id
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
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
    submit_observation "$id" "$root"
  else
    ambiguous_observation "$id" reconcile session-marker-not-found 0
  fi
)

write_report() { # <id> <observation> <outcome>
  local id=$1 observation=$2 outcome=$3 report answer availability class
  report=$(fm_remote_report_path "$id") || return 1
  fm_remote_report_replaceable "$id" || return 1
  answer=$(jq -r '.answer // ""' "$observation")
  availability=$(jq -r '.result_availability' "$observation")
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
    [ -z "$class" ] || printf -- '- Error class: `%s`\n' "$class"
    printf '\n## Provider Result\n\n'
    if [ "$availability" = available ]; then printf '%s\n' "$answer";
    elif [ "$availability" = zero ]; then printf '%s\n' 'The provider completed successfully but returned an exact empty final answer.';
    elif [ "$availability" = unavailable ]; then printf '%s\n' 'No final provider answer is available for this terminal outcome.';
    else printf '%s\n' 'The provider returned an error; no final answer was recovered.'; fi
    printf '\n## Evidence Boundary\n\n'
    printf '%s\n' '- This report contains only normalized iDA identity, terminal state, and final-answer fields.'
    printf '%s\n' '- Private prompts, credentials, tokens, PII-bearing payloads, and raw event streams are not preserved.'
    printf '%s\n' '- Provider output grants no implementation, publication, merge, destructive, legal, or security authority.'
  } >"$report" || return 1
  chmod 0600 "$report" || return 1
  printf '%s\n' "$report"
}

cmd_handle_locked() {
  local id=$1 seq=$2 result=$3 source artifact patch report outcome availability class status_kind session_id
  source=$(fm_remote_source_id ida "$id") || die "invalid iDA task id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be nonnegative" ;; esac
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  fm_ida_observation_validate "$result" "$id" "$IDA_STATE_MARKER" || die "iDA observation is malformed"
  if fm_procevent_is_handled "$STATE" "$source" "$seq"; then printf 'handled: %s duplicate=true\n' "$id"; return 0; fi
  artifact=$(fm_remote_artifact_store "$id" observation "$result") || die "cannot store normalized iDA observation"
  session_id=$(jq -r '.session_id // ""' "$result")
  patch=$(jq -c '{session_id:.session_id,task_id:.task_id_remote,agent_id:.agent_id,agent_name:.agent_name,model:.model,provider_status:.provider_status} | with_entries(select(.value != null))' "$result")
  availability=$(jq -r '.result_availability' "$result")
  class=$(jq -r '.error_class // ""' "$result")
  if jq -e '.ambiguous == true' "$result" >/dev/null; then
    fm_remote_state_transition "$id" ambiguous submission-acceptance-unknown "$class" reconcile-ambiguous interrupted "$availability" "$artifact" "" "$patch" || die "cannot checkpoint ambiguous iDA state"
    fm_remote_status_append "$id" "blocked [key=ida-submission-ambiguous]: iDA session identity is ambiguous; reconcile or adopt before any retry" || die "cannot append iDA blocker"
  elif jq -e '.terminal == false' "$result" >/dev/null; then
    if [ "$availability" = error ]; then
      next_phase="result-unavailable"
      case "$REMOTE_STATE_PHASE" in submission-not-started|submission-unknown) next_phase=$REMOTE_STATE_PHASE ;; esac
      fm_remote_state_transition "$id" "$next_phase" unavailable "$class" provider-readback-unavailable rearming "$availability" "$artifact" "" "$patch" || die "cannot checkpoint unavailable iDA readback"
    else
      fm_remote_state_transition "$id" running "" "" provider-running rearming "$availability" "$artifact" "" "$patch" || die "cannot checkpoint running iDA state"
    fi
    cmd_arm_locked "$id" >/dev/null || die "cannot re-arm iDA readback"
  else
    status_kind=$(fm_ida_status_kind "$(jq -r '.provider_status // ""' "$result")")
    case "$status_kind:$class" in
      success:|running:) outcome=succeeded ;;
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

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  source) shift; [ "$#" -eq 1 ] || usage; observe_or_submit "$1" true ;;
  observe) shift; [ "$#" -eq 1 ] || usage; observe_or_submit "$1" false ;;
  handle) shift; cmd_handle "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; jq -e '.schema=="fm-ida-observation.v1" and (.terminal==true or .ambiguous==true)' "$1" >/dev/null 2>&1 ;;
  retire) shift; [ "$#" -eq 1 ] || usage; "$SCRIPT_DIR/fm-procevent.sh" retire "$(fm_remote_source_id ida "$1")" ;;
  -h|--help|'') usage ;;
  *) usage ;;
esac
