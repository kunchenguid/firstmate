#!/usr/bin/env bash
# Firstmate-owned native iDA remote-agent executor.
#
# Usage:
#   fm-remote-agent-ida.sh probe
#   fm-remote-agent-ida.sh dispatch <task-id> --instructions <private-file> [--model <name>] [--document]
#   fm-remote-agent-ida.sh adopt <task-id>
#   fm-remote-agent-ida.sh followup <task-id> --action-id <id> --expected-terminal-generation <n> --instructions <private-file>
# A followup is one new turn in the SAME session. It freezes the prior terminal
# record and checkpoints attempted before the sole create. Replaying the action
# only reads back a same-message marker/task correlation; adjacency or a newest
# task never proves identity. Missing correlation remains submission-unknown.
#   fm-remote-agent-ida.sh state <task-id> [--durable-only]
#   fm-remote-agent-ida.sh artifacts <task-id>
#   fm-remote-agent-ida.sh interrupt-wait <task-id>
#   fm-remote-agent-ida.sh cancel <task-id> --authorize-provider-cancel
#   fm-remote-agent-ida.sh abandon <task-id> --authorize-abandon
#   fm-remote-agent-ida.sh retire <task-id>
# Retirement's paired backlog transition is owned by fm-backlog-transition-lib.sh.
#
# New dispatches require config/ida-remote-agent, whose schema is owned by
# fm-ida-remote-lib.sh, and always use region=sg. `dispatch` durably records the
# task/provider identity, optional validated model, and session marker, then
# arms the process-event adapter;
# it does not block on Deep Research. The adapter reconciles that unique marker
# before the sole allowed create and after every ambiguous submission.
# Omit --model to leave the official create request unchanged and let iDA use
# its provider default. Explicit values must exactly match the name from the
# current SG `bytedcli ida model list` response.
#
# `cancel` is a destructive provider write and therefore requires the explicit
# --authorize-provider-cancel flag at the call site. A successful close response
# is not treated as terminal cancellation until authoritative session readback
# confirms it. After that confirmation, the command replaces any older local
# waiter before the normalized terminal observation enters durable capture.
# `interrupt-wait` stops only Firstmate's local waiter.
# `artifacts` performs a read-only, task-bound discovery call and projects the
# provider response to artifact/file identities, sizes, types, and availability
# before stdout. Artifact text, tables, rows, scripts, and embedded bodies never
# cross this consumer boundary; fetch a selected file URI separately only when
# its content is actually needed.
#
# `abandon` is the only escape for an ambiguous or submission-unknown task
# whose session marker authoritatively yields a complete non-truncated
# zero-match session list. It fail-terminals the durable record, performs no
# provider write, never retries or recreates, and requires the explicit
# --authorize-abandon flag; any future execution requires a separate explicit
# dispatch.
#
# `retire` requires a terminal normalized state, safe report, completed decision
# gate, and retired process-event source. It preserves data/<id>/report.md and
# removes only the volatile iDA metadata/state for that task.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-remote-agent-lib.sh
. "$SCRIPT_DIR/fm-remote-agent-lib.sh"
# shellcheck source=bin/fm-ida-remote-lib.sh
. "$SCRIPT_DIR/fm-ida-remote-lib.sh"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 2; }

temp_root() {
  local root
  root=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-ida-command.XXXXXX") || die "cannot create private iDA temporary storage"
  printf '%s\n' "$root"
}

cmd_probe() {
  local root out err capability rc=0 agent_id args=(agent get)
  [ "$#" -eq 0 ] || usage
  fm_ida_config_load || die "iDA remote-agent config is missing or invalid"
  fm_ida_resolve_bytedcli >/dev/null 2>&1 || die "bytedcli is unavailable"
  root=$(temp_root); out="$root/out"; err="$root/err"; capability="$root/capability.json"
  [ "$IDA_CONFIG_AGENT_ID" = default ] || args+=(--agent-id "$IDA_CONFIG_AGENT_ID")
  if fm_ida_run_bytedcli --json --as user ida --region sg "${args[@]}" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
  agent_id=$(jq -r 'if .status=="success" and .error==null and .data.deep_research_enabled==true then .data.id // empty else empty end | tostring' "$out" 2>/dev/null)
  if [ "$rc" -ne 0 ] || ! fm_ida_numeric_id "$agent_id" \
      || { [ "$IDA_CONFIG_AGENT_ID" != default ] && [ "$agent_id" != "$IDA_CONFIG_AGENT_ID" ]; }; then
    fm_ida_normalize_error "$out" "$err" "$root/error.json"
    jq -n --arg class "$(fm_remote_error_classify "$root/error.json")" \
      '{schema:"fm-ida-probe.v1",outcome:"unavailable",error_class:$class,provider:"ida",region:"sg",identity:"user"}'
    rm -rf -- "$root"
    return 1
  fi
  if fm_ida_run_bytedcli --json --as user ida --region sg session raw list --agent-id "$agent_id" --page-size 1 >"$out" 2>"$err"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ] || ! fm_ida_structured_success "$out" \
      || ! jq -e '.data.sessions.sessionList | type == "array"' "$out" >/dev/null 2>&1; then
    fm_ida_normalize_error "$out" "$err" "$root/error.json"
    jq -n --arg class "$(fm_remote_error_classify "$root/error.json")" \
      '{schema:"fm-ida-probe.v1",outcome:"unavailable",error_class:$class,provider:"ida",region:"sg",identity:"user"}'
    rm -rf -- "$root"
    return 1
  fi
  if ! "$SCRIPT_DIR/fm-bytedcli-mcp-call.sh" capabilities >"$capability" 2>"$err" \
      || ! fm_ida_structured_success "$capability"; then
    fm_ida_normalize_error "$capability" "$err" "$root/error.json"
    jq -n --arg class "$(fm_remote_error_classify "$root/error.json")" \
      '{schema:"fm-ida-probe.v1",outcome:"unavailable",error_class:$class,provider:"ida",region:"sg",identity:"user"}'
    rm -rf -- "$root"
    return 1
  fi
  jq -n --arg agent "$agent_id" \
    '{schema:"fm-ida-probe.v1",outcome:"ready",error_class:null,provider:"ida",region:"sg",identity:"user",agent_id:$agent,capabilities:["deep-research.create","deep-research.model-selection","session.list","session.get","chat.completion.close"]}'
  rm -rf -- "$root"
}

