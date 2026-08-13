#!/usr/bin/env bash
# Shared private-state and configuration primitives for the AIME cloud research
# executor.
#
# Sourced, never executed.
#
# Configuration owner:
#   config/aime-cloud-worker
#
# Required schema:
#   schema=fm-aime-cloud-worker-config.v1
#   enabled=true|false
#   site=<bytedcli site>
#   space_id=<AIME space UUID>
#   identity=user
#   sandbox_verified_version=<exact bytedcli version>
#   sandbox_verified_at=<UTC timestamp>
#   sandbox_verification=disposable-session-readback
#
# `sandbox-verify` in bin/fm-cloud-research-aime.sh is the only supported writer.
# It records enabled=false after one explicitly authorized disposable session
# create plus readback.
# Enabling the feature is a separate local operator action.
# The configuration contains no credential or token.
#
# Per-task state owner:
#   state/cloud-tasks/<task-id>/state.json
#
# State schema fm-aime-task-state.v1 is a discriminated cloud execution record.
# It never contains local worktree, window, harness, backend, endpoint, prompt
# bytes, credential, or token fields.
# Every transition is serialized by a per-task lock and published atomically at
# mode 0600.
set -u

AIME_CONFIG_SCHEMA=fm-aime-cloud-worker-config.v1
AIME_STATE_SCHEMA=fm-aime-task-state.v1
# shellcheck disable=SC2034 # Public constants consumed by scripts that source this library.
AIME_OBSERVATION_SCHEMA=fm-aime-observation.v1
# shellcheck disable=SC2034 # Public constants consumed by scripts that source this library.
AIME_DOCUMENT_SCHEMA=FM_AIME_DOCUMENT_V1

fm_aime_die() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

fm_aime_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

fm_aime_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fm_aime_die "no SHA-256 tool is available"
  fi
}

fm_aime_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_aime_file_links() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_aime_file_owner() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

fm_aime_task_id_valid() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  # The generic process-event source is `aime-<task-id>` and is capped at 64
  # bytes, so the task component must leave room for that provider prefix.
  [ "${#id}" -le 59 ]
}

fm_aime_uuid_valid() {
  local value=${1-}
  local LC_ALL=C
  [[ "$value" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

fm_aime_site_valid() {
  case "${1-}" in
    cn|boe|i18n|i18n-bd|i18n-tt|us-ttp|us-ttp-bdee|us-ttp-usts|eu-ttp|eu-ttp-limited|eu-ttp-full) return 0 ;;
    *) return 1 ;;
  esac
}

fm_aime_config_path() {
  printf '%s/aime-cloud-worker\n' "$CONFIG"
}

fm_aime_task_dir() {
  fm_aime_task_id_valid "$1" || return 1
  printf '%s/cloud-tasks/%s\n' "$STATE" "$1"
}

fm_aime_state_path() {
  printf '%s/state.json\n' "$(fm_aime_task_dir "$1")"
}

fm_aime_task_lock_path() {
  printf '%s/.aime-cloud-%s.lock\n' "$STATE" "$1"
}

fm_aime_source_id() {
  fm_aime_task_id_valid "$1" || return 1
  printf 'aime-%s\n' "$1"
}

fm_aime_config_field() {
  local file=$1 key=$2 count
  count=$(grep -c "^$key=" "$file" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^$key=//p" "$file"
}

fm_aime_config_load() {
  local file mode links owner
  file=$(fm_aime_config_path)
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  mode=$(fm_aime_file_mode "$file") || return 1
  [ "$mode" = 600 ] || return 1
  links=$(fm_aime_file_links "$file") || return 1
  [ "$links" = 1 ] || return 1
  owner=$(fm_aime_file_owner "$file") || return 1
  [ "$owner" = "$(id -u)" ] || return 1
  AIME_CONFIG_SCHEMA_VALUE=$(fm_aime_config_field "$file" schema) || return 1
  AIME_CONFIG_ENABLED=$(fm_aime_config_field "$file" enabled) || return 1
  AIME_CONFIG_SITE=$(fm_aime_config_field "$file" site) || return 1
  AIME_CONFIG_SPACE_ID=$(fm_aime_config_field "$file" space_id) || return 1
  AIME_CONFIG_IDENTITY=$(fm_aime_config_field "$file" identity) || return 1
  AIME_CONFIG_VERIFIED_VERSION=$(fm_aime_config_field "$file" sandbox_verified_version) || return 1
  AIME_CONFIG_VERIFIED_AT=$(fm_aime_config_field "$file" sandbox_verified_at) || return 1
  AIME_CONFIG_VERIFICATION=$(fm_aime_config_field "$file" sandbox_verification) || return 1
  [ "$AIME_CONFIG_SCHEMA_VALUE" = "$AIME_CONFIG_SCHEMA" ] || return 1
  case "$AIME_CONFIG_ENABLED" in true|false) ;; *) return 1 ;; esac
  fm_aime_site_valid "$AIME_CONFIG_SITE" || return 1
  fm_aime_uuid_valid "$AIME_CONFIG_SPACE_ID" || return 1
  [ "$AIME_CONFIG_IDENTITY" = user ] || return 1
  [ -n "$AIME_CONFIG_VERIFIED_VERSION" ] || return 1
  [ -n "$AIME_CONFIG_VERIFIED_AT" ] || return 1
  [ "$AIME_CONFIG_VERIFICATION" = disposable-session-readback ] || return 1
}

