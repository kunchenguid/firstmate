#!/usr/bin/env bash
# Provider configuration and normalized command helpers for the iDA remote
# agent. Sourced after fm-remote-agent-lib.sh; never executed directly.
#
# config/ida-remote-agent schema:
#   schema=fm-ida-remote-agent-config.v1
#   enabled=true|false
#   region=sg
#   identity=user
#   agent_id=default|<numeric iDA agent id>
#   model=default|<iDA model name>  # legacy optional field; never a dispatch default
#   bytedcli_version=<legacy informational value; optional>
#
# Prompt submission uses the domain-restricted bytedcli MCP `run_command` tool
# over stdio JSON-RPC so the parent iDA command can carry `--region sg`. The
# prompt exists only in a mode-0600 request file connected to stdin; it is never
# placed in an operating-system argv, status event, log, durable state, or
# provider artifact. CLI reads and cancellation use ordinary official
# `bytedcli --json --as user ida --region sg ...` commands because those carry
# no private prompt payload. All bytedcli children discard ambient proxy
# variables, which otherwise divert the SG identity endpoint through an
# incompatible proxy, while preserving the rest of the operator environment.
# Durable artifacts are normalized here and never preserve raw MCP responses
# or raw provider streams.
set -u

IDA_CONFIG_SCHEMA=fm-ida-remote-agent-config.v1
IDA_OBSERVATION_SCHEMA=fm-ida-observation.v1

fm_ida_config_path() { printf '%s/ida-remote-agent\n' "$CONFIG"; }

fm_ida_safe_token() {
  local value=${1-} LC_ALL=C
  case "$value" in ''|*[!A-Za-z0-9._:/+-]*) return 1 ;; esac
  [ "${#value}" -le 160 ]
}

fm_ida_numeric_id() {
  case "${1-}" in ''|*[!0-9]*) return 1 ;; esac
}

fm_ida_config_field() {
  local file=$1 key=$2 count
  count=$(grep -c "^$key=" "$file" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^$key=//p" "$file"
}

fm_ida_config_optional_field() {
  local file=$1 key=$2 count
  count=$(grep -c "^$key=" "$file" 2>/dev/null || true)
  [ "$count" -le 1 ] || return 1
  [ "$count" -eq 0 ] || sed -n "s/^$key=//p" "$file"
}

fm_ida_run_bytedcli() (
  unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli "$@"
)

fm_ida_config_load() {
  local file legacy_model
  file=$(fm_ida_config_path)
  fm_remote_private_file_safe "$file" || return 1
  IDA_CONFIG_SCHEMA_VALUE=$(fm_ida_config_field "$file" schema) || return 1
  IDA_CONFIG_ENABLED=$(fm_ida_config_field "$file" enabled) || return 1
  IDA_CONFIG_REGION=$(fm_ida_config_field "$file" region) || return 1
  IDA_CONFIG_IDENTITY=$(fm_ida_config_field "$file" identity) || return 1
  IDA_CONFIG_AGENT_ID=$(fm_ida_config_field "$file" agent_id) || return 1
  legacy_model=$(fm_ida_config_optional_field "$file" model) || return 1
  # Read legacy configs without turning their recorded version into a gate.
  # New configs omit this informational field.
  fm_ida_config_optional_field "$file" bytedcli_version >/dev/null || return 1
  [ "$IDA_CONFIG_SCHEMA_VALUE" = "$IDA_CONFIG_SCHEMA" ] || return 1
  case "$IDA_CONFIG_ENABLED" in true|false) ;; *) return 1 ;; esac
  [ "$IDA_CONFIG_REGION" = sg ] || return 1
  [ "$IDA_CONFIG_IDENTITY" = user ] || return 1
  [ "$IDA_CONFIG_AGENT_ID" = default ] || fm_ida_numeric_id "$IDA_CONFIG_AGENT_ID" || return 1
  if [ -n "$legacy_model" ]; then
    [ "$legacy_model" = default ] || fm_ida_safe_token "$legacy_model" || return 1
  fi
}