validate_dispatch_model() { # <model>
  local model=$1 root out err capability class code
  root=$(temp_root); out="$root/models.out"; err="$root/models.err"; capability="$root/capability.json"
  if ! "$SCRIPT_DIR/fm-bytedcli-mcp-call.sh" capabilities >"$capability" 2>"$err" \
      || ! fm_ida_structured_success "$capability"; then
    fm_ida_normalize_error "$capability" "$err" "$root/error.json"
    code=$(jq -r '.error.code // ""' "$root/error.json")
    class=$(fm_remote_error_classify "$root/error.json")
    rm -rf -- "$root"
    if [ "$code" = MCP_CAPABILITY_UNSUPPORTED ]; then
      die "installed iDA create command does not support --model; update bytedcli or omit the selection"
    fi
    die "cannot validate iDA model '$model': $class; run 'fm-remote-agent-ida.sh probe' to check iDA availability"
  fi
  if ! jq -e '.data.required_options | index("--model") != null' "$capability" >/dev/null 2>&1; then
    rm -rf -- "$root"
    die "installed iDA create command does not support --model; update bytedcli or omit the selection"
  fi
  if fm_ida_run_bytedcli --json --as user ida --region sg model list >"$out" 2>"$err"; then :; else
    fm_ida_normalize_error "$out" "$err" "$root/error.json"
    class=$(fm_remote_error_classify "$root/error.json")
    rm -rf -- "$root"
    die "cannot validate iDA model '$model': $class; run 'bytedcli --json --as user ida --region sg model list'"
  fi
  if ! fm_ida_structured_success "$out" \
      || ! jq -e '.data.models | type == "array" and all(.[]; .name | type == "string")' "$out" >/dev/null 2>&1; then
    rm -rf -- "$root"
    die "cannot validate iDA model '$model': provider returned an invalid model catalog"
  fi
  if ! jq -e --arg model "$model" '.data.models | any(.[]; .name == $model)' "$out" >/dev/null 2>&1; then
    rm -rf -- "$root"
    die "unsupported iDA model '$model'; choose an exact name from 'bytedcli --json --as user ida --region sg model list'"
  fi
  rm -rf -- "$root"
}

cmd_dispatch() {
  local id=${1-} instructions='' task_type=research model='' model_seen=false
  local sha marker provider_state lock rc agent_id
  [ -n "$id" ] || usage; shift
  fm_remote_task_id_valid "$id" || die "invalid task id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instructions) [ "$#" -ge 2 ] || usage; instructions=$2; shift 2 ;;
      --model)
        [ "$model_seen" = false ] || die "duplicate --model; select exactly one iDA model"
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "--model requires a non-empty value from 'bytedcli --json --as user ida --region sg model list'"
        case "$2" in --*) die "--model requires a value before the next option" ;; esac
        fm_ida_safe_token "$2" || die "malformed iDA model '$2'; use an exact name from 'bytedcli --json --as user ida --region sg model list'"
        model=$2; model_seen=true; shift 2
        ;;
      --model=*) die "use '--model <value>' exactly once for iDA dispatch" ;;
      --document) task_type=document; shift ;;
      *) die "unsupported iDA dispatch argument: $1" ;;
    esac
  done
  [ -n "$instructions" ] || die "dispatch requires --instructions <private-file>"
  [ -f "$DATA/$id/brief.md" ] && [ ! -L "$DATA/$id/brief.md" ] || die "ordinary Firstmate brief is missing or unsafe: data/$id/brief.md"
  fm_remote_instruction_validate "$id" "$instructions" || exit 1
  fm_ida_config_load || die "iDA remote agent is disabled: config is missing or invalid"
  [ "$IDA_CONFIG_ENABLED" = true ] || die "iDA remote agent is disabled in config"
  fm_ida_resolve_bytedcli >/dev/null 2>&1 || die "bytedcli is unavailable"
  [ -z "$model" ] || validate_dispatch_model "$model"
  sha=$(fm_remote_sha256_file "$instructions") || die "cannot hash iDA instruction"
  marker=$(fm_ida_session_marker "$id" "$sha") || die "cannot derive iDA session marker"
  [ "$IDA_CONFIG_AGENT_ID" = default ] && agent_id= || agent_id=$IDA_CONFIG_AGENT_ID
  provider_state=$(jq -cn --arg marker "$marker" --arg agent_id "$agent_id" --arg model "$model" \
    '{region:"sg",identity:"user",session_marker:$marker,session_id:null,task_id:null,
      agent_id:(if $agent_id=="" then null else $agent_id end),agent_name:null,
      model:(if $model=="" then null else $model end),provider_status:null}')
  lock=$(fm_remote_task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"
  trap 'fm_lock_release "$lock"' EXIT
  # shellcheck source=bin/fm-task-disposition-lib.sh
  . "$SCRIPT_DIR/fm-task-disposition-lib.sh"
  fm_task_disposition_effect_guard "$DATA" "$id" 'remote dispatch' || exit $?
  fm_task_historical_execution_guard "$DATA" "$id" || exit $?
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || die "task metadata already exists; dispatch refuses to replace another executor"
  fm_remote_state_initialize "$id" ida "$task_type" "$instructions" "$sha" "$provider_state" || die "cannot initialize iDA task state"
  if ! fm_remote_meta_write "$id" ida "$task_type"; then
    rc=$?; rm -rf -- "$(fm_remote_task_dir "$id")"
    [ "$rc" -eq 2 ] && die "task metadata appeared during iDA preparation"
    die "cannot publish iDA task metadata"
  fi
  fm_lock_release "$lock"; trap - EXIT
  "$SCRIPT_DIR/fm-procevent-ida.sh" arm "$id" >/dev/null || die "iDA task was recorded but its process-event source could not be armed; use adopt"
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null || die "iDA task was recorded but process-event reconciliation failed; use adopt"
  printf 'submitted: %s provider=ida session-marker=%s\n' "$id" "$marker"
}

