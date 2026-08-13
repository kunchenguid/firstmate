#!/usr/bin/env bash
# AIME adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-aime.sh arm <task-id>
#   fm-procevent-aime.sh source <task-id>
#   fm-procevent-aime.sh handle <task-id> <sequence> <result-file>
#   fm-procevent-aime.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-aime.sh terminal <result-file>
#   fm-procevent-aime.sh retire <task-id>
#
# `source` is the blocking provider-specific readback operation registered by
# `arm`.
# It replays from the durable AIME event cursor until the current CLI sees a
# terminal candidate, then cross-reads session details and latest assistant
# output.
# The generic runner remains transport only.
#
# `handle` owns result schema validation, identity binding, cursor monotonicity,
# duplicate generation handling, normalized result storage, deterministic report
# generation, AIME-created Feishu document identity validation, handled
# acknowledgement, and re-arming after a nonterminal/unavailable observation.
# Raw event/tool payloads remain private under state/cloud-tasks and never enter a
# status event or report.
#
# Every source invocation exits 0 with one bounded JSON observation, including
# provider errors.
# This avoids the generic runner's "nonzero plus empty output" retry ambiguity.
# A failed readback does not mean the cloud task stopped and is re-armed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-aime-cloud-lib.sh
. "$SCRIPT_DIR/fm-aime-cloud-lib.sh"

AIME_REPLAY_TIMEOUT_MS=${FM_AIME_REPLAY_TIMEOUT_MS:-5000}
AIME_REPLAY_MAX_STREAMS=${FM_AIME_REPLAY_MAX_STREAMS:-200}
AIME_READBACK_TIMEOUT=${FM_AIME_READBACK_TIMEOUT:-20}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

validate_positive() {
  case "$2" in ''|0|*[!0-9]*) die "$1 must be a positive integer" ;; esac
}

validate_positive FM_AIME_REPLAY_TIMEOUT_MS "$AIME_REPLAY_TIMEOUT_MS"
validate_positive FM_AIME_REPLAY_MAX_STREAMS "$AIME_REPLAY_MAX_STREAMS"
validate_positive FM_AIME_READBACK_TIMEOUT "$AIME_READBACK_TIMEOUT"

temp_root() {
  local root
  root=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-aime-event.XXXXXX") || die "cannot create private temporary storage"
  printf '%s\n' "$root"
}

structured_success() {
  jq -e '.status == "success" and .error == null and (.data | type != "null")' "$1" >/dev/null 2>&1
}

