#!/usr/bin/env bash
# Firstmate-owned native iDA remote-agent executor.
#
# Usage:
#   fm-remote-agent-ida.sh probe
#   fm-remote-agent-ida.sh dispatch <task-id> --instructions <private-file> [--document]
#   fm-remote-agent-ida.sh adopt <task-id>
#   fm-remote-agent-ida.sh state <task-id>
#   fm-remote-agent-ida.sh interrupt-wait <task-id>
#   fm-remote-agent-ida.sh cancel <task-id> --authorize-provider-cancel
#   fm-remote-agent-ida.sh abandon <task-id> --authorize-abandon
#   fm-remote-agent-ida.sh retire <task-id>
#
# New dispatches require config/ida-remote-agent, whose schema is owned by
# fm-ida-remote-lib.sh, and always use region=sg. `dispatch` durably records the
# task/provider identity and session marker, then arms the process-event adapter;
# it does not block on Deep Research. The adapter reconciles that unique marker
# before the sole allowed create and after every ambiguous submission.
#
# `cancel` is a destructive provider write and therefore requires the explicit
# --authorize-provider-cancel flag at the call site. A successful close response
# is not treated as terminal cancellation until authoritative session readback
# confirms it. `interrupt-wait` stops only Firstmate's local waiter.
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

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

temp_root() {
  local root
  root=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-ida-command.XXXXXX") || die "cannot create private iDA temporary storage"
  printf '%s\n' "$root"
}

cmd_probe() {
  local root out err capability rc=0 agent_id args=(agent get)
  [ "$#" -eq 0 ] || usage
  fm_ida_config_load || die "iDA remote-agent config is missing or invalid"
  command -v bytedcli >/dev/null 2>&1 || die "bytedcli is unavailable"
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
  jq -n --arg agent "$agent_id" --arg model "$IDA_CONFIG_MODEL" \
    '{schema:"fm-ida-probe.v1",outcome:"ready",error_class:null,provider:"ida",region:"sg",identity:"user",agent_id:$agent,model:$model,capabilities:["deep-research.create","session.list","session.get","chat.completion.close"]}'
  rm -rf -- "$root"
}

cmd_dispatch() {
  local id=${1-} instructions='' task_type=research sha marker provider_state lock rc agent_id model
  [ -n "$id" ] || usage; shift
  fm_remote_task_id_valid "$id" || die "invalid task id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instructions) [ "$#" -ge 2 ] || usage; instructions=$2; shift 2 ;;
      --document) task_type=document; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$instructions" ] || die "dispatch requires --instructions <private-file>"
  [ -f "$DATA/$id/brief.md" ] && [ ! -L "$DATA/$id/brief.md" ] || die "ordinary Firstmate brief is missing or unsafe: data/$id/brief.md"
  fm_remote_instruction_validate "$id" "$instructions" || exit 1
  fm_ida_config_load || die "iDA remote agent is disabled: config is missing or invalid"
  [ "$IDA_CONFIG_ENABLED" = true ] || die "iDA remote agent is disabled in config"
  command -v bytedcli >/dev/null 2>&1 || die "bytedcli is unavailable"
  sha=$(fm_remote_sha256_file "$instructions") || die "cannot hash iDA instruction"
  marker=$(fm_ida_session_marker "$id" "$sha") || die "cannot derive iDA session marker"
  [ "$IDA_CONFIG_AGENT_ID" = default ] && agent_id= || agent_id=$IDA_CONFIG_AGENT_ID
  [ "$IDA_CONFIG_MODEL" = default ] && model= || model=$IDA_CONFIG_MODEL
  provider_state=$(jq -cn --arg marker "$marker" --arg agent_id "$agent_id" --arg model "$model" \
    '{region:"sg",identity:"user",session_marker:$marker,session_id:null,task_id:null,
      agent_id:(if $agent_id=="" then null else $agent_id end),agent_name:null,
      model:(if $model=="" then null else $model end),provider_status:null}')
  lock=$(fm_remote_task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"
  trap 'fm_lock_release "$lock"' EXIT
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
  local id=${1-} root observation state status kind availability class
  [ "$#" -eq 1 ] || usage
  if ! fm_ida_state_load "$id"; then printf 'state: unknown · source: remote-state · provider=ida invalid-state\n'; return; fi
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
  elif jq -e '.terminal==false' "$observation" >/dev/null; then [ "$availability" = error ] && state=unknown || state=working
  else case "$kind" in success) state='done' ;; *) state=failed ;; esac; fi
  printf 'state: %s · source: remote-readback · provider=ida phase=%s provider-status=%s terminal=%s result=%s error=%s\n' \
    "$state" "$REMOTE_STATE_PHASE" "${status:-unknown}" "$(jq -r '.terminal' "$observation")" "$availability" "${class:-none}"
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
  local id=${1-} report source lock
  [ "$#" -eq 1 ] || usage
  lock=$(fm_remote_task_lock_path "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock iDA task"
    trap 'fm_lock_release "$lock"' EXIT
    fm_ida_state_load "$id" || die "iDA task state is missing or invalid"
    case "$REMOTE_STATE_PHASE" in terminal-success|terminal-failure|terminal-cancelled) ;; *) die "iDA task is not safely terminal: phase=$REMOTE_STATE_PHASE" ;; esac
    report=$(fm_remote_report_path "$id") || die "cannot resolve report path"
    fm_remote_report_safe "$id" && [ "$REMOTE_STATE_REPORT_PATH" = "$report" ] || die "iDA task has no safe report at data/$id/report.md"
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-decision-hold.sh" verify "$id" >/dev/null || die "iDA task decision completion gate has not passed"
    source=$(fm_remote_source_id ida "$id")
    "$SCRIPT_DIR/fm-procevent.sh" retire "$source" >/dev/null || die "cannot retire iDA process-event source"
    rm -f -- "$STATE/$id.meta" "$STATE/$id.status" "$STATE/$id.turn-ended" "$STATE/.$id.open-decisions-cursor"
    rm -rf -- "$(fm_remote_task_dir "$id")"
    printf 'retired: %s report=data/%s/report.md\n' "$id" "$id"
  )
}

case "${1-}" in
  probe) shift; cmd_probe "$@" ;;
  dispatch) shift; cmd_dispatch "$@" ;;
  adopt) shift; cmd_adopt "$@" ;;
  state) shift; cmd_state "$@" ;;
  interrupt-wait) shift; cmd_interrupt_wait "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  abandon) shift; cmd_abandon "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  -h|--help|'') usage ;;
  *) usage ;;
esac