cmd_followup() (
  local id=${1-} action='' expected='' instructions='' lock meta_lock root sha marker provider session parent_task
  local baseline output task='' current_action current_generation old_generation rc=0 old_report preserved_report record
  [ -n "$id" ] || usage; shift
  fm_remote_task_id_valid "$id" || die 'invalid task id'
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --action-id) action=$2 ;;
      --expected-terminal-generation) expected=$2 ;;
      --instructions) instructions=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  case "$expected" in ''|*[!0-9]*|0) die 'followup needs a positive terminal generation' ;; esac
  [ -n "$action" ] || die 'followup needs a stable action id'
  fm_remote_instruction_validate "$id" "$instructions" || exit 1
  fm_ida_config_load && [ "$IDA_CONFIG_ENABLED" = true ] || die 'iDA continuation is disabled'
  # shellcheck source=bin/fm-lease-lib.sh
  . "$SCRIPT_DIR/fm-lease-lib.sh"
  fm_lease_guard "$id" 'iDA followup' || exit $?
  meta_lock=$(fm_meta_lock_path "$STATE/$id.meta") || exit 1
  lock=$(fm_remote_task_lock_path "$id") || exit 1
  root=$(temp_root)
  trap 'fm_lock_release "$lock"; fm_lock_release "$meta_lock"; fm_lease_guard_release; rm -rf "$root"' EXIT
  fm_lock_acquire_wait "$meta_lock" || die 'cannot lock iDA metadata'
  fm_lock_acquire_wait "$lock" || die 'cannot lock iDA continuation'
  fm_ida_state_load "$id" || die 'iDA state is missing or invalid'
  fm_remote_meta_validate "$id" ida "$REMOTE_STATE_TASK_TYPE" || die 'iDA metadata identity differs'
  current_action=$(jq -r '.provider_state.followup_action_id // ""' "$REMOTE_STATE_FILE")
  current_generation=$(jq -r '.generation // 1' "$REMOTE_STATE_FILE")
  sha=$(fm_remote_sha256_file "$instructions") || exit 1
  output="$root/result.json"
  if [ "$current_action" = "$action" ]; then
    [ "$sha" = "$REMOTE_STATE_INSTRUCTION_SHA256" ] && \
      [ "$(jq -r '.provider_state.parent_generation' "$REMOTE_STATE_FILE")" = "$expected" ] || die 'followup action collision'
    session=$IDA_STATE_SESSION_ID
    task=$IDA_STATE_TASK_ID
    if [ -z "$task" ]; then
      # Only the provider exposing the marker and task on the SAME user
      # message can repair a lost response. New task count/order is irrelevant.
      fm_run_bash_timeout 30 fm_ida_run_bytedcli --json --as user ida --region sg session get --session-id "$session" > "$output" 2> "$root/error" || die 'followup readback unavailable; no request repeated'
      fm_ida_structured_success "$output" || die 'followup readback invalid; no request repeated'
      [ "$(jq -r '.data.session.id // empty | tostring' "$output")" = "$session" ] || die 'followup readback session mismatch; no request repeated'
      task=$(jq -r --arg prefix "[Firstmate session marker: $IDA_STATE_MARKER]" '
        [.data.messages[]? | select(.type==0 and (.text|type)=="string")
          | select(.text==$prefix or (.text|startswith($prefix+"\n")))
          | .task_result.task_id? | select(.!=null) | tostring] | unique
        | if length==1 then .[0] else empty end' "$output")
      [ -n "$task" ] || die 'submission-unknown: official readback cannot uniquely correlate the followup marker to a turn; supply provider-supported identity evidence; no create repeated'
    fi
  else
    [ "$current_generation" = "$expected" ] || die 'terminal generation changed'
    case "$REMOTE_STATE_PHASE" in terminal-success|terminal-failure) ;; *) die 'followup requires the expected terminal execution; cancellation is not restart authority' ;; esac
    session=$IDA_STATE_SESSION_ID; parent_task=$IDA_STATE_TASK_ID
    [ -n "$session" ] && [ -n "$parent_task" ] || die 'original session/turn identity missing'
    # shellcheck source=bin/fm-task-disposition-lib.sh
    . "$SCRIPT_DIR/fm-task-disposition-lib.sh"
    fm_task_disposition_effect_guard "$DATA" "$id" 'remote followup' || exit $?
    fm_run_timed 30 "$SCRIPT_DIR/fm-bytedcli-mcp-call.sh" capabilities-followup > "$root/capabilities" 2> "$root/error" || die 'unsupported-continuation: official same-session create/list/get capability unavailable'
    fm_run_bash_timeout 30 fm_ida_run_bytedcli --json --as user ida --region sg deep-research list --session-id "$session" > "$root/baseline" 2> "$root/error" || die 'cannot establish original turn baseline'
    fm_ida_structured_success "$root/baseline" || die 'turn baseline unavailable'
    baseline=$(jq -ce '.data.tasks | select(type=="array") | map(.task_id | tostring) | unique' "$root/baseline") || die 'turn list schema unavailable'
    printf '%s' "$baseline" | jq -e --arg task "$parent_task" 'index($task)!=null' >/dev/null || die 'original turn absent from baseline'
    printf '%s\n%s' "$action" "$sha" > "$root/marker-input"
    marker=$(fm_ida_session_marker "$id" "$(fm_remote_sha256_file "$root/marker-input")") || exit 1
    old_report=$REMOTE_STATE_REPORT_PATH
    preserved_report=''
    if [ -n "$old_report" ]; then
      fm_remote_private_file_safe "$old_report" || die 'prior report cannot be preserved'
      preserved_report="$DATA/$id/turn-$expected-report.md"
      if [ -e "$preserved_report" ]; then
        if ! fm_remote_private_file_safe "$preserved_report" || ! cmp -s "$old_report" "$preserved_report"; then die 'prior report retention conflict'; fi
      else
        if ! cp "$old_report" "$root/report" || ! chmod 600 "$root/report" || ! mv "$root/report" "$preserved_report"; then die 'cannot retain prior report'; fi
      fi
    fi
    provider=$(jq -c --arg action "$action" --arg marker "$marker" --argjson parent "$expected" \
      --argjson baseline "$baseline" --arg report "$preserved_report" \
      '.provider_state + {parent_generation:$parent,parent_task_id:.provider_state.task_id,parent_report_ref:$report,
        followup_action_id:$action,session_marker:$marker,task_id:null,baseline_task_ids:$baseline,submit_attempted:true}' "$REMOTE_STATE_FILE")
    fm_remote_state_begin_followup "$id" "$expected" "$instructions" "$sha" "$provider" || die 'cannot checkpoint followup; no provider create issued'
    jq -n --rawfile content "$instructions" --arg name "$marker" --arg session "$session" \
      '{content:$content,name:$name,timeoutMs:"30000",sessionId:$session}' > "$root/arguments"
    chmod 600 "$root/arguments"
    fm_run_timed 35 "$SCRIPT_DIR/fm-bytedcli-mcp-call.sh" ida_deep_research_create "$root/arguments" > "$output" 2> "$root/error" || rc=$?
    if [ "$rc" = 0 ] && fm_ida_structured_success "$output" && \
        [ "$(jq -r '.data.session_id | tostring' "$output")" = "$session" ]; then
      task=$(jq -r '.data.task_id // empty | tostring' "$output")
    fi
    [ -n "$task" ] || die 'submission-unknown: followup may have been accepted; replay this action for readback only, never create again'
  fi
  fm_ida_numeric_id "$task" || die 'unverified followup task identity'
  fm_ida_state_load "$id" || exit 1
  jq -e --arg task "$task" '.provider_state.baseline_task_ids | index($task)==null' "$REMOTE_STATE_FILE" >/dev/null || die 'followup response reused a pre-existing turn'
  provider=$(jq -cn --arg task "$task" '{task_id:$task}')
  if [ "$IDA_STATE_TASK_ID" != "$task" ]; then
    fm_remote_state_transition "$id" submitted '' '' followup-identity-confirmed not-armed '' '' '' "$provider" || exit 1
  fi
  fm_lock_release "$lock"; fm_lock_release "$meta_lock"; fm_lease_guard_release
  case "$REMOTE_STATE_PHASE" in
    terminal-success|terminal-failure|terminal-cancelled) ;;
    *) "$SCRIPT_DIR/fm-procevent-ida.sh" arm "$id" >/dev/null || die 'turn identity retained; waiter arming pending, replay same action' ;;
  esac
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null || die 'turn identity retained; waiter startup pending, replay same action'
  printf 'followup recorded: %s action=%s; prior terminal and report retained\n' "$id" "$action"
)