fm_ida_session_marker() {
  local id=$1 sha=$2
  fm_remote_task_id_valid "$id" || return 1
  case "$sha" in *[!0-9a-f]*|'') return 1 ;; esac
  printf 'firstmate:%s:%.16s\n' "$id" "$sha"
}

fm_ida_provider_state_validate() {
  local file=$1
  jq -e '
    .provider == "ida"
    and .provider_state.region == "sg"
    and .provider_state.identity == "user"
    and (.provider_state.session_marker | type == "string" and length > 0 and length <= 220)
    and (.provider_state.session_id == null or (.provider_state.session_id | type == "string" and test("^[0-9]+$")))
    and (.provider_state.task_id == null or (.provider_state.task_id | type == "string" and length > 0 and length <= 160))
    and (.provider_state.agent_id == null or (.provider_state.agent_id | type == "string" and test("^[0-9]+$")))
    and (.provider_state.agent_name == null or (.provider_state.agent_name | type == "string" and length <= 240))
    and (.provider_state.model == null or (.provider_state.model | type == "string" and length <= 160))
    and (.provider_state.provider_status == null or (.provider_state.provider_status | type == "string" and length <= 120))
    and (.provider_state.local_readback_blocked == null or (.provider_state.local_readback_blocked | type == "boolean"))
  ' "$file" >/dev/null 2>&1
}

fm_ida_state_load() {
  fm_remote_state_load "$1" || return 1
  [ "$REMOTE_STATE_PROVIDER" = ida ] || return 1
  fm_ida_provider_state_validate "$REMOTE_STATE_FILE" || return 1
  # shellcheck disable=SC2034 # Public values consumed by scripts that source this library.
  IDA_STATE_REGION=$(jq -r '.provider_state.region' "$REMOTE_STATE_FILE")
  # shellcheck disable=SC2034
  IDA_STATE_MARKER=$(jq -r '.provider_state.session_marker' "$REMOTE_STATE_FILE")
  # shellcheck disable=SC2034
  IDA_STATE_SESSION_ID=$(jq -r '.provider_state.session_id // ""' "$REMOTE_STATE_FILE")
  # shellcheck disable=SC2034
  IDA_STATE_TASK_ID=$(jq -r '.provider_state.task_id // ""' "$REMOTE_STATE_FILE")
  # shellcheck disable=SC2034
  IDA_STATE_AGENT_ID=$(jq -r '.provider_state.agent_id // ""' "$REMOTE_STATE_FILE")
  # shellcheck disable=SC2034
  IDA_STATE_AGENT_NAME=$(jq -r '.provider_state.agent_name // ""' "$REMOTE_STATE_FILE")
  # shellcheck disable=SC2034
  IDA_STATE_MODEL=$(jq -r '.provider_state.model // ""' "$REMOTE_STATE_FILE")
  # shellcheck disable=SC2034
  IDA_STATE_PROVIDER_STATUS=$(jq -r '.provider_state.provider_status // ""' "$REMOTE_STATE_FILE")
}

fm_ida_status_kind() {
  local status
  status=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' | tr ' -' '__')
  case "$status" in
    completed|complete|success|succeeded|finished|done) printf 'success\n' ;;
    failed|fail|error) printf 'failure\n' ;;
    cancelled|canceled|closed|stopped|shutdown|shut_down) printf 'cancelled\n' ;;
    ''|created|pending|queued|waiting|processing|running|in_progress|executing|streaming) printf 'running\n' ;;
    *) printf 'ambiguous\n' ;;
  esac
}

fm_ida_structured_success() {
  jq -e '.status == "success" and .error == null and (.data | type != "null")' "$1" >/dev/null 2>&1
}