fm_aime_config_write_verified() {
  local site=$1 space_id=$2 version=$3 verified_at=$4 file dir tmp
  fm_aime_site_valid "$site" || return 1
  fm_aime_uuid_valid "$space_id" || return 1
  [ -n "$version" ] && [ -n "$verified_at" ] || return 1
  file=$(fm_aime_config_path)
  dir=$(dirname "$file")
  (umask 077; mkdir -p "$dir") || return 1
  [ ! -L "$file" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.aime-config.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$AIME_CONFIG_SCHEMA"
    printf 'enabled=false\n'
    printf 'site=%s\n' "$site"
    printf 'space_id=%s\n' "$space_id"
    printf 'identity=user\n'
    printf 'sandbox_verified_version=%s\n' "$version"
    printf 'sandbox_verified_at=%s\n' "$verified_at"
    printf 'sandbox_verification=disposable-session-readback\n'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}

fm_aime_instruction_validate() {
  local id=$1 file=$2 task_dir resolved_parent expected_parent mode links owner size
  task_dir="$DATA/$id"
  [ -d "$task_dir" ] && [ ! -L "$task_dir" ] \
    || { fm_aime_die "task data directory is missing or unsafe: $task_dir"; return 1; }
  [ -f "$file" ] && [ ! -L "$file" ] \
    || { fm_aime_die "instruction file must be a regular non-symlink: $file"; return 1; }
  resolved_parent=$(CDPATH='' cd -- "$(dirname "$file")" 2>/dev/null && pwd -P) \
    || { fm_aime_die "instruction parent cannot be resolved"; return 1; }
  expected_parent=$(CDPATH='' cd -- "$task_dir" 2>/dev/null && pwd -P) \
    || { fm_aime_die "task data directory cannot be resolved"; return 1; }
  case "$resolved_parent/" in
    "$expected_parent/"*) ;;
    *) fm_aime_die "instruction file must stay under data/$id"; return 1 ;;
  esac
  mode=$(fm_aime_file_mode "$file") \
    || { fm_aime_die "instruction file mode cannot be read"; return 1; }
  case "$mode" in
    600|400) ;;
    *) fm_aime_die "instruction file must have mode 0600 or 0400"; return 1 ;;
  esac
  links=$(fm_aime_file_links "$file") \
    || { fm_aime_die "instruction file link count cannot be read"; return 1; }
  [ "$links" = 1 ] \
    || { fm_aime_die "instruction file must not be hardlinked"; return 1; }
  owner=$(fm_aime_file_owner "$file") \
    || { fm_aime_die "instruction file owner cannot be read"; return 1; }
  [ "$owner" = "$(id -u)" ] \
    || { fm_aime_die "instruction file must be owned by the current user"; return 1; }
  [ -s "$file" ] || { fm_aime_die "instruction file is empty"; return 1; }
  size=$(wc -c < "$file" | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) fm_aime_die "instruction size cannot be read"; return 1 ;;
  esac
  [ "$size" -le "${FM_AIME_MAX_INSTRUCTION_BYTES:-262144}" ] \
    || { fm_aime_die "instruction file exceeds the configured size bound"; return 1; }
}