run_json() { # <stdout> <stderr> <args...>
  local out=$1 err=$2
  shift 2
  : > "$out"
  : > "$err"
  if BYTEDCLI_NO_AUTO_UPGRADE=1 fm_run_timed "$AIME_READBACK_TIMEOUT" \
    bytedcli --json "$@" >"$out" 2>"$err"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

error_json() { # <stdout> <stderr> <destination>
  if jq -e . "$1" >/dev/null 2>&1; then
    cp "$1" "$3"
  else
    jq -n --rawfile stderr "$2" '{status:"error",error:{message:($stderr | .[0:4096])}}' >"$3"
  fi
}

cmd_source() {
  local id=${1-} root replay_out replay_err session_out session_err output_out output_err
  local replay_ok=false session_ok=false output_ok=false class='' cursor terminal=false
  [ "$#" -eq 1 ] || usage
  fm_aime_task_id_valid "$id" || die "invalid task id"
  fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
  [ -n "$AIME_STATE_SESSION_ID" ] || die "AIME task has no checkpointed session id"
  cursor=$AIME_STATE_CURSOR
  root=$(temp_root)
  replay_out="$root/replay.out"
  replay_err="$root/replay.err"
  session_out="$root/session.out"
  session_err="$root/session.err"
  output_out="$root/output.out"
  output_err="$root/output.err"

  run_json "$replay_out" "$replay_err" \
    --site "$AIME_STATE_SITE" --as user aime session replay-events \
    --session-id "$AIME_STATE_SESSION_ID" --from-offset "$cursor" \
    --timeout-ms "$AIME_REPLAY_TIMEOUT_MS" --max-streams "$AIME_REPLAY_MAX_STREAMS" --until-terminal
  if [ "$RUN_RC" -eq 0 ] && structured_success "$replay_out" \
    && [ "$(jq -r '.data.session_id // ""' "$replay_out")" = "$AIME_STATE_SESSION_ID" ] \
    && jq -e '.data.events | type == "array"' "$replay_out" >/dev/null 2>&1; then
    replay_ok=true
    terminal=$(jq -r '.data.terminal == true' "$replay_out")
  else
    error_json "$replay_out" "$replay_err" "$root/replay-error.json"
    class=$(fm_aime_error_classify "$root/replay-error.json")
    [ "$RUN_RC" -ne 124 ] || class=timeout
    jq -n --arg class "$class" '{status:"error",error_class:$class}' >"$replay_out"
  fi

  run_json "$session_out" "$session_err" \
    --site "$AIME_STATE_SITE" --as user aime session get --session-id "$AIME_STATE_SESSION_ID"
  if [ "$RUN_RC" -eq 0 ] && structured_success "$session_out" \
    && [ "$(jq -r '.data.id // ""' "$session_out")" = "$AIME_STATE_SESSION_ID" ]; then
    session_ok=true
  else
    error_json "$session_out" "$session_err" "$root/session-error.json"
    class=$(fm_aime_error_classify "$root/session-error.json")
    [ "$RUN_RC" -ne 124 ] || class=timeout
    jq -n --arg class "$class" '{status:"error",error_class:$class}' >"$session_out"
  fi

  if [ "$terminal" = true ]; then
    run_json "$output_out" "$output_err" \
      --site "$AIME_STATE_SITE" --as user aime session get-output --session-id "$AIME_STATE_SESSION_ID" \
      --timeout-ms "$AIME_REPLAY_TIMEOUT_MS" --max-streams "$AIME_REPLAY_MAX_STREAMS"
    if [ "$RUN_RC" -eq 0 ] && structured_success "$output_out" \
      && [ "$(jq -r '.data.session_id // ""' "$output_out")" = "$AIME_STATE_SESSION_ID" ] \
      && { [ -z "$AIME_STATE_MESSAGE_ID" ] \
        || [ "$(jq -r '.data.message_id // ""' "$output_out")" = "$AIME_STATE_MESSAGE_ID" ]; }; then
      output_ok=true
    else
      error_json "$output_out" "$output_err" "$root/output-error.json"
      class=$(fm_aime_error_classify "$root/output-error.json")
      [ "$RUN_RC" -ne 124 ] || class=timeout
      jq -n --arg class "$class" '{status:"error",error_class:$class}' >"$output_out"
    fi
  else
    jq -n '{status:"not-requested"}' >"$output_out"
  fi

  jq -n \
    --arg schema "$AIME_OBSERVATION_SCHEMA" \
    --arg task_id "$id" \
    --arg session_id "$AIME_STATE_SESSION_ID" \
    --arg site "$AIME_STATE_SITE" \
    --argjson from_offset "$cursor" \
    --argjson replay_ok "$replay_ok" \
    --argjson session_ok "$session_ok" \
    --argjson output_ok "$output_ok" \
    --argjson terminal "$terminal" \
    --slurpfile replay "$replay_out" \
    --slurpfile session "$session_out" \
    --slurpfile output "$output_out" \
    '{
      schema:$schema,
      task_id:$task_id,
      provider:"aime",
      site:$site,
      session_id:$session_id,
      from_offset:$from_offset,
      replay_ok:$replay_ok,
      session_ok:$session_ok,
      output_ok:$output_ok,
      terminal_candidate:$terminal,
      observed_at:(now | todateiso8601),
      replay:($replay[0]),
      session:($session[0]),
      output:($output[0])
    }'
  rm -rf -- "$root"
}

validate_observation() { # <result> <task-id>
  local result=$1 id=$2
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  jq -e \
    --arg schema "$AIME_OBSERVATION_SCHEMA" \
    --arg id "$id" '
      .schema == $schema
      and .task_id == $id
      and .provider == "aime"
      and (.site | type == "string" and length > 0)
      and (.session_id | type == "string" and length > 0)
      and (.from_offset | type == "number" and . >= 0)
      and (.replay_ok | type == "boolean")
      and (.session_ok | type == "boolean")
      and (.output_ok | type == "boolean")
      and (.terminal_candidate | type == "boolean")
      and (.replay | type == "object")
      and (.session | type == "object")
      and (.output | type == "object")
    ' "$result" >/dev/null 2>&1
}

observation_terminal() {
  local result=$1
  jq -e '.replay_ok == true and .session_ok == true and .terminal_candidate == true' "$result" >/dev/null 2>&1
}