# Read-only CLI calls preserve local failure categories without exposing stderr.
# Only a structured provider error enters the shared remote-error classifier.
fm_ida_read_error_classify() { # <stdout-file> <exit-code>; empty means success
  local out=$1 rc=$2
  case "$rc" in
    126) printf 'cli-not-executable\n'; return ;;
    127) printf 'cli-not-found\n'; return ;;
    124) printf 'timeout\n'; return ;;
  esac
  if ! [ -s "$out" ]; then
    printf 'response-empty\n'
  elif ! jq -e -s 'length == 1' "$out" >/dev/null 2>&1; then
    printf 'response-invalid-json\n'
  elif jq -e 'type == "object" and .status == "error"
      and (.error | type == "object")
      and (.error.code | type == "string")
      and (.error.message | type == "string")' "$out" >/dev/null 2>&1; then
    fm_remote_error_classify "$out"
  elif [ "$rc" -ne 0 ]; then
    printf 'cli-exit-error\n'
  elif ! jq -e 'type == "object" and .status == "success"
      and .error == null and (.data | type == "object")' "$out" >/dev/null 2>&1; then
    printf 'response-invalid-structure\n'
  fi
}

fm_ida_session_response_error() { # <successful-response> <expected-session-id>
  if ! jq -e '(.data.session | type == "object")
      and (.data.session.id | tostring | test("^[0-9]+$"))
      and (.data.messages | type == "array")
      and all(.data.messages[]; type == "object")' "$1" >/dev/null 2>&1; then
    printf 'response-invalid-structure\n'
  elif [ "$(jq -r '.data.session.id | tostring' "$1")" != "$2" ]; then
    printf 'session-identity-mismatch\n'
  fi
}

fm_ida_local_read_error() { # <error-class>
  case "$1" in
    cli-not-executable|cli-not-found|cli-exit-error|response-empty|response-invalid-json|response-invalid-structure|session-identity-mismatch) return 0 ;;
    *) return 1 ;;
  esac
}

fm_ida_normalize_error() {
  local out=$1 err=$2 dest=$3
  if jq -e . "$out" >/dev/null 2>&1; then
    jq '{status:(.status // "error"),error:{code:(.error.code // "PROVIDER_ERROR"),message:((.error.message // "provider command failed") | tostring | .[0:1000])}}' "$out" >"$dest"
  else
    jq -n --rawfile stderr "$err" '{status:"error",error:{code:"CLI_ERROR",message:($stderr | .[0:1000])}}' >"$dest"
  fi
}

fm_ida_observation_validate() {
  local file=$1 id=$2 marker=$3
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  jq -e --arg schema "$IDA_OBSERVATION_SCHEMA" --arg id "$id" --arg marker "$marker" '
    .schema == $schema and .task_id == $id and .provider == "ida" and .region == "sg"
    and .session_marker == $marker
    and (.kind == "submission" or .kind == "reconcile" or .kind == "session")
    and (.terminal | type == "boolean") and (.ambiguous | type == "boolean")
    and (.session_id == null or (.session_id | type == "string" and test("^[0-9]+$")))
    and (.task_id_remote == null or (.task_id_remote | type == "string" and length > 0))
    and (.provider_status == null or (.provider_status | type == "string" and length <= 120))
    and (.result_availability == "available" or .result_availability == "zero" or .result_availability == "unavailable" or .result_availability == "error")
    and (.answer == null or (.answer | type == "string"))
    and ((has("result_kind") | not) or .result_kind == null or .result_kind == "text" or .result_kind == "artifact")
    and ((has("artifact_reference") | not) or .artifact_reference == null or (
      (.artifact_reference | type) == "object"
      and (.artifact_reference | keys | sort) == ["artifact_count","kind","part_count","part_kinds","readback","schema"]
      and .artifact_reference.schema == "fm-ida-artifact-reference.v1"
      and .artifact_reference.kind == "deep-research-final-answer"
      and .artifact_reference.readback == "session-get"
      and (.artifact_reference.artifact_count | type == "number" and . >= 1 and floor == .)
      and (.artifact_reference.part_count | type == "number" and . >= 1 and floor == .)
      and (.artifact_reference.part_kinds | type == "array" and length >= 1
        and all(.[]; . == "file" or . == "data"))
    ))
    and (
      if .result_kind == "text" then (.answer | type == "string" and length > 0) and .artifact_reference == null
      elif .result_kind == "artifact" then .answer == null and (.artifact_reference | type == "object")
      elif has("result_kind") then .answer == null and .artifact_reference == null
      else true
      end
    )
    and (.error_class == null or (.error_class | type == "string" and length <= 120))
  ' "$file" >/dev/null 2>&1
}