cmd_adopt() (
  local id=${1-} lock root observation patch
  [ "$#" -eq 1 ] || usage
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  if [ ! -f "$STATE/$id.meta" ]; then fm_remote_meta_write "$id" ida "$REMOTE_STATE_TASK_TYPE" || die "cannot repair missing iDA metadata";
  else fm_remote_meta_validate "$id" ida "$REMOTE_STATE_TASK_TYPE" || die "iDA metadata does not match durable state"; fi
  case "$REMOTE_STATE_PHASE" in terminal-success|terminal-failure|terminal-cancelled) printf 'already-terminal: %s phase=%s\n' "$id" "$REMOTE_STATE_PHASE"; return ;; esac
  lock=$(fm_remote_task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"
  if [ "$REMOTE_STATE_PHASE" = ambiguous ]; then
    root=$(temp_root); observation="$root/observation.json"
    trap 'rm -rf -- "$root"' EXIT
    "$SCRIPT_DIR/fm-procevent-ida.sh" observe "$id" >"$observation" || { fm_lock_release "$lock"; die "iDA reconciliation failed"; }
    if jq -e '.ambiguous==false and .session_id != null' "$observation" >/dev/null 2>&1; then
      patch=$(jq -c '{session_id:.session_id,agent_id:.agent_id,agent_name:.agent_name,provider_status:.provider_status} | with_entries(select(.value != null))' "$observation")
      fm_remote_state_transition "$id" running "" "" identity-reconciled not-armed unavailable "" "" "$patch" || { fm_lock_release "$lock"; die "cannot checkpoint reconciled iDA identity"; }
      fm_remote_status_append "$id" "resolved [key=ida-submission-ambiguous]: unique iDA session identity reconciled" || true
    else
      fm_lock_release "$lock"
      die "iDA session identity remains ambiguous; no retry is safe"
    fi
    rm -rf -- "$root"; trap - EXIT
  fi
  fm_lock_release "$lock"
  "$SCRIPT_DIR/fm-procevent-ida.sh" arm "$id" >/dev/null || die "cannot re-arm iDA source"
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null || die "cannot start adopted iDA source"
  fm_ida_state_load "$id" || die "cannot reload adopted iDA state"
  printf 'adopted: %s session=%s marker=%s\n' "$id" "${IDA_STATE_SESSION_ID:-pending}" "$IDA_STATE_MARKER"
)