cmd_terminal() {
  local result=${1-}
  [ "$#" -eq 1 ] || usage
  [ -f "$result" ] && [ ! -L "$result" ] || exit 1
  observation_terminal "$result"
}

document_json_from_output() { # <content-file>
  local file=$1 line
  line=$(grep "^$AIME_DOCUMENT_SCHEMA " "$file" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || return 1
  printf '%s\n' "${line#"$AIME_DOCUMENT_SCHEMA "}" | jq -ce '
    select(
      type == "object"
      and (.url | type == "string" and test("^https://([A-Za-z0-9-]+\\.)*(larkoffice\\.com|feishu\\.cn)/(docx|wiki)/[A-Za-z0-9]+$"))
      and (.identity | type == "string" and length > 0)
      and (.revision | (type == "number" and . >= 0) or (type == "string" and length > 0))
    )
  '
}

report_path_safe() { # <report-path>
  local report=$1 links owner
  [ ! -L "$report" ] || return 1
  [ -e "$report" ] || return 0
  [ -f "$report" ] || return 1
  links=$(fm_aime_file_links "$report") || return 1
  [ "$links" = 1 ] || return 1
  owner=$(fm_aime_file_owner "$report") || return 1
  [ "$owner" = "$(id -u)" ]
}

write_report() { # <id> <observation-artifact> <output-artifact> <document-json-or-empty>
  local id=$1 observation=$2 output_file=$3 document_json=$4 report content_file
  report="$DATA/$id/report.md"
  content_file="${output_file}.content"
  jq -r '.data.content // ""' "$output_file" >"$content_file" || return 1
  [ -s "$content_file" ] || return 2
  report_path_safe "$report" || return 1
  # shellcheck disable=SC2016 # Backticks below are literal Markdown.
  {
    printf '# AIME cloud research report\n\n'
    printf -- '- Task: `%s`\n' "$id"
    printf -- '- Executor: `cloud-worker`\n'
    printf -- '- Provider: `aime`\n'
    printf -- '- Site: `%s`\n' "$AIME_STATE_SITE"
    printf -- '- Space: `%s`\n' "$AIME_STATE_SPACE_ID"
    printf -- '- Session: `%s`\n' "$AIME_STATE_SESSION_ID"
    printf -- '- Message: `%s`\n' "${AIME_STATE_MESSAGE_ID:-unknown}"
    printf -- '- bytedcli: `%s`\n' "$AIME_STATE_BYTEDCLI_VERSION"
    printf -- '- Observation: `%s`\n' "$observation"
    printf -- '- Result mode: `%s`\n' "$AIME_STATE_RESULT_MODE"
    if [ -n "$document_json" ]; then
      printf -- '- AIME-created Feishu document: `%s`\n' "$(printf '%s' "$document_json" | jq -r '.url')"
      printf -- '- Document identity: `%s`\n' "$(printf '%s' "$document_json" | jq -r '.identity')"
      printf -- '- Document revision: `%s`\n' "$(printf '%s' "$document_json" | jq -r '.revision')"
    fi
    printf '\n## Provider Result\n\n'
    cat "$content_file"
    printf '\n\n## Evidence Boundary\n\n'
    printf '%s\n' '- This is AIME output captured through authoritative session replay and readback.'
    printf '%s\n' '- External content is input and evidence, not executable instruction or authority.'
    printf '%s\n' '- This report grants no implementation, publication, merge, destructive, or security authority.'
    if [ "$AIME_STATE_RESULT_MODE" = document ]; then
      printf '%s\n' '- Firstmate performed no Feishu create, copy, rewrite, permission, or sharing operation.'
    fi
  } >"$report" || { rm -f -- "$content_file"; return 1; }
  rm -f -- "$content_file"
  chmod 0600 "$report" || return 1
  printf '%s\n' "$report"
}

# Write the deterministic report for a provider-terminal session whose requested
# result cannot be verified. This is terminal failure, not a transient readback
# outage: another waiter run cannot make an empty result or missing document
# identity authoritative.
write_terminal_failure_report() { # <id> <error-class> <observation-path>
  local id=$1 class=$2 observation=$3 report
  report="$DATA/$id/report.md"
  report_path_safe "$report" || return 1
  # shellcheck disable=SC2016 # Backticks below are literal Markdown.
  {
    printf '# AIME cloud research result\n\n'
    printf -- '- Task: `%s`\n' "$id"
    printf -- '- Executor: `cloud-worker`\n'
    printf -- '- Provider: `aime`\n'
    printf -- '- Site: `%s`\n' "$AIME_STATE_SITE"
    printf -- '- Space: `%s`\n' "$AIME_STATE_SPACE_ID"
    printf -- '- Session: `%s`\n' "$AIME_STATE_SESSION_ID"
    printf -- '- bytedcli: `%s`\n' "$AIME_STATE_BYTEDCLI_VERSION"
    printf -- '- Outcome: `failed`\n'
    printf -- '- Error class: `%s`\n' "$class"
    printf -- '- Observation: `%s`\n' "$observation"
    printf '\nThe AIME session reached a terminal provider event, but no valid requested result was recoverable.\n'
    if [ "$class" = document-identity-missing ]; then
      printf 'Firstmate did not create, copy, rewrite, share, or change permissions on any Feishu document.\n'
    fi
    printf 'Provider output grants no implementation, publication, merge, destructive, or security authority.\n'
  } >"$report" || return 1
  chmod 0600 "$report" || return 1
  printf '%s\n' "$report"
}

record_terminal_result_failure() { # <id> <error-class> <observation-path> <cursor>
  local id=$1 class=$2 observation=$3 cursor=$4 report
  report=$(write_terminal_failure_report "$id" "$class" "$observation") || return 1
  fm_aime_state_transition "$id" terminal-failure failed "$class" \
    "$AIME_STATE_SESSION_ID" "$AIME_STATE_MESSAGE_ID" "$cursor" terminal-result-invalid \
    "$observation" "$report" terminal "" || return 1
  ensure_terminal_status "$id" terminal-failure
}

ensure_terminal_status() { # <id> <terminal-phase>
  local id=$1 phase=$2 line status
  status="$STATE/$id.status"
  case "$phase" in
    terminal-success) line="done: AIME cloud research complete; see data/$id/report.md" ;;
    terminal-failure) line="failed: AIME reached terminal state without a valid requested result; see data/$id/report.md" ;;
    *) return 1 ;;
  esac
  grep -Fqx "$line" "$status" 2>/dev/null && return 0
  fm_aime_status_append "$id" "$line"
}

