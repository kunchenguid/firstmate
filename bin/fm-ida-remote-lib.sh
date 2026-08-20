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
#   model=default|<iDA model name>
#   bytedcli_version=<exact tested version>
#
# Prompt submission uses `bytedcli mcp --allow-domains ida --all-tools` over
# stdio JSON-RPC. The prompt exists only in a mode-0600 request file connected
# to stdin; it is never placed in an operating-system argv, status event, log,
# durable state, or provider artifact. CLI reads and cancellation use ordinary
# official `bytedcli --json ida --region sg ...` commands because those carry no
# private prompt payload. All durable artifacts are normalized here and never
# preserve raw MCP responses or raw provider streams.
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

fm_ida_config_load() {
  local file
  file=$(fm_ida_config_path)
  fm_remote_private_file_safe "$file" || return 1
  IDA_CONFIG_SCHEMA_VALUE=$(fm_ida_config_field "$file" schema) || return 1
  IDA_CONFIG_ENABLED=$(fm_ida_config_field "$file" enabled) || return 1
  IDA_CONFIG_REGION=$(fm_ida_config_field "$file" region) || return 1
  IDA_CONFIG_IDENTITY=$(fm_ida_config_field "$file" identity) || return 1
  IDA_CONFIG_AGENT_ID=$(fm_ida_config_field "$file" agent_id) || return 1
  IDA_CONFIG_MODEL=$(fm_ida_config_field "$file" model) || return 1
  IDA_CONFIG_BYTEDCLI_VERSION=$(fm_ida_config_field "$file" bytedcli_version) || return 1
  [ "$IDA_CONFIG_SCHEMA_VALUE" = "$IDA_CONFIG_SCHEMA" ] || return 1
  case "$IDA_CONFIG_ENABLED" in true|false) ;; *) return 1 ;; esac
  [ "$IDA_CONFIG_REGION" = sg ] || return 1
  [ "$IDA_CONFIG_IDENTITY" = user ] || return 1
  [ "$IDA_CONFIG_AGENT_ID" = default ] || fm_ida_numeric_id "$IDA_CONFIG_AGENT_ID" || return 1
  [ "$IDA_CONFIG_MODEL" = default ] || fm_ida_safe_token "$IDA_CONFIG_MODEL" || return 1
  fm_ida_safe_token "$IDA_CONFIG_BYTEDCLI_VERSION" || return 1
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
    and (.error_class == null or (.error_class | type == "string" and length <= 120))
  ' "$file" >/dev/null 2>&1
}