cmd_state() (
  local id=${1-} root observation state status kind availability class durable_only=0
  if [ "$#" -eq 2 ] && [ "$2" = --durable-only ]; then durable_only=1
  elif [ "$#" -ne 1 ]; then usage
  fi
  if ! fm_ida_state_load "$id"; then printf 'state: unknown · source: remote-state · provider=ida invalid-state\n'; return; fi
  if [ "$durable_only" -eq 1 ]; then
    state=$(fm_remote_phase_current_state "$REMOTE_STATE_PHASE")
    case "$REMOTE_STATE_PHASE" in
      submitted|running|result-unavailable)
        printf 'state: %s · source: remote-state · provider=ida phase=%s outcome=%s freshness=durable-local remote-readback=deferred\n' \
          "$state" "$REMOTE_STATE_PHASE" "${REMOTE_STATE_OUTCOME:-none}"
        ;;
      *)
        printf 'state: %s · source: remote-state · provider=ida phase=%s outcome=%s freshness=durable-local\n' \
          "$state" "$REMOTE_STATE_PHASE" "${REMOTE_STATE_OUTCOME:-none}"
        ;;
    esac
    return
  fi
  case "$REMOTE_STATE_PHASE" in
    terminal-success|terminal-failure|terminal-cancelled|submission-not-started|submission-unknown|ambiguous)
      state=$(fm_remote_phase_current_state "$REMOTE_STATE_PHASE")
      printf 'state: %s · source: remote-state · provider=ida phase=%s outcome=%s\n' "$state" "$REMOTE_STATE_PHASE" "${REMOTE_STATE_OUTCOME:-none}"; return ;;
  esac
  root=$(temp_root); observation="$root/observation.json"
  trap 'rm -rf -- "$root"' EXIT
  if ! "$SCRIPT_DIR/fm-procevent-ida.sh" observe "$id" >"$observation" 2>/dev/null \
      || ! fm_ida_observation_validate "$observation" "$id" "$IDA_STATE_MARKER"; then
    printf 'state: unknown · source: remote-readback · provider=ida phase=%s readback=unavailable\n' "$REMOTE_STATE_PHASE"; return
  fi
  status=$(jq -r '.provider_status // ""' "$observation"); kind=$(fm_ida_status_kind "$status")
  availability=$(jq -r '.result_availability' "$observation"); class=$(jq -r '.error_class // ""' "$observation")
  if jq -e '.ambiguous==true' "$observation" >/dev/null; then state=blocked
  elif jq -e '.terminal==false' "$observation" >/dev/null; then
    if fm_ida_local_read_error "$class"; then state=blocked
    else [ "$availability" = error ] && state=unknown || state=working; fi
  else case "$kind" in success) state='done' ;; *) state=failed ;; esac; fi
  printf 'state: %s · source: remote-readback · provider=ida phase=%s provider-status=%s terminal=%s result=%s error=%s\n' \
    "$state" "$REMOTE_STATE_PHASE" "${status:-unknown}" "$(jq -r '.terminal' "$observation")" "$availability" "${class:-none}"
)

emit_artifact_discovery_error() { # <task-id> <session-id> <remote-task-id> <class>
  local id=$1 session_id=$2 remote_task_id=$3 class=$4 revision
  revision=$(jq -r '.revision' "$REMOTE_STATE_FILE" 2>/dev/null || printf 'null')
  jq -n --arg id "$id" --arg session "$session_id" --arg remote_task "$remote_task_id" \
    --arg class "$class" --argjson revision "$revision" \
    '{schema:"fm-ida-artifact-discovery.v1",task_id:$id,provider:"ida",region:"sg",
      state_revision:$revision,session_id:$session,remote_task_id:$remote_task,
      availability:"error",provider_truncated:null,artifact_count:null,
      artifacts:[],error_class:$class}'
}

