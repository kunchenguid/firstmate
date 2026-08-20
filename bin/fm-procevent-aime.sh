#!/usr/bin/env bash
# AIME adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-aime.sh arm <task-id>
#   fm-procevent-aime.sh source <task-id>
#   fm-procevent-aime.sh handle <task-id> <sequence> <result-file>
#   fm-procevent-aime.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-aime.sh terminal <result-file>
#   fm-procevent-aime.sh prepare-retire <task-id>
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
# A malformed capture remains rejected until a later identity-bound observation
# is applied; `handle` then preserves the superseded bytes as task evidence
# before acknowledging that older generation through the adapter-owned path.
# `source` reduces replay history to one bounded summary before transport; raw
# replay event/tool payloads never enter an observation, status event, or report.
# `prepare-retire` seals only an identity-bound provider status `stopped` plus
# authoritative terminal replay plus unavailable bounded output readback, using
# the preserved observation when sufficient or one bounded fresh readback.
# It requires or preserves a safe report, stops the canonical source, then
# quarantines and acknowledges at most FM_AIME_RETIRE_MAX_GENERATIONS exact
# captured generations and removes only their exact queued wake records.
# Every checkpoint is idempotent; an unsafe, unrelated, contradictory, or
# over-bound generation refuses the seal without trusting its payload bytes.
#
# Every source invocation exits 0 with one bounded JSON observation, including
# provider errors.
# This avoids the generic runner's "nonzero plus empty output" retry ambiguity.
# A failed readback is re-armed unless the same identity-bound observation also
# proves provider status `stopped` and authoritative terminal replay.
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
AIME_RETIRE_MAX_GENERATIONS=${FM_AIME_RETIRE_MAX_GENERATIONS:-256}
AIME_RETIRE_MAX_CAPTURE_BYTES=${FM_AIME_RETIRE_MAX_CAPTURE_BYTES:-1048576}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

validate_positive() {
  case "$2" in ''|0|*[!0-9]*) die "$1 must be a positive integer" ;; esac
}

validate_positive FM_AIME_REPLAY_TIMEOUT_MS "$AIME_REPLAY_TIMEOUT_MS"
validate_positive FM_AIME_REPLAY_MAX_STREAMS "$AIME_REPLAY_MAX_STREAMS"
validate_positive FM_AIME_READBACK_TIMEOUT "$AIME_READBACK_TIMEOUT"
validate_positive FM_AIME_RETIRE_MAX_GENERATIONS "$AIME_RETIRE_MAX_GENERATIONS"
validate_positive FM_AIME_RETIRE_MAX_CAPTURE_BYTES "$AIME_RETIRE_MAX_CAPTURE_BYTES"

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