fm_aime_state_validate_file() {
  local file=$1 mode links owner
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  mode=$(fm_aime_file_mode "$file") || return 1
  [ "$mode" = 600 ] || return 1
  links=$(fm_aime_file_links "$file") || return 1
  [ "$links" = 1 ] || return 1
  owner=$(fm_aime_file_owner "$file") || return 1
  [ "$owner" = "$(id -u)" ] || return 1
  jq -e --arg schema "$AIME_STATE_SCHEMA" '
    .schema == $schema
    and (.task_id | type == "string" and length > 0)
    and .executor == "cloud-worker"
    and .provider == "aime"
    and (.revision | type == "number" and . >= 1 and floor == .)
    and (.phase == "create-not-started"
      or .phase == "create-unknown"
      or .phase == "created"
      or .phase == "send-unknown"
      or .phase == "submitted"
      or .phase == "running"
      or .phase == "result-unavailable"
      or .phase == "terminal-success"
      or .phase == "terminal-failure")
    and (.site | type == "string" and length > 0)
    and (.space_id | type == "string" and length > 0)
    and .identity == "user"
    and (.result_mode == "research" or .result_mode == "document")
    and (.instruction_file | type == "string" and length > 0)
    and (.instruction_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.bytedcli_version | type == "string" and length > 0)
    and (.session_id == null or (.session_id | type == "string" and length > 0))
    and (.message_id == null or (.message_id | type == "string" and length > 0))
    and (.event_cursor | type == "number" and . >= 0 and floor == .)
  ' "$file" >/dev/null 2>&1
}