cmd_artifacts() (
  local id=${1-} root out err projected rc=0 class revision
  [ "$#" -eq 1 ] || usage
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  fm_ida_numeric_id "$IDA_STATE_SESSION_ID" || die "iDA artifact discovery requires a reconciled session id"
  fm_ida_numeric_id "$IDA_STATE_TASK_ID" || die "iDA artifact discovery requires a reconciled remote task id"
  if fm_ida_resolve_bytedcli >/dev/null 2>&1; then :; else
    rc=$?
    [ "$rc" -eq 126 ] && class=cli-not-executable || class=cli-not-found
    emit_artifact_discovery_error "$id" "$IDA_STATE_SESSION_ID" "$IDA_STATE_TASK_ID" "$class"
    return 1
  fi
  root=$(temp_root); out="$root/artifacts.out"; err="$root/artifacts.err"; projected="$root/projected.json"
  trap 'rm -rf -- "$root"' EXIT
  if fm_ida_run_bytedcli --json --as user ida --region sg deep-research artifact list \
      --session-id "$IDA_STATE_SESSION_ID" --task-id "$IDA_STATE_TASK_ID" >"$out" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  class=$(fm_ida_read_error_classify "$out" "$err" "$rc")
  if [ -n "$class" ]; then
    emit_artifact_discovery_error "$id" "$IDA_STATE_SESSION_ID" "$IDA_STATE_TASK_ID" "$class"
    return 1
  fi
  revision=$(jq -r '.revision' "$REMOTE_STATE_FILE")
  if ! jq -e --arg session "$IDA_STATE_SESSION_ID" --arg task "$IDA_STATE_TASK_ID" '
      (.data.session_id | tostring) == $session
      and (.data.task_id | tostring) == $task
      and (.data.artifacts | type == "array")
      and ((.data.truncated == null) or (.data.truncated | type == "boolean"))
      and ((.truncated == null) or (.truncated | type == "boolean"))
      and all(.data.artifacts[];
        type == "object"
        and ((.task_id // $task) | tostring) == $task
        and ((.files // []) | type == "array")
        and all((.files // [])[]; type == "object")
        and ((.tables // []) | type == "array")
        and (.text == null or (.text | type == "string")))
    ' "$out" >/dev/null 2>&1; then
    emit_artifact_discovery_error "$id" "$IDA_STATE_SESSION_ID" "$IDA_STATE_TASK_ID" response-invalid-structure
    return 1
  fi
  if ! jq --arg id "$id" --arg session "$IDA_STATE_SESSION_ID" --arg task "$IDA_STATE_TASK_ID" \
      --argjson revision "$revision" '
      def nullable_scalar: if . == null or (type == "string") or (type == "number") or (type == "boolean") then . else null end;
      (.data.truncated // .truncated // false) as $provider_truncated
      | (.data.artifacts | map({
          task_id: ((.task_id // $task) | tostring),
          artifact_id: ((.artifact_id // null) | nullable_scalar),
          name: ((.name // null) | nullable_scalar),
          content_type: ((.content_type // .type // null) | nullable_scalar),
          table_count: (if (.tables // null) | type == "array" then (.tables | length) else (.table_count // 0) end),
          has_text: (if (.text // null) | type == "string" then (.text | length > 0) else (.has_text // false) end),
          files: ((.files // []) | map({
            file_name: ((.name // .file_name // null) | nullable_scalar),
            mime_type: ((.mime_type // null) | nullable_scalar),
            uri: ((.uri // .file_uri // null) | nullable_scalar),
            size: ((.size // null) | nullable_scalar)
          }))
        })) as $artifacts
      | {schema:"fm-ida-artifact-discovery.v1",task_id:$id,provider:"ida",region:"sg",
          state_revision:$revision,session_id:$session,remote_task_id:$task,
          availability:(if $provider_truncated then "partial" elif ($artifacts|length)>0 then "available" else "empty" end),
          provider_truncated:$provider_truncated,artifact_count:($artifacts|length),
          artifacts:$artifacts,error_class:null}
    ' "$out" >"$projected"; then
    emit_artifact_discovery_error "$id" "$IDA_STATE_SESSION_ID" "$IDA_STATE_TASK_ID" response-invalid-structure
    return 1
  fi
  cat "$projected"
)

cmd_interrupt_wait() {
  local id=${1-} source lock session_id
  [ "$#" -eq 1 ] || usage
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  session_id=$IDA_STATE_SESSION_ID
  source=$(fm_remote_source_id ida "$id") || die "invalid task id"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$source" >/dev/null || die "cannot stop local iDA waiter"
  lock=$(fm_remote_task_lock_path "$id")
  ( fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"; trap 'fm_lock_release "$lock"' EXIT; fm_ida_state_load "$id" || die "iDA state invalid"; fm_remote_state_transition "$id" "$REMOTE_STATE_PHASE" "$REMOTE_STATE_OUTCOME" "$REMOTE_STATE_ERROR_CLASS" waiter-interrupted interrupted "$REMOTE_STATE_RESULT_AVAILABILITY" "" "" '{}' || die "cannot checkpoint waiter interrupt" )
  printf 'waiter-interrupted: %s; iDA session %s may still be running\n' "$id" "${session_id:-unknown}"
}

cmd_cancel() (
  local id=${1-} authorization=${2-} root out err artifact observation source lock class
  [ "$#" -eq 2 ] && [ "$authorization" = --authorize-provider-cancel ] || die "iDA cancellation requires --authorize-provider-cancel"
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  [ -n "$IDA_STATE_SESSION_ID" ] || die "iDA cancellation requires a reconciled session id"
  case "$REMOTE_STATE_PHASE" in terminal-success|terminal-failure|terminal-cancelled) die "iDA task is already terminal" ;; esac
  root=$(temp_root); out="$root/cancel.out"; err="$root/cancel.err"
  trap 'rm -rf -- "$root"' EXIT
  if ! fm_ida_run_bytedcli --json --as user ida --region sg chat completion close --session-id "$IDA_STATE_SESSION_ID" >"$out" 2>"$err" \
      || ! fm_ida_structured_success "$out"; then
    fm_ida_normalize_error "$out" "$err" "$root/error.json"; class=$(fm_remote_error_classify "$root/error.json")
    rm -rf -- "$root"; die "iDA cancellation was not confirmed: $class"
  fi
  jq '{status:"success",data:{result:(.data.result // null)},error:null}' "$out" >"$root/normalized.json"
  artifact=$(fm_remote_artifact_store "$id" cancel "$root/normalized.json") || die "cannot checkpoint iDA cancellation response"
  lock=$(fm_remote_task_lock_path "$id")
  ( fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"; trap 'fm_lock_release "$lock"' EXIT; fm_ida_state_load "$id"; fm_remote_state_transition "$id" running cancellation-requested "" cancellation-request-accepted not-armed unavailable "$artifact" "" '{}' ) || die "cannot checkpoint iDA cancellation request"
  observation="$root/observation.json"
  "$SCRIPT_DIR/fm-procevent-ida.sh" observe "$id" >"$observation" || die "cannot read back iDA cancellation"
  if jq -e '.terminal==true and (.error_class=="provider-cancelled" or (.provider_status|ascii_downcase|test("cancel|closed|stopped|shutdown")))' "$observation" >/dev/null; then
    source=$(fm_remote_source_id ida "$id")
    "$SCRIPT_DIR/fm-procevent.sh" retire "$source" >/dev/null || die "cannot replace the pre-cancellation iDA waiter"
    "$SCRIPT_DIR/fm-procevent.sh" register ida "$source" -- "$SCRIPT_DIR/fm-procevent-ida.sh" observe "$id" >/dev/null
    "$SCRIPT_DIR/fm-procevent.sh" start "$source" >/dev/null || die "cannot apply terminal cancellation observation"
    printf 'cancelled: %s session=%s\n' "$id" "$IDA_STATE_SESSION_ID"
  else
    "$SCRIPT_DIR/fm-procevent-ida.sh" arm "$id" >/dev/null || die "cannot monitor requested iDA cancellation"
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null || die "cannot start iDA cancellation monitor"
    printf 'cancellation-requested: %s session=%s; awaiting authoritative provider terminal\n' "$id" "$IDA_STATE_SESSION_ID"
  fi
  rm -rf -- "$root"; trap - EXIT
)

write_abandon_report() { # <id>
  local id=$1 report
  report=$(fm_remote_report_path "$id") || return 1
  fm_remote_report_replaceable "$id" || return 1
  # shellcheck disable=SC2016 # Backticks are literal Markdown.
  {
    printf '# iDA remote-agent report\n\n'
    printf -- '- Task: `%s`\n- Executor: `remote-agent`\n- Provider: `ida`\n- Region: `sg`\n' "$id"
    printf -- '- Session marker: `%s`\n- Session: `unavailable`\n- Remote task: `unavailable`\n' "$IDA_STATE_MARKER"
    printf -- '- Agent: `%s`\n- Model: `%s`\n' \
      "${IDA_STATE_AGENT_NAME:-${IDA_STATE_AGENT_ID:-unavailable}}" \
      "${IDA_STATE_MODEL:-unavailable}"
    [ -z "$REMOTE_STATE_BYTEDCLI_VERSION" ] || printf -- '- Legacy bytedcli version: `%s` (informational)\n' "$REMOTE_STATE_BYTEDCLI_VERSION"
    printf -- '- Outcome: `failed`\n- Result availability: `unavailable`\n- Error class: `session-marker-not-found`\n'
    printf '\n## Provider Result\n\n'
    printf '%s\n' 'This task was abandoned after an authoritative complete non-truncated zero-match session list proved no provider session exists.'
    printf '%s\n' 'No final provider answer is available for this terminal outcome.'
    printf '\n## Evidence Boundary\n\n'
    printf '%s\n' '- This report contains only normalized iDA identity, terminal state, and abandonment fields.'
    printf '%s\n' '- Private prompts, credentials, tokens, PII-bearing payloads, and raw event streams are not preserved.'
    printf '%s\n' '- Provider output grants no implementation, publication, merge, destructive, legal, or security authority.'
    printf '%s\n' '- Abandonment performed no provider write and authorizes no retry or recreation; re-execution requires a separate explicit dispatch.'
  } >"$report" || return 1
  chmod 0600 "$report" || return 1
  printf '%s\n' "$report"
}

cmd_abandon() (
  local id=${1-} authorization=${2-} root observation report lock
  [ "$#" -eq 2 ] && [ "$authorization" = --authorize-abandon ] || die "iDA abandonment requires --authorize-abandon"
  lock=$(fm_remote_task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"
  trap 'fm_lock_release "$lock"' EXIT
  fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
  case "$REMOTE_STATE_PHASE" in
    ambiguous|submission-unknown) ;;
    terminal-success|terminal-failure|terminal-cancelled) die "iDA task is already terminal: phase=$REMOTE_STATE_PHASE" ;;
    *) die "iDA abandonment applies only to ambiguous or submission-unknown tasks: phase=$REMOTE_STATE_PHASE" ;;
  esac
  root=$(temp_root); observation="$root/observation.json"
  if ! "$SCRIPT_DIR/fm-procevent-ida.sh" observe "$id" >"$observation" 2>/dev/null \
      || ! fm_ida_observation_validate "$observation" "$id" "$IDA_STATE_MARKER" \
      || ! jq -e '.ambiguous == true and .error_class == "session-marker-not-found"' "$observation" >/dev/null 2>&1; then
    die "iDA abandonment requires an authoritative complete non-truncated zero-match session list"
  fi
  report=$(write_abandon_report "$id") || die "cannot write iDA abandonment report"
  fm_remote_state_transition "$id" terminal-failure failed session-marker-not-found abandon-confirmed terminal unavailable "" "$report" '{}' \
    || die "cannot checkpoint abandoned iDA state"
  fm_remote_status_append "$id" "failed: iDA remote research abandoned after an authoritative zero-match session list; re-execution requires a separate explicit dispatch" \
    || die "cannot append iDA abandonment status"
  rm -rf -- "$root"
  fm_lock_release "$lock"; trap - EXIT
  "$SCRIPT_DIR/fm-procevent.sh" retire "$(fm_remote_source_id ida "$id")" >/dev/null || die "cannot retire abandoned iDA process-event source"
  printf 'abandoned: %s marker=%s\n' "$id" "$IDA_STATE_MARKER"
)

cmd_retire() {
  local id=${1-} report source lock meta_lock generation
  [ "$#" -eq 1 ] || usage
  lock=$(fm_remote_task_lock_path "$id")
  (
    # Same order as continuation: lease, metadata, provider state.
    # shellcheck source=bin/fm-lease-lib.sh
    . "$SCRIPT_DIR/fm-lease-lib.sh"
    fm_lease_guard "$id" 'iDA retirement' || exit $?
    meta_lock=$(fm_meta_lock_path "$STATE/$id.meta") || die "cannot resolve task meta lock"
    trap 'fm_lock_release "$meta_lock"; fm_lock_release "$lock"; fm_lease_guard_release' EXIT
    fm_lock_acquire_wait "$meta_lock" || die "cannot lock task metadata"
    fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"
    fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
    generation=$(jq -r '.generation // 1' "$REMOTE_STATE_FILE")
    # shellcheck source=bin/fm-cleanup-receipt-lib.sh
    . "$SCRIPT_DIR/fm-cleanup-receipt-lib.sh"
    fm_cleanup_completion_guard "$id" "remote-$generation" \
      || die 'iDA goal is unfinished; MAIN must accept or explicitly archive it before retirement'
    case "$REMOTE_STATE_PHASE" in terminal-success|terminal-failure|terminal-cancelled) ;; *) die "iDA task is not safely terminal: phase=$REMOTE_STATE_PHASE" ;; esac
    report=$(fm_remote_report_path "$id") || die "cannot resolve report path"
    fm_remote_report_safe "$id" && [ "$REMOTE_STATE_REPORT_PATH" = "$report" ] || die "iDA task has no safe report at data/$id/report.md"
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" verify "$id" >/dev/null || die "iDA task decision completion gate has not passed"
    # shellcheck source=bin/fm-remote-execution-receipt-lib.sh
    . "$SCRIPT_DIR/fm-remote-execution-receipt-lib.sh"
    fm_remote_execution_receipt_record "$DATA" "$id" remote-agent ida "remote-$generation" \
      || die "cannot retain immutable iDA execution identity"
    source=$(fm_remote_source_id ida "$id")
    "$SCRIPT_DIR/fm-procevent.sh" retire "$source" >/dev/null || die "cannot retire iDA process-event source"
    fm_backlog_remote_retire "$CONFIG" "$DATA" "$id" \
      || die "remote retirement backlog transition failed; execution evidence retained: $FM_BACKLOG_TRANSITION_ERROR"
    rm -f -- "$STATE/$id.meta" "$STATE/$id.status" "$STATE/$id.turn-ended" "$STATE/.$id.open-decisions-cursor"
    rm -rf -- "$(fm_remote_task_dir "$id")"
    printf 'retired: %s report=data/%s/report.md\n' "$id" "$id"
  )
}

case "${1-}" in
  followup) shift; cmd_followup "$@" ;;
  probe) shift; cmd_probe "$@" ;;
  dispatch) shift; cmd_dispatch "$@" ;;
  adopt) shift; cmd_adopt "$@" ;;
  state) shift; cmd_state "$@" ;;
  artifacts) shift; cmd_artifacts "$@" ;;
  interrupt-wait) shift; cmd_interrupt_wait "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  abandon) shift; cmd_abandon "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  -h|--help|'') usage ;;
  *) usage ;;
esac