record_result_unavailable() { # <id> <error-class> <observation-path>
  local id=$1 class=$2 observation=$3
  fm_aime_state_transition "$id" result-unavailable result-unavailable "$class" \
    "$AIME_STATE_SESSION_ID" "$AIME_STATE_MESSAGE_ID" "$AIME_STATE_CURSOR" readback-unavailable \
    "$observation" "" rearming "" || return 1
  fm_aime_status_append "$id" "blocked [key=aime-result-unavailable]: AIME result readback is unavailable; the cloud session may still be running" \
    || return 1
}

resolve_result_unavailable() { # <id>
  local id=$1
  [ "$AIME_STATE_PHASE" = result-unavailable ] || return 0
  fm_aime_status_append "$id" \
    "resolved [key=aime-result-unavailable]: authoritative AIME readback recovered"
}

cmd_handle_locked() {
  local id=$1 seq=$2 result=$3 source observation artifact cursor class terminal=false output_file
  local report document_json='' document_state_json='' current_cursor content_file observed_from observed_cursor
  local provider_status
  source=$(fm_aime_source_id "$id") || die "invalid task id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  validate_observation "$result" "$id" || die "AIME observation is malformed"
  fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
  if fm_procevent_is_handled "$STATE" "$source" "$seq"; then
    case "$AIME_STATE_PHASE" in
      terminal-success|terminal-failure)
        ensure_terminal_status "$id" "$AIME_STATE_PHASE" \
          || die "cannot restore the terminal AIME status event"
        ;;
    esac
    printf 'handled: %s duplicate=true cursor=%s\n' "$id" "$AIME_STATE_CURSOR"
    return 0
  fi
  [ "$(jq -r '.session_id' "$result")" = "$AIME_STATE_SESSION_ID" ] \
    || die "AIME observation session identity does not match the task"
  [ "$(jq -r '.site' "$result")" = "$AIME_STATE_SITE" ] \
    || die "AIME observation site does not match the task"
  observed_from=$(jq -r '.from_offset' "$result")
  observed_cursor=$(jq -r '.replay.data.last_event_offset // .from_offset' "$result")
  case "$observed_cursor" in ''|*[!0-9]*) die "AIME observation has an invalid event cursor" ;; esac
  if [ "$observed_from" -lt "$AIME_STATE_CURSOR" ] \
    && [ "$observed_cursor" -le "$AIME_STATE_CURSOR" ]; then
    case "$AIME_STATE_PHASE" in
      terminal-success|terminal-failure)
        ensure_terminal_status "$id" "$AIME_STATE_PHASE" \
          || die "cannot restore the terminal AIME status event"
        ;;
    esac
    "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
      || die "cannot acknowledge duplicate AIME observation"
    printf 'handled: %s duplicate=true cursor=%s\n' "$id" "$AIME_STATE_CURSOR"
    return 0
  fi
  [ "$observed_from" = "$AIME_STATE_CURSOR" ] \
    || die "AIME observation does not continue the durable cursor"

  observation=$(fm_aime_artifact_store "$id" observation "$result") \
    || die "cannot checkpoint AIME observation"

  if ! jq -e '.replay_ok == true and .session_ok == true' "$result" >/dev/null 2>&1; then
    class=$(jq -r '
      [.replay.error_class?,.session.error_class?]
      | map(select(type == "string" and length > 0))
      | first // "unavailable"
    ' "$result")
    record_result_unavailable "$id" "$class" "$observation" \
      || die "cannot record unavailable AIME readback"
    cmd_arm_locked "$id" >/dev/null \
      || die "cannot re-arm unavailable AIME readback"
    "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
      || die "cannot acknowledge unavailable AIME observation"
    printf 'handled: %s readback=%s rearmed=true\n' "$id" "$class"
    return 0
  fi

  current_cursor=$observed_cursor
  case "$current_cursor" in ''|*[!0-9]*) die "AIME observation has an invalid event cursor" ;; esac
  [ "$current_cursor" -ge "$AIME_STATE_CURSOR" ] || die "AIME event cursor regressed"
  cursor=$current_cursor
  terminal=$(jq -r '.terminal_candidate == true' "$result")
  if [ "$terminal" != true ]; then
    resolve_result_unavailable "$id" \
      || die "cannot resolve recovered AIME readback blocker"
    fm_aime_state_transition "$id" running "" "" \
      "$AIME_STATE_SESSION_ID" "$AIME_STATE_MESSAGE_ID" "$cursor" replay-progress \
      "$observation" "" rearming "" || die "cannot checkpoint AIME progress"
    cmd_arm_locked "$id" >/dev/null \
      || die "cannot re-arm AIME progress"
    "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
      || die "cannot acknowledge AIME progress"
    printf 'handled: %s phase=running cursor=%s rearmed=true\n' "$id" "$cursor"
    return 0
  fi

  provider_status=$(jq -r '.session.data.status // "unknown"' "$result")
  case "$provider_status" in
    failed|error|cancelled|canceled)
      resolve_result_unavailable "$id" \
        || die "cannot resolve recovered AIME readback blocker"
      record_terminal_result_failure "$id" provider-terminal-failure "$observation" "$cursor" \
        || die "cannot record provider-terminal AIME failure"
      "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
        || die "cannot acknowledge provider-terminal AIME failure"
      printf 'handled: %s phase=terminal-failure error=provider-terminal-failure\n' "$id"
      return 0
      ;;
  esac

  if ! jq -e '.output_ok == true' "$result" >/dev/null 2>&1; then
    class=$(jq -r '.output.error_class // "result-unavailable"' "$result")
    record_result_unavailable "$id" "$class" "$observation" \
      || die "cannot record unavailable terminal AIME output"
    cmd_arm_locked "$id" >/dev/null \
      || die "cannot re-arm unavailable terminal AIME output"
    "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
      || die "cannot acknowledge unavailable terminal AIME output"
    printf 'handled: %s readback=%s rearmed=true\n' "$id" "$class"
    return 0
  fi

  resolve_result_unavailable "$id" \
    || die "cannot resolve recovered AIME readback blocker"
  if ! jq -e '.output.data.finished == true and (.output.data.content | type == "string" and length > 0)' \
    "$result" >/dev/null 2>&1; then
    record_terminal_result_failure "$id" malformed-or-empty-output "$observation" "$cursor" \
      || die "cannot record terminal AIME output failure"
    "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
      || die "cannot acknowledge incomplete AIME output"
    printf 'handled: %s phase=terminal-failure error=malformed-or-empty-output\n' "$id"
    return 0
  fi

  output_file="$(fm_aime_task_dir "$id")/.output-$seq.json"
  jq '.output' "$result" >"$output_file" || die "cannot extract AIME output"
  chmod 0600 "$output_file" || die "cannot secure AIME output"
  artifact=$(fm_aime_artifact_store "$id" get-output "$output_file") \
    || { rm -f -- "$output_file"; die "cannot checkpoint AIME output"; }
  rm -f -- "$output_file"

  if [ "$AIME_STATE_RESULT_MODE" = document ]; then
    output_file="$artifact"
    content_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-aime-doc.XXXXXX") \
      || die "cannot stage AIME document marker"
    if jq -r '.data.content' "$output_file" >"$content_file" \
      && document_json=$(document_json_from_output "$content_file"); then
      document_state_json=$document_json
    else
      rm -f -- "$content_file"
      record_terminal_result_failure "$id" document-identity-missing "$observation" "$cursor" \
        || die "cannot record terminal missing AIME document identity"
      "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
        || die "cannot acknowledge missing AIME document identity"
      printf 'handled: %s phase=terminal-failure error=document-identity-missing\n' "$id"
      return 0
    fi
    rm -f -- "$content_file"
  fi

  report=$(write_report "$id" "$observation" "$artifact" "$document_state_json") \
    || die "cannot write the AIME report"
  fm_aime_state_transition "$id" terminal-success succeeded "" \
    "$AIME_STATE_SESSION_ID" "$AIME_STATE_MESSAGE_ID" "$cursor" result-verified \
    "$observation" "$report" terminal "$document_state_json" \
    || die "cannot checkpoint AIME completion"
  ensure_terminal_status "$id" terminal-success \
    || die "cannot append AIME completion event"
  "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
    || die "cannot acknowledge AIME completion"
  printf 'handled: %s phase=terminal-success report=%s\n' "$id" "$report"
}