write_replay_summary() { # <replay-response> <destination>
  jq -c '
    {
      status:"success",
      data:{
        session_id:.data.session_id,
        terminal:(.data.terminal == true),
        last_event_offset:(.data.last_event_offset // null),
        event_count:(.data.events | length)
      },
      error:null
    }
  ' "$1" >"$2"
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
    write_replay_summary "$replay_out" "$root/replay-summary.json" \
      || die "cannot summarize AIME replay"
    mv -f -- "$root/replay-summary.json" "$replay_out" \
      || die "cannot stage AIME replay summary"
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

  jq -cn \
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

write_report() { # <id> <observation-artifact> <output-artifact> <document-json-or-empty>
  local id=$1 observation=$2 output_file=$3 document_json=$4 report content_file
  report=$(fm_aime_report_path "$id") || return 1
  content_file="${output_file}.content"
  jq -r '.data.content // ""' "$output_file" >"$content_file" || return 1
  [ -s "$content_file" ] || return 2
  fm_aime_report_replaceable "$id" || return 1
  # shellcheck disable=SC2016 # Backticks below are literal Markdown.
  {
    printf '# AIME cloud research report\n\n'
    printf -- '- Task: `%s`\n' "$id"
    printf -- '- Executor: `%s`\n' "$AIME_STATE_EXECUTOR"
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
  report=$(fm_aime_report_path "$id") || return 1
  fm_aime_report_replaceable "$id" || return 1
  # shellcheck disable=SC2016 # Backticks below are literal Markdown.
  {
    printf '# AIME cloud research result\n\n'
    printf -- '- Task: `%s`\n' "$id"
    printf -- '- Executor: `%s`\n' "$AIME_STATE_EXECUTOR"
    printf -- '- Provider: `aime`\n'
    printf -- '- Site: `%s`\n' "$AIME_STATE_SITE"
    printf -- '- Space: `%s`\n' "$AIME_STATE_SPACE_ID"
    printf -- '- Session: `%s`\n' "$AIME_STATE_SESSION_ID"
    printf -- '- bytedcli: `%s`\n' "$AIME_STATE_BYTEDCLI_VERSION"
    printf -- '- Outcome: `failed`\n'
    printf -- '- Error class: `%s`\n' "$class"
    printf -- '- Observation: `%s`\n' "$observation"
    if [ "$class" = provider-stopped-output-unavailable ]; then
      printf '\n## Terminal Outcome\n\n'
      printf '%s\n' '- Provider status: `stopped`'
      printf '%s\n' '- Authoritative provider terminal: `true`'
      printf '%s\n' '- Requested output: `unavailable after bounded readback`'
      printf '%s\n' '- Outcome: `failed`'
      printf '\nThe provider confirmed that execution stopped, while bounded output readback produced no readable result.\n'
      printf 'Firstmate recovered no result, computed no replacement outcome, and neither attempted nor claimed provider cancellation.\n'
    else
      printf '\nThe AIME session reached a terminal provider event, but no valid requested result was recoverable.\n'
    fi
    if [ "$class" = document-identity-missing ]; then
      printf 'Firstmate did not create, copy, rewrite, share, or change permissions on any Feishu document.\n'
    fi
    printf 'Provider output grants no implementation, publication, merge, destructive, or security authority.\n'
  } >"$report" || return 1
  chmod 0600 "$report" || return 1
  printf '%s\n' "$report"
}

record_terminal_result_failure() { # <id> <error-class> <observation-path> <cursor>
  local id=$1 class=$2 observation=$3 cursor=$4 report checkpoint=terminal-result-invalid
  report=$(write_terminal_failure_report "$id" "$class" "$observation") || return 1
  [ "$class" != provider-stopped-output-unavailable ] || checkpoint='terminal-output-unavailable'
  fm_aime_state_transition "$id" terminal-failure failed "$class" \
    "$AIME_STATE_SESSION_ID" "$AIME_STATE_MESSAGE_ID" "$cursor" "$checkpoint" \
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
  local id=$1 line status
  [ "$AIME_STATE_PHASE" = result-unavailable ] || return 0
  line="resolved [key=aime-result-unavailable]: authoritative AIME readback recovered"
  status="$STATE/$id.status"
  grep -Fqx "$line" "$status" 2>/dev/null && return 0
  fm_aime_status_append "$id" "$line"
}

terminal_unavailable_observation() { # <task-id> <observation>
  local id=$1 observation=$2 cursor
  validate_observation "$observation" "$id" || return 1
  [ "$(jq -r '.session_id' "$observation")" = "$AIME_STATE_SESSION_ID" ] || return 1
  [ "$(jq -r '.site' "$observation")" = "$AIME_STATE_SITE" ] || return 1
  jq -e --arg session "$AIME_STATE_SESSION_ID" '
    .replay_ok == true
    and .session_ok == true
    and .terminal_candidate == true
    and .replay.data.session_id == $session
    and .replay.data.terminal == true
    and (.replay.data.event_count | type == "number" and . > 0 and floor == .)
    and (.replay.data.last_event_offset as $last
      | .from_offset as $from
      | ($last | type) == "number" and ($last | floor) == $last and $last >= $from)
    and .session.data.id == $session
    and .session.data.status == "stopped"
    and .output_ok == false
    and .output.status == "error"
    and (.output.error_class | type == "string" and length > 0)
  ' "$observation" >/dev/null 2>&1 || return 1
  cursor=$(jq -r '.replay.data.last_event_offset' "$observation")
  case "$cursor" in ''|*[!0-9]*) return 1 ;; esac
}

terminal_unavailable_state_observation() { # <task-id>
  local id=$1 task_dir observation observed_from cursor
  task_dir=$(fm_aime_task_dir "$id") || return 1
  observation=$AIME_STATE_RESULT_PATH
  case "$observation" in
    "$task_dir"/artifacts/*-observation.json) ;;
    *) return 1 ;;
  esac
  fm_aime_private_file_safe "$observation" || return 1
  terminal_unavailable_observation "$id" "$observation" || return 1
  observed_from=$(jq -r '.from_offset' "$observation")
  cursor=$(jq -r '.replay.data.last_event_offset' "$observation")
  if [ "$AIME_STATE_PHASE" = result-unavailable ]; then
    [ "$observed_from" = "$AIME_STATE_CURSOR" ] || return 1
  else
    [ "$cursor" = "$AIME_STATE_CURSOR" ] || return 1
  fi
  AIME_TERMINAL_UNAVAILABLE_OBSERVATION=$observation
  AIME_TERMINAL_UNAVAILABLE_CURSOR=$cursor
}

refresh_terminal_unavailable_observation() { # <task-id>
  local id=$1 root readback summary artifact cursor
  root=$(temp_root)
  readback="$root/readback.json"
  summary="$root/terminal-unavailable.json"
  cmd_source "$id" >"$readback" || { rm -rf -- "$root"; return 1; }
  terminal_unavailable_observation "$id" "$readback" || { rm -rf -- "$root"; return 1; }
  jq -c '
    {
      schema,task_id,provider,site,session_id,from_offset,replay_ok,session_ok,output_ok,
      terminal_candidate,
      replay:{status:.replay.status,data:{session_id:.replay.data.session_id,terminal:.replay.data.terminal,last_event_offset:.replay.data.last_event_offset,event_count:.replay.data.event_count},error:null},
      session:{status:.session.status,data:{id:.session.data.id,status:.session.data.status},error:null},
      output:{status:.output.status,error_class:.output.error_class}
    }
  ' "$readback" >"$summary" || { rm -rf -- "$root"; return 1; }
  artifact=$(fm_aime_artifact_store "$id" observation "$summary") \
    || { rm -rf -- "$root"; return 1; }
  cursor=$(jq -r '.replay.data.last_event_offset' "$summary")
  rm -rf -- "$root"
  AIME_TERMINAL_UNAVAILABLE_OBSERVATION=$artifact
  AIME_TERMINAL_UNAVAILABLE_CURSOR=$cursor
}

append_terminal_unavailable_report() { # <task-id>
  local id=$1 report marker tmp
  # shellcheck disable=SC2016 # Backticks below are literal Markdown.
  marker='- Requested output: `unavailable after bounded readback`'
  report=$(fm_aime_report_path "$id") || return 1
  fm_aime_report_safe "$id" || return 1
  grep -Fqx -- "$marker" "$report" 2>/dev/null && return 0
  tmp=$(umask 077; mktemp "$DATA/$id/.report-terminal.XXXXXX") || return 1
  # shellcheck disable=SC2016 # Backticks below are literal Markdown.
  {
    cat "$report"
    printf '\n\n## Terminal Outcome\n\n'
    printf '%s\n' '- Provider status: `stopped`'
    printf '%s\n' '- Authoritative provider terminal: `true`'
    printf '%s\n' "$marker"
    printf '%s\n' '- Outcome: `failed`'
    printf '\nThe provider confirmed that execution stopped, while bounded output readback produced no readable result.\n'
    printf 'Firstmate recovered no result, computed no replacement outcome, and neither attempted nor claimed provider cancellation.\n'
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$report"
}

aime_quarantine_dir() { # <task-id>
  printf '%s/%s/aime-quarantine\n' "$DATA" "$1"
}

ensure_quarantine_dir() { # <task-id>
  local id=$1 task_data dir mode owner
  task_data="$DATA/$id"
  [ -d "$task_data" ] && [ ! -L "$task_data" ] || return 1
  dir=$(aime_quarantine_dir "$id")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    (umask 077; mkdir "$dir") || return 1
  fi
  chmod 0700 "$dir" || return 1
  mode=$(fm_aime_file_mode "$dir") || return 1
  [ "$mode" = 700 ] || return 1
  owner=$(fm_aime_file_owner "$dir") || return 1
  [ "$owner" = "$(id -u)" ]
}

captured_generation_preflight() { # <task-id> <source-id> <sequence> <result>
  local id=$1 source=$2 seq=$3 result=$4 expected adapter_file adapter size schema_task schema_site schema_session
  expected="$(fm_procevent_inbox_dir "$STATE")/$source.$seq.result"
  [ "$result" = "$expected" ] || { AIME_RETIRE_REFUSAL="generation $seq path is not canonical"; return 1; }
  [ "$(fm_procevent_result_source_id "$result")" = "$source" ] \
    || { AIME_RETIRE_REFUSAL="generation $seq source identity does not match"; return 1; }
  [ "$(fm_procevent_result_sequence "$result")" = "$seq" ] \
    || { AIME_RETIRE_REFUSAL="generation $seq identity does not match its path"; return 1; }
  adapter_file=${result%.result}.adapter
  fm_aime_private_file_safe "$result" \
    || { AIME_RETIRE_REFUSAL="generation $seq result file is unsafe"; return 1; }
  fm_aime_private_file_safe "$adapter_file" \
    || { AIME_RETIRE_REFUSAL="generation $seq adapter identity is unsafe"; return 1; }
  adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null || true)
  [ "$adapter" = aime ] \
    || { AIME_RETIRE_REFUSAL="generation $seq is not owned by the AIME adapter"; return 1; }
  size=$(wc -c <"$result" | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) AIME_RETIRE_REFUSAL="generation $seq size is unreadable"; return 1 ;; esac
  [ "$size" -le "$AIME_RETIRE_MAX_CAPTURE_BYTES" ] \
    || { AIME_RETIRE_REFUSAL="generation $seq exceeds the quarantine byte bound"; return 1; }
  if jq -e --arg schema "$AIME_OBSERVATION_SCHEMA" '.schema == $schema' "$result" >/dev/null 2>&1; then
    schema_task=$(jq -r '.task_id // ""' "$result")
    schema_site=$(jq -r '.site // ""' "$result")
    schema_session=$(jq -r '.session_id // ""' "$result")
    [ "$schema_task" = "$id" ] && [ "$schema_site" = "$AIME_STATE_SITE" ] \
      && [ "$schema_session" = "$AIME_STATE_SESSION_ID" ] \
      || { AIME_RETIRE_REFUSAL="generation $seq observation identity does not match the task"; return 1; }
    terminal_unavailable_observation "$id" "$result" \
      || { AIME_RETIRE_REFUSAL="generation $seq contradicts the terminal-unavailable outcome"; return 1; }
    AIME_CAPTURE_CLASS='terminal-output-unavailable'
  else
    AIME_CAPTURE_CLASS=malformed
  fi
  AIME_CAPTURE_SIZE=$size
}

quarantine_generation() { # <task-id> <source-id> <sequence> <result>
  local id=$1 source=$2 seq=$3 result=$4 dir dest tmp source_sha dest_sha
  ensure_quarantine_dir "$id" || return 1
  dir=$(aime_quarantine_dir "$id")
  dest="$dir/$source.$seq.result"
  source_sha=$(fm_aime_sha256_file "$result") || return 1
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fm_aime_private_file_safe "$dest" || return 1
    dest_sha=$(fm_aime_sha256_file "$dest") || return 1
    [ "$source_sha" = "$dest_sha" ] || return 1
  else
    tmp=$(umask 077; mktemp "$dir/.generation-$seq.XXXXXX") || return 1
    cat "$result" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    dest_sha=$(fm_aime_sha256_file "$tmp") || { rm -f -- "$tmp"; return 1; }
    [ "$source_sha" = "$dest_sha" ] || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  fi
  AIME_CAPTURE_SHA=$source_sha
}

append_quarantined_generation_report() { # <task-id> <source-id> <sequence> <class> <bytes> <sha>
  local id=$1 source=$2 seq=$3 class=$4 bytes=$5 sha=$6 report header line tmp
  report=$(fm_aime_report_path "$id") || return 1
  fm_aime_report_safe "$id" || return 1
  header='## Retired Captured Observations'
  line="- \`$source#$seq\`: \`$class\`, $bytes bytes, SHA-256 \`$sha\`; the AIME adapter quarantined the untrusted bytes before acknowledging only this generation."
  grep -Fqx -- "$line" "$report" 2>/dev/null && return 0
  tmp=$(umask 077; mktemp "$DATA/$id/.report-generation.XXXXXX") || return 1
  {
    cat "$report"
    if ! grep -Fqx -- "$header" "$report" 2>/dev/null; then
      printf '\n\n%s\n\n' "$header"
    else
      printf '\n'
    fi
    printf '%s\n' "$line"
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$report"
}

remove_queued_generation() { # <source-id> <sequence>
  local source=$1 seq=$2 key payload tmp status=0
  key="procevent:$source:$seq"
  payload="check: procevent aime $source $seq"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if [ ! -e "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if [ ! -f "$FM_WAKE_QUEUE" ] || [ -L "$FM_WAKE_QUEUE" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  tmp=$(umask 077; mktemp "$STATE/.wake-aime-retire.XXXXXX") || {
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  }
  awk -F '\t' -v key="$key" -v payload="$payload" \
    '!(NF >= 5 && $3 == "check" && $4 == key && $5 == payload)' \
    "$FM_WAKE_QUEUE" >"$tmp" || status=1
  [ "$status" -ne 0 ] || chmod 0600 "$tmp" || status=1
  [ "$status" -ne 0 ] || mv -f -- "$tmp" "$FM_WAKE_QUEUE" || status=1
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

source_generation_quarantined() { # <task-id> <source-id> <sequence>
  local dir
  dir=$(aime_quarantine_dir "$1")
  [ -f "$dir/$2.$3.result" ] && [ ! -L "$dir/$2.$3.result" ]
}

preflight_captured_generations() { # <task-id> <source-id>
  local id=$1 source=$2 inbox seq result adapter_file handled quarantine=false
  inbox=$(fm_procevent_inbox_dir "$STATE")
  seq=1
  while [ "$seq" -le "$AIME_RETIRE_MAX_GENERATIONS" ]; do
    result="$inbox/$source.$seq.result"
    adapter_file=${result%.result}.adapter
    handled=${result%.result}.handled
    quarantine=false
    source_generation_quarantined "$id" "$source" "$seq" && quarantine=true
    if [ ! -e "$result" ] && [ ! -L "$result" ]; then
      if [ -e "$adapter_file" ] || [ -L "$adapter_file" ] \
        || [ -e "$handled" ] || [ -L "$handled" ] || [ "$quarantine" = true ]; then
        AIME_RETIRE_REFUSAL="generation $seq has incomplete captured state"
        return 1
      fi
      AIME_RETIRE_LAST_SEQUENCE=$((seq - 1))
      return 0
    fi
    if { [ -e "$result" ] || [ -L "$result" ]; } \
      && { [ "$quarantine" = true ] || ! fm_procevent_is_handled "$STATE" "$source" "$seq"; }; then
      captured_generation_preflight "$id" "$source" "$seq" "$result" || return 1
    fi
    seq=$((seq + 1))
  done
  result="$inbox/$source.$((AIME_RETIRE_MAX_GENERATIONS + 1)).result"
  if [ -e "$result" ] || [ -L "$result" ]; then
    AIME_RETIRE_REFUSAL="captured generations exceed the bounded retirement scan"
    return 1
  fi
  AIME_RETIRE_LAST_SEQUENCE=$AIME_RETIRE_MAX_GENERATIONS
}

quarantine_captured_generations() { # <task-id> <source-id>
  local id=$1 source=$2 inbox seq result quarantine=false
  preflight_captured_generations "$id" "$source" || return 1
  inbox=$(fm_procevent_inbox_dir "$STATE")
  seq=1
  while [ "$seq" -le "$AIME_RETIRE_LAST_SEQUENCE" ]; do
    result="$inbox/$source.$seq.result"
    quarantine=false
    source_generation_quarantined "$id" "$source" "$seq" && quarantine=true
    if { [ -e "$result" ] || [ -L "$result" ]; } \
      && { [ "$quarantine" = true ] || ! fm_procevent_is_handled "$STATE" "$source" "$seq"; }; then
      captured_generation_preflight "$id" "$source" "$seq" "$result" || return 1
      quarantine_generation "$id" "$source" "$seq" "$result" \
        || { AIME_RETIRE_REFUSAL="generation $seq could not be quarantined"; return 1; }
      append_quarantined_generation_report "$id" "$source" "$seq" "$AIME_CAPTURE_CLASS" \
        "$AIME_CAPTURE_SIZE" "$AIME_CAPTURE_SHA" \
        || { AIME_RETIRE_REFUSAL="generation $seq could not be recorded in the report"; return 1; }
      "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
        || { AIME_RETIRE_REFUSAL="generation $seq could not be acknowledged"; return 1; }
      fm_procevent_is_handled "$STATE" "$source" "$seq" \
        || { AIME_RETIRE_REFUSAL="generation $seq acknowledgement is not durable"; return 1; }
      remove_queued_generation "$source" "$seq" \
        || { AIME_RETIRE_REFUSAL="generation $seq queued wake could not be retired"; return 1; }
    fi
    seq=$((seq + 1))
  done
}

retire_terminal_unavailable_source() { # <source-id>
  local source=$1 registration claim
  registration="$(fm_procevent_registry_dir "$STATE")/$source.source"
  claim=$(fm_procevent_claim_path "$source") || return 1
  if [ ! -e "$registration" ] && [ ! -L "$registration" ] \
    && [ ! -e "$claim" ] && [ ! -L "$claim" ]; then
    return 0
  fi
  "$SCRIPT_DIR/fm-procevent.sh" retire "$source" >/dev/null || return 1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] \
    && [ ! -e "$claim" ] && [ ! -L "$claim" ]
}

seal_terminal_unavailable_locked() { # <task-id>
  local id=$1 source report
  AIME_RETIRE_REFUSAL=
  fm_aime_state_load "$id" || { AIME_RETIRE_REFUSAL="task state is missing or invalid"; return 1; }
  case "$AIME_STATE_PHASE:$AIME_STATE_ERROR_CLASS" in
    result-unavailable:*)
      fm_aime_report_safe "$id" \
        || { AIME_RETIRE_REFUSAL="a safe failure report is required before sealing"; return 1; }
      if ! terminal_unavailable_state_observation "$id" \
        && ! refresh_terminal_unavailable_observation "$id"; then
        AIME_RETIRE_REFUSAL="terminal stopped/output-unavailable evidence is not proven"
        return 1
      fi
      append_terminal_unavailable_report "$id" \
        || { AIME_RETIRE_REFUSAL="the failure report could not record output unavailability"; return 1; }
      resolve_result_unavailable "$id" \
        || { AIME_RETIRE_REFUSAL="the readback blocker could not be resolved"; return 1; }
      report=$(fm_aime_report_path "$id") || return 1
      fm_aime_state_transition "$id" terminal-failure failed provider-stopped-output-unavailable \
        "$AIME_STATE_SESSION_ID" "$AIME_STATE_MESSAGE_ID" "$AIME_TERMINAL_UNAVAILABLE_CURSOR" \
        terminal-output-unavailable "$AIME_TERMINAL_UNAVAILABLE_OBSERVATION" "$report" terminal "" \
        || { AIME_RETIRE_REFUSAL="terminal failure state could not be checkpointed"; return 1; }
      ensure_terminal_status "$id" terminal-failure \
        || { AIME_RETIRE_REFUSAL="terminal failure status could not be checkpointed"; return 1; }
      fm_aime_state_load "$id" || return 1
      ;;
    terminal-failure:provider-stopped-output-unavailable) ;;
    *) AIME_RETIRE_REFUSAL="task is not the stopped terminal-unavailable failure class"; return 1 ;;
  esac
  terminal_unavailable_state_observation "$id" \
    || { AIME_RETIRE_REFUSAL="sealed state lost its terminal stopped/output-unavailable proof"; return 1; }
  report=$(fm_aime_report_path "$id") || return 1
  if [ "$AIME_STATE_PROVIDER_CHECKPOINT" != terminal-output-unavailable ] \
    || [ "$AIME_STATE_WAITER" != terminal ] \
    || [ "$AIME_STATE_REPORT_PATH" != "$report" ] \
    || ! fm_aime_report_safe "$id"; then
    AIME_RETIRE_REFUSAL="sealed state or report binding is incomplete"
    return 1
  fi
  append_terminal_unavailable_report "$id" \
    || { AIME_RETIRE_REFUSAL="the failure report could not preserve the terminal outcome"; return 1; }
  source=$(fm_aime_source_id "$id") || return 1
  retire_terminal_unavailable_source "$source" \
    || { AIME_RETIRE_REFUSAL="canonical result source could not be proven retired"; return 1; }
  quarantine_captured_generations "$id" "$source" || return 1
}

newer_observation_was_applied() { # <task-id> <source-id> <older-sequence>
  local id=$1 source=$2 older_seq=$3 current_observation current_sha candidate candidate_sha
  local candidate_seq candidate_adapter observed_from observed_cursor event_count inbox task_dir
  current_observation=$(jq -r '.result_path // ""' "$AIME_STATE_FILE") || return 1
  task_dir=$(fm_aime_task_dir "$id") || return 1
  case "$current_observation" in
    "$task_dir"/artifacts/*-observation.json) ;;
    *) return 1 ;;
  esac
  [ -f "$current_observation" ] && [ ! -L "$current_observation" ] || return 1
  current_sha=$(fm_aime_sha256_file "$current_observation") || return 1
  inbox=$(fm_procevent_inbox_dir "$STATE")
  for candidate in "$inbox/$source".*.result; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    candidate_seq=$(fm_procevent_result_sequence "$candidate") || continue
    case "$candidate_seq" in ''|*[!0-9]*) continue ;; esac
    [ "$candidate_seq" -gt "$older_seq" ] || continue
    fm_procevent_is_handled "$STATE" "$source" "$candidate_seq" || continue
    candidate_adapter=$(fm_procevent_result_adapter "$candidate" 2>/dev/null || true)
    [ "$candidate_adapter" = aime ] || continue
    validate_observation "$candidate" "$id" || continue
    [ "$(jq -r '.session_id' "$candidate")" = "$AIME_STATE_SESSION_ID" ] || continue
    [ "$(jq -r '.site' "$candidate")" = "$AIME_STATE_SITE" ] || continue
    jq -e '.replay_ok == true and .session_ok == true' "$candidate" >/dev/null 2>&1 || continue
    observed_from=$(jq -r '.from_offset' "$candidate")
    observed_cursor=$(jq -r '.replay.data.last_event_offset // .from_offset' "$candidate")
    event_count=$(jq -r '.replay.data.event_count // 0' "$candidate")
    case "$observed_from:$observed_cursor:$event_count" in
      *[!0-9:]*) continue ;;
    esac
    [ "$event_count" -gt 0 ] && [ "$observed_cursor" -gt "$observed_from" ] \
      && [ "$AIME_STATE_CURSOR" -ge "$observed_cursor" ] || continue
    candidate_sha=$(fm_aime_sha256_file "$candidate") || continue
    [ "$candidate_sha" = "$current_sha" ] || continue
    return 0
  done
  return 1
}

recover_superseded_malformed_observation() { # <task-id> <source-id> <sequence> <result>
  local id=$1 source=$2 seq=$3 result=$4 expected adapter artifact
  expected="$(fm_procevent_inbox_dir "$STATE")/$source.$seq.result"
  [ "$result" = "$expected" ] || return 1
  adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null || true)
  [ "$adapter" = aime ] || return 1
  newer_observation_was_applied "$id" "$source" "$seq" || return 1
  artifact=$(fm_aime_artifact_store "$id" malformed-observation "$result") || return 1
  "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null || return 1
  printf 'handled: %s malformed-superseded=true evidence=%s cursor=%s\n' \
    "$id" "$artifact" "$AIME_STATE_CURSOR"
}

cmd_handle_locked() {
  local id=$1 seq=$2 result=$3 source observation artifact cursor class terminal=false output_file
  local report document_json='' document_state_json='' current_cursor content_file observed_from observed_cursor
  local provider_status
  source=$(fm_aime_source_id "$id") || die "invalid task id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  if ! validate_observation "$result" "$id"; then
    fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
    if terminal_unavailable_state_observation "$id" && fm_aime_report_safe "$id"; then
      seal_terminal_unavailable_locked "$id" \
        || die "cannot seal terminal-unavailable AIME failure: $AIME_RETIRE_REFUSAL"
      if fm_procevent_is_handled "$STATE" "$source" "$seq"; then
        printf 'handled: %s malformed-terminal-unavailable=true cursor=%s\n' \
          "$id" "$AIME_STATE_CURSOR"
        return 0
      fi
    fi
    recover_superseded_malformed_observation "$id" "$source" "$seq" "$result" \
      || die "AIME observation is malformed"
    return 0
  fi
  fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
  if fm_procevent_is_handled "$STATE" "$source" "$seq"; then
    case "$AIME_STATE_PHASE" in
      terminal-success|terminal-failure)
        ensure_terminal_status "$id" "$AIME_STATE_PHASE" \
          || die "cannot restore the terminal AIME status event"
        ;;
    esac
    if [ "$AIME_STATE_PHASE:$AIME_STATE_ERROR_CLASS" \
      = terminal-failure:provider-stopped-output-unavailable ]; then
      seal_terminal_unavailable_locked "$id" \
        || die "cannot finish terminal-unavailable AIME retirement preparation: $AIME_RETIRE_REFUSAL"
    fi
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
    if [ "$AIME_STATE_PHASE:$AIME_STATE_ERROR_CLASS" \
      = terminal-failure:provider-stopped-output-unavailable ]; then
      seal_terminal_unavailable_locked "$id" \
        || die "cannot finish terminal-unavailable AIME retirement preparation: $AIME_RETIRE_REFUSAL"
    fi
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
    if [ "$provider_status" = stopped ]; then
      resolve_result_unavailable "$id" \
        || die "cannot resolve recovered AIME readback blocker"
      record_terminal_result_failure "$id" provider-stopped-output-unavailable "$observation" "$cursor" \
        || die "cannot record stopped terminal AIME output failure"
      seal_terminal_unavailable_locked "$id" \
        || die "cannot finish stopped terminal AIME output failure: $AIME_RETIRE_REFUSAL"
      "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq" >/dev/null \
        || die "cannot acknowledge stopped terminal AIME output failure"
      printf 'handled: %s phase=terminal-failure error=provider-stopped-output-unavailable\n' "$id"
      return 0
    fi
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

cmd_prepare_retire() {
  local id=${1-} lock
  [ "$#" -eq 1 ] || usage
  fm_aime_task_id_valid "$id" || die "invalid task id"
  lock=$(fm_aime_task_lock_path "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock AIME task $id"
    trap 'fm_lock_release "$lock"' EXIT
    fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
    case "$AIME_STATE_PHASE:$AIME_STATE_ERROR_CLASS" in
      result-unavailable:*|terminal-failure:provider-stopped-output-unavailable)
        seal_terminal_unavailable_locked "$id" \
          || die "cannot prepare terminal-unavailable AIME retirement: $AIME_RETIRE_REFUSAL"
        printf 'prepared-retirement: %s phase=terminal-failure error=provider-stopped-output-unavailable\n' "$id"
        ;;
      *) printf 'prepare-retirement: %s no-terminal-unavailable-transition\n' "$id" ;;
    esac
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
  prepare-retire) shift; cmd_prepare_retire "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  -h|--help|'') usage ;;
  *) usage ;;
esac