fm_aime_state_load() {
  local id=$1 file
  file=$(fm_aime_state_path "$id") || return 1
  fm_aime_state_validate_file "$file" || return 1
  [ "$(jq -r '.task_id' "$file")" = "$id" ] || return 1
  # shellcheck disable=SC2034
  AIME_STATE_FILE=$file
  # shellcheck disable=SC2034
  AIME_STATE_PHASE=$(jq -r '.phase' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_OUTCOME=$(jq -r '.outcome // ""' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_SITE=$(jq -r '.site' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_SPACE_ID=$(jq -r '.space_id' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_RESULT_MODE=$(jq -r '.result_mode' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_SESSION_ID=$(jq -r '.session_id // ""' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_MESSAGE_ID=$(jq -r '.message_id // ""' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_CURSOR=$(jq -r '.event_cursor // 0' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_ERROR_CLASS=$(jq -r '.error_class // ""' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_INSTRUCTION_FILE=$(jq -r '.instruction_file' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_INSTRUCTION_SHA256=$(jq -r '.instruction_sha256' "$file")
  # shellcheck disable=SC2034
  AIME_STATE_BYTEDCLI_VERSION=$(jq -r '.bytedcli_version' "$file")
}

fm_aime_state_publish() {
  local id=$1 staged=$2 dir file tmp
  dir=$(fm_aime_task_dir "$id") || return 1
  file=$(fm_aime_state_path "$id") || return 1
  (umask 077; mkdir -p "$dir") || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  [ ! -L "$file" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.state.XXXXXX") || return 1
  cat "$staged" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_aime_state_validate_file "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}

fm_aime_state_initialize() {
  local id=$1 site=$2 space_id=$3 result_mode=$4 instruction_file=$5 instruction_sha=$6 version=$7
  local dir file staged now
  dir=$(fm_aime_task_dir "$id") || return 1
  file=$(fm_aime_state_path "$id") || return 1
  [ ! -e "$file" ] && [ ! -L "$file" ] || return 2
  now=$(fm_aime_now)
  (umask 077; mkdir -p "$dir") || return 1
  staged=$(umask 077; mktemp "$dir/.initialize.XXXXXX") || return 1
  jq -n \
    --arg schema "$AIME_STATE_SCHEMA" \
    --arg task_id "$id" \
    --arg site "$site" \
    --arg space_id "$space_id" \
    --arg result_mode "$result_mode" \
    --arg instruction_file "$instruction_file" \
    --arg instruction_sha256 "$instruction_sha" \
    --arg bytedcli_version "$version" \
    --arg now "$now" \
    '{
      schema:$schema,
      task_id:$task_id,
      executor:"cloud-worker",
      provider:"aime",
      site:$site,
      space_id:$space_id,
      identity:"user",
      result_mode:$result_mode,
      instruction_file:$instruction_file,
      instruction_sha256:$instruction_sha256,
      bytedcli_version:$bytedcli_version,
      phase:"create-not-started",
      outcome:null,
      session_id:null,
      message_id:null,
      event_cursor:0,
      provider_checkpoint:null,
      error_class:null,
      waiter:"not-armed",
      result_path:null,
      report_path:null,
      document:null,
      revision:1,
      created_at:$now,
      updated_at:$now
    }' > "$staged" || { rm -f -- "$staged"; return 1; }
  fm_aime_state_publish "$id" "$staged"
  local rc=$?
  rm -f -- "$staged"
  return "$rc"
}

fm_aime_state_transition() {
  local id=$1 phase=$2 outcome=$3 error_class=$4 session_id=$5 message_id=$6 cursor=$7 checkpoint=$8
  local result_path=${9-} report_path=${10-} waiter=${11-} document_json=${12-}
  local file dir staged now
  file=$(fm_aime_state_path "$id") || return 1
  fm_aime_state_validate_file "$file" || return 1
  dir=$(dirname "$file")
  staged=$(umask 077; mktemp "$dir/.transition.XXXXXX") || return 1
  now=$(fm_aime_now)
  jq \
    --arg phase "$phase" \
    --arg outcome "$outcome" \
    --arg error_class "$error_class" \
    --arg session_id "$session_id" \
    --arg message_id "$message_id" \
    --arg cursor "$cursor" \
    --arg checkpoint "$checkpoint" \
    --arg result_path "$result_path" \
    --arg report_path "$report_path" \
    --arg waiter "$waiter" \
    --arg document_json "$document_json" \
    --arg now "$now" '
      .phase = $phase
      | .outcome = (if $outcome == "" then null else $outcome end)
      | .error_class = (if $error_class == "" then null else $error_class end)
      | (if $session_id == "" then . else .session_id = $session_id end)
      | (if $message_id == "" then . else .message_id = $message_id end)
      | (if $cursor == "" then . else .event_cursor = ($cursor | tonumber) end)
      | (if $checkpoint == "" then . else .provider_checkpoint = $checkpoint end)
      | (if $result_path == "" then . else .result_path = $result_path end)
      | (if $report_path == "" then . else .report_path = $report_path end)
      | (if $waiter == "" then . else .waiter = $waiter end)
      | (if $document_json == "" then . else .document = ($document_json | fromjson) end)
      | .revision += 1
      | .updated_at = $now
    ' "$file" > "$staged" || { rm -f -- "$staged"; return 1; }
  fm_aime_state_publish "$id" "$staged"
  local rc=$?
  rm -f -- "$staged"
  return "$rc"
}

fm_aime_artifact_store() {
  local id=$1 kind=$2 source=$3 dir revision dest tmp source_sha dest_sha
  case "$kind" in
    probe|create|send|replay|session|get-output|observation) ;;
    *) return 1 ;;
  esac
  fm_aime_state_load "$id" || return 1
  revision=$(jq -r '.revision' "$AIME_STATE_FILE")
  dir="$(fm_aime_task_dir "$id")/artifacts"
  (umask 077; mkdir -p "$dir") || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  dest="$dir/${revision}-${kind}.json"
  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    source_sha=$(fm_aime_sha256_file "$source") || return 1
    dest_sha=$(fm_aime_sha256_file "$dest") || return 1
    [ "$source_sha" = "$dest_sha" ] || return 1
    printf '%s\n' "$dest"
    return 0
  fi
  [ ! -e "$dest" ] && [ ! -L "$dest" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.artifact.XXXXXX") || return 1
  cat "$source" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$dest"
}

fm_aime_error_classify() {
  local file=$1 text
  text=$(jq -r '[.error.code?,.error.message?,.error.hint?,.message?] | map(select(type == "string")) | join(" ")' "$file" 2>/dev/null || true)
  [ -n "$text" ] || text=$(head -c 4096 "$file" 2>/dev/null || true)
  case "$(printf '%s' "$text" | tr '[:lower:]' '[:upper:]')" in
    *RATE*LIMIT*|*TOO*MANY*REQUEST*|*HTTP*429*|*QUOTA*) printf 'rate-limited\n' ;;
    *AUTH*|*SSO*|*FORBIDDEN*|*HTTP*401*|*HTTP*403*) printf 'auth\n' ;;
    *UNSUPPORTED*|*NOT*IMPLEMENTED*|*UNKNOWN*COMMAND*) printf 'unsupported\n' ;;
    *TIMEOUT*|*TIMED*OUT*) printf 'timeout\n' ;;
    *NETWORK*|*FETCH*FAILED*|*ECONN*|*UNAVAILABLE*|*HTTP*502*|*HTTP*503*|*HTTP*504*) printf 'unavailable\n' ;;
    *NOT*FOUND*|*HTTP*404*|*4020*) printf 'remote-not-found\n' ;;
    *) printf 'cli-failure\n' ;;
  esac
}

fm_aime_meta_value() {
  local file=$1 key=$2
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_aime_meta_validate() {
  local id=$1 result_mode=$2 file="$STATE/$1.meta" mode links owner key
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  mode=$(fm_aime_file_mode "$file") || return 1
  [ "$mode" = 600 ] || return 1
  links=$(fm_aime_file_links "$file") || return 1
  [ "$links" = 1 ] || return 1
  owner=$(fm_aime_file_owner "$file") || return 1
  [ "$owner" = "$(id -u)" ] || return 1
  for key in kind executor provider task_type cloud_state; do
    [ "$(grep -c "^$key=" "$file" 2>/dev/null || true)" -eq 1 ] || return 1
  done
  [ "$(fm_aime_meta_value "$file" kind)" = scout ] || return 1
  [ "$(fm_aime_meta_value "$file" executor)" = cloud-worker ] || return 1
  [ "$(fm_aime_meta_value "$file" provider)" = aime ] || return 1
  [ "$(fm_aime_meta_value "$file" task_type)" = "$result_mode" ] || return 1
  [ "$(fm_aime_meta_value "$file" cloud_state)" = "$(fm_aime_task_dir "$id")" ] || return 1
  ! grep -Eq '^(window|worktree|harness|backend|endpoint_task_id)=' "$file"
}

fm_aime_meta_write() {
  local id=$1 result_mode=$2 cloud_dir meta tmp
  meta="$STATE/$id.meta"
  cloud_dir=$(fm_aime_task_dir "$id") || return 1
  [ ! -e "$meta" ] && [ ! -L "$meta" ] || return 2
  (umask 077; mkdir -p "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.aime-meta.XXXXXX") || return 1
  {
    printf 'kind=scout\n'
    printf 'executor=cloud-worker\n'
    printf 'provider=aime\n'
    printf 'task_type=%s\n' "$result_mode"
    printf 'cloud_state=%s\n' "$cloud_dir"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ln "$tmp" "$meta" 2>/dev/null; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    return 2
  fi
  return 1
}

fm_aime_status_append() {
  local id=$1 line=$2 file
  file="$STATE/$id.status"
  (umask 077; mkdir -p "$STATE") || return 1
  [ ! -L "$file" ] || return 1
  printf '%s\n' "$line" >> "$file"
  chmod 0600 "$file" 2>/dev/null || true
}