cmd_handle() {
  local id=${1-} lock
  [ "$#" -eq 3 ] || usage
  fm_aime_task_id_valid "$id" || die "invalid task id"
  lock=$(fm_aime_task_lock_path "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock AIME task $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_handle_locked "$@"
  )
}

cmd_autohandle() {
  local source=${1-} seq=${2-} result=${3-} id
  [ "$#" -eq 3 ] || usage
  case "$source" in
    aime-?*) id=${source#aime-} ;;
    *) die "not an AIME source id: $source" ;;
  esac
  [ "$(fm_aime_source_id "$id")" = "$source" ] || die "AIME source id is not canonical"
  cmd_handle "$id" "$seq" "$result"
}

cmd_arm_locked() {
  local id=$1 source
  fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
  [ -n "$AIME_STATE_SESSION_ID" ] || die "AIME task has no checkpointed session id"
  case "$AIME_STATE_PHASE" in
    terminal-success|terminal-failure) die "AIME task is already terminal" ;;
    create-unknown) die "AIME create acceptance is unknown; no session can be armed" ;;
  esac
  source=$(fm_aime_source_id "$id") || die "invalid task id"
  "$SCRIPT_DIR/fm-procevent.sh" register aime "$source" -- \
    "$SCRIPT_DIR/fm-procevent-aime.sh" source "$id" || return 1
  fm_aime_state_transition "$id" "$AIME_STATE_PHASE" "$AIME_STATE_OUTCOME" "$AIME_STATE_ERROR_CLASS" \
    "$AIME_STATE_SESSION_ID" "$AIME_STATE_MESSAGE_ID" "$AIME_STATE_CURSOR" waiter-armed \
    "" "" armed "" || return 1
  printf 'armed: %s session=%s cursor=%s\n' "$source" "$AIME_STATE_SESSION_ID" "$AIME_STATE_CURSOR"
}

cmd_arm() {
  local id=${1-} lock
  [ "$#" -eq 1 ] || usage
  fm_aime_task_id_valid "$id" || die "invalid task id"
  lock=$(fm_aime_task_lock_path "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock AIME task $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_arm_locked "$id"
  )
}

cmd_retire() {
  local id=${1-} source
  [ "$#" -eq 1 ] || usage
  source=$(fm_aime_source_id "$id") || die "invalid task id"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$source"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  source) shift; cmd_source "$@" ;;
  handle) shift; cmd_handle "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  -h|--help|'') usage ;;
  *) usage ;;
esac
