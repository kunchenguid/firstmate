#!/usr/bin/env bash
# Shared durable schema and state-machine primitives for native remote agents.
#
# Sourced, never executed. Provider adapters own provider commands and response
# interpretation. This file owns the new executor=remote-agent metadata shape,
# the normalized state phases, private-file boundaries, and atomic publication.
#
# New metadata schema (state/<task-id>.meta):
#   kind=scout
#   executor=remote-agent
#   provider=aime|ida
#   task_type=research|document
#   remote_state=<absolute state/remote-tasks/<task-id> path>
#
# New state schema: fm-remote-agent-task-state.v1. Its normalized phases are:
#   submission-not-started, submission-unknown, submitted, running,
#   result-unavailable, ambiguous, terminal-success, terminal-failure, and
#   terminal-cancelled. Provider identity and checkpoints live in the bounded
#   provider_state object. Prompt bytes, credentials, tokens, and raw streams
#   are forbidden from both metadata and state.
# generation starts at 1 (also the legacy default); a followup atomically
# freezes the old state under generations/<generation>.json, then advances it.
# The provider-specific parent/action/turn bindings belong to fm-ida-remote-lib.
#
# Existing executor=cloud-worker/provider=aime metadata and
# fm-aime-task-state.v1 records are a permanent read-compatibility path. They
# stay owned by fm-aime-cloud-lib.sh and are never rewritten or migrated here.
set -u

FM_REMOTE_STATE_SCHEMA=fm-remote-agent-task-state.v1

fm_remote_die() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

fm_remote_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

fm_remote_task_id_valid() {
  local id=${1-} LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  # Process-event source ids add "aime-" or "ida-" and are capped at 64.
  [ "${#id}" -le 59 ]
}

fm_remote_provider_valid() {
  case "${1-}" in aime|ida) return 0 ;; *) return 1 ;; esac
}

fm_remote_phase_valid() {
  case "${1-}" in
    submission-not-started|submission-unknown|submitted|running|result-unavailable|ambiguous|terminal-success|terminal-failure|terminal-cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

fm_remote_phase_current_state() {
  case "${1-}" in
    submitted|running) printf 'working\n' ;;
    submission-not-started|submission-unknown|result-unavailable|ambiguous) printf 'blocked\n' ;;
    terminal-success) printf 'done\n' ;;
    terminal-failure|terminal-cancelled) printf 'failed\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

fm_remote_file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi
}

fm_remote_file_links() {
  if [ "$(uname)" = Darwin ]; then stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}

fm_remote_file_owner() {
  if [ "$(uname)" = Darwin ]; then stat -f %u "$1" 2>/dev/null; else stat -c %u "$1" 2>/dev/null; fi
}

fm_remote_private_file_safe() {
  local file=$1 mode links owner
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  mode=$(fm_remote_file_mode "$file") || return 1
  [ "$mode" = 600 ] || return 1
  links=$(fm_remote_file_links "$file") || return 1
  [ "$links" = 1 ] || return 1
  owner=$(fm_remote_file_owner "$file") || return 1
  [ "$owner" = "$(id -u)" ]
}

fm_remote_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fm_remote_die "no SHA-256 tool is available"
  fi
}

fm_remote_task_dir() {
  fm_remote_task_id_valid "$1" || return 1
  printf '%s/remote-tasks/%s\n' "$STATE" "$1"
}

fm_remote_state_path() { printf '%s/state.json\n' "$(fm_remote_task_dir "$1")"; }
fm_remote_task_lock_path() { printf '%s/.remote-agent-%s.lock\n' "$STATE" "$1"; }

fm_remote_source_id() {
  fm_remote_provider_valid "$1" && fm_remote_task_id_valid "$2" || return 1
  printf '%s-%s\n' "$1" "$2"
}

fm_remote_report_path() {
  fm_remote_task_id_valid "$1" || return 1
  printf '%s/%s/report.md\n' "$DATA" "$1"
}

fm_remote_report_safe() {
  local report
  report=$(fm_remote_report_path "$1") || return 1
  fm_remote_private_file_safe "$report"
}

fm_remote_report_replaceable() {
  local report
  report=$(fm_remote_report_path "$1") || return 1
  if [ -e "$report" ] || [ -L "$report" ]; then
    fm_remote_private_file_safe "$report"
  else
    return 0
  fi
}

fm_remote_instruction_validate() {
  local id=$1 file=$2 task_dir resolved_parent expected_parent mode links owner size
  task_dir="$DATA/$id"
  [ -d "$task_dir" ] && [ ! -L "$task_dir" ] \
    || { fm_remote_die "task data directory is missing or unsafe: $task_dir"; return 1; }
  [ -f "$file" ] && [ ! -L "$file" ] \
    || { fm_remote_die "instruction file must be a regular non-symlink: $file"; return 1; }
  resolved_parent=$(CDPATH='' cd -- "$(dirname "$file")" 2>/dev/null && pwd -P) \
    || { fm_remote_die "instruction parent cannot be resolved"; return 1; }
  expected_parent=$(CDPATH='' cd -- "$task_dir" 2>/dev/null && pwd -P) \
    || { fm_remote_die "task data directory cannot be resolved"; return 1; }
  case "$resolved_parent/" in "$expected_parent/"*) ;; *) fm_remote_die "instruction file must stay under data/$id"; return 1 ;; esac
  mode=$(fm_remote_file_mode "$file") || return 1
  case "$mode" in 600|400) ;; *) fm_remote_die "instruction file must have mode 0600 or 0400"; return 1 ;; esac
  links=$(fm_remote_file_links "$file") || return 1
  [ "$links" = 1 ] || { fm_remote_die "instruction file must not be hardlinked"; return 1; }
  owner=$(fm_remote_file_owner "$file") || return 1
  [ "$owner" = "$(id -u)" ] || { fm_remote_die "instruction file must be owned by the current user"; return 1; }
  [ -s "$file" ] || { fm_remote_die "instruction file is empty"; return 1; }
  size=$(wc -c < "$file" | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$size" -le "${FM_REMOTE_MAX_INSTRUCTION_BYTES:-262144}" ] \
    || { fm_remote_die "instruction file exceeds the configured size bound"; return 1; }
}

fm_remote_state_validate_file() {
  local file=$1
  fm_remote_private_file_safe "$file" || return 1
  jq -e --arg schema "$FM_REMOTE_STATE_SCHEMA" '
    .schema == $schema
    and (.task_id | type == "string" and length > 0)
    and .executor == "remote-agent"
    and (.provider == "aime" or .provider == "ida")
    and (.task_type == "research" or .task_type == "document")
    and (.phase == "submission-not-started"
      or .phase == "submission-unknown"
      or .phase == "submitted"
      or .phase == "running"
      or .phase == "result-unavailable"
      or .phase == "ambiguous"
      or .phase == "terminal-success"
      or .phase == "terminal-failure"
      or .phase == "terminal-cancelled")
    and (.revision | type == "number" and . >= 1 and floor == .)
    and ((has("generation") | not) or (.generation | type=="number" and .>=1 and .<=9007199254740991 and floor==.))
    and (.instruction_file | type == "string" and length > 0)
    and (.instruction_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and ((has("bytedcli_version") | not)
      or (.bytedcli_version | type == "string"))
    and (.outcome == null or (.outcome | type == "string" and length > 0))
    and (.error_class == null or (.error_class | type == "string" and length > 0))
    and (.waiter == "not-armed" or .waiter == "armed" or .waiter == "rearming" or .waiter == "interrupted" or .waiter == "terminal")
    and (.result_availability == null or .result_availability == "available" or .result_availability == "zero" or .result_availability == "unavailable" or .result_availability == "error")
    and (.result_path == null or (.result_path | type == "string" and length > 0))
    and (.report_path == null or (.report_path | type == "string" and length > 0))
    and (.provider_state | type == "object")
  ' "$file" >/dev/null 2>&1
}

fm_remote_state_load() {
  local id=$1 file
  file=$(fm_remote_state_path "$id") || return 1
  fm_remote_state_validate_file "$file" || return 1
  [ "$(jq -r '.task_id' "$file")" = "$id" ] || return 1
  REMOTE_STATE_FILE=$file
  # shellcheck disable=SC2034 # Public values consumed by scripts that source this library.
  REMOTE_STATE_PROVIDER=$(jq -r '.provider' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_TASK_TYPE=$(jq -r '.task_type' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_PHASE=$(jq -r '.phase' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_OUTCOME=$(jq -r '.outcome // ""' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_ERROR_CLASS=$(jq -r '.error_class // ""' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_WAITER=$(jq -r '.waiter' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_RESULT_AVAILABILITY=$(jq -r '.result_availability // ""' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_RESULT_PATH=$(jq -r '.result_path // ""' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_REPORT_PATH=$(jq -r '.report_path // ""' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_PROVIDER_CHECKPOINT=$(jq -r '.provider_checkpoint // ""' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_INSTRUCTION_FILE=$(jq -r '.instruction_file' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_INSTRUCTION_SHA256=$(jq -r '.instruction_sha256' "$file")
  # shellcheck disable=SC2034
  REMOTE_STATE_BYTEDCLI_VERSION=$(jq -r '.bytedcli_version // ""' "$file")
}

fm_remote_state_publish() {
  local id=$1 staged=$2 dir file tmp
  dir=$(fm_remote_task_dir "$id") || return 1
  file=$(fm_remote_state_path "$id") || return 1
  (umask 077; mkdir -p "$dir") || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  [ ! -L "$file" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.state.XXXXXX") || return 1
  cp "$staged" "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_remote_state_validate_file "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}

fm_remote_state_initialize() {
  local id=$1 provider=$2 task_type=$3 instruction_file=$4 instruction_sha=$5 provider_state=$6
  local dir file staged now
  fm_remote_provider_valid "$provider" || return 1
  case "$task_type" in research|document) ;; *) return 1 ;; esac
  printf '%s' "$provider_state" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  dir=$(fm_remote_task_dir "$id") || return 1
  file=$(fm_remote_state_path "$id") || return 1
  [ ! -e "$file" ] && [ ! -L "$file" ] || return 2
  (umask 077; mkdir -p "$dir") || return 1
  staged=$(umask 077; mktemp "$dir/.initialize.XXXXXX") || return 1
  now=$(fm_remote_now)
  jq -n \
    --arg schema "$FM_REMOTE_STATE_SCHEMA" --arg task_id "$id" --arg provider "$provider" \
    --arg task_type "$task_type" --arg instruction_file "$instruction_file" \
    --arg instruction_sha256 "$instruction_sha" \
    --argjson provider_state "$provider_state" --arg now "$now" '
      {schema:$schema,task_id:$task_id,executor:"remote-agent",provider:$provider,task_type:$task_type,
       instruction_file:$instruction_file,instruction_sha256:$instruction_sha256,
       phase:"submission-not-started",outcome:null,error_class:null,provider_checkpoint:"dispatch-durable",
       waiter:"not-armed",result_availability:null,result_path:null,report_path:null,provider_state:$provider_state,
       generation:1,revision:1,created_at:$now,updated_at:$now}' >"$staged" || { rm -f -- "$staged"; return 1; }
  fm_remote_state_publish "$id" "$staged"
  local rc=$?
  rm -f -- "$staged"
  return "$rc"
}

# Freeze the old terminal execution before publishing a new, independently
# identified provider turn. Caller holds the task meta and provider locks.
# The provider adapter supplies the new provider identity; this owner never
# creates a remote request and never re-labels the previous terminal record.
fm_remote_state_begin_followup() { # <task> <expected-generation> <instructions> <sha> <provider-state-json>
  local id=$1 generation=$2 instructions=$3 sha=$4 provider=$5 dir snapshot staged
  fm_remote_state_load "$id" || return 1
  [ "$(jq -r '.generation // 1' "$REMOTE_STATE_FILE")" = "$generation" ] || return 1
  case "$REMOTE_STATE_PHASE" in terminal-success|terminal-failure|terminal-cancelled) ;; *) return 1 ;; esac
  dir=$(fm_remote_task_dir "$id") || return 1
  mkdir -p "$dir/generations" || return 1
  [ ! -L "$dir/generations" ] || return 1
  snapshot="$dir/generations/$generation.json"
  staged=$(umask 077; mktemp "$dir/generations/.terminal.XXXXXX") || return 1
  jq --arg report "$(printf '%s' "$provider" | jq -r '.parent_report_ref // ""')" \
    'if $report!="" then .report_path=$report else . end' "$REMOTE_STATE_FILE" > "$staged" || { rm -f "$staged"; return 1; }
  if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
    if ! fm_remote_private_file_safe "$snapshot" || ! cmp -s "$snapshot" "$staged"; then rm -f "$staged"; return 1; fi
    rm -f "$staged"
  else
    mv "$staged" "$snapshot" || return 1
  fi
  staged=$(umask 077; mktemp "$dir/.followup.XXXXXX") || return 1
  jq --arg instruction "$instructions" --arg sha "$sha" --argjson provider "$provider" '
    .generation=((.generation // 1)+1) | .revision+=1 | .instruction_file=$instruction | .instruction_sha256=$sha
    | .phase="submission-unknown" | .outcome="followup-submission-unconfirmed" | .error_class=null
    | .provider_checkpoint="followup-attempted" | .waiter="not-armed"
    | .result_availability=null | .result_path=null | .report_path=null | .provider_state=$provider
  ' "$snapshot" > "$staged" && fm_remote_state_publish "$id" "$staged"
  local rc=$?
  rm -f "$staged"
  return "$rc"
}

fm_remote_state_transition() {
  local id=$1 phase=$2 outcome=$3 error_class=$4 checkpoint=$5 waiter=$6 availability=$7
  local result_path=$8 report_path=$9 provider_patch file dir staged now
  provider_patch=${10:-"{}"}
  fm_remote_phase_valid "$phase" || return 1
  case "$waiter" in not-armed|armed|rearming|interrupted|terminal) ;; *) return 1 ;; esac
  case "$availability" in ''|available|zero|unavailable|error) ;; *) return 1 ;; esac
  printf '%s' "$provider_patch" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  file=$(fm_remote_state_path "$id") || return 1
  fm_remote_state_validate_file "$file" || return 1
  dir=$(dirname "$file")
  staged=$(umask 077; mktemp "$dir/.transition.XXXXXX") || return 1
  now=$(fm_remote_now)
  jq --arg phase "$phase" --arg outcome "$outcome" --arg error_class "$error_class" \
    --arg checkpoint "$checkpoint" --arg waiter "$waiter" --arg availability "$availability" \
    --arg result_path "$result_path" --arg report_path "$report_path" \
    --argjson provider_patch "$provider_patch" --arg now "$now" '
      .phase=$phase
      | .outcome=(if $outcome == "" then null else $outcome end)
      | .error_class=(if $error_class == "" then null else $error_class end)
      | .provider_checkpoint=(if $checkpoint == "" then .provider_checkpoint else $checkpoint end)
      | .waiter=$waiter
      | .result_availability=(if $availability == "" then null else $availability end)
      | .result_path=(if $result_path == "" then .result_path else $result_path end)
      | .report_path=(if $report_path == "" then .report_path else $report_path end)
      | .provider_state=(.provider_state + $provider_patch)
      | .revision += 1 | .updated_at=$now' "$file" >"$staged" || { rm -f -- "$staged"; return 1; }
  fm_remote_state_publish "$id" "$staged"
  local rc=$?
  rm -f -- "$staged"
  return "$rc"
}

fm_remote_artifact_store() {
  local id=$1 kind=$2 source=$3 dir revision dest tmp source_sha dest_sha
  case "$kind" in observation|submission|session|result|cancel|reconcile|error) ;; *) return 1 ;; esac
  fm_remote_state_load "$id" || return 1
  revision=$(jq -r '.revision' "$REMOTE_STATE_FILE")
  dir="$(fm_remote_task_dir "$id")/artifacts"
  (umask 077; mkdir -p "$dir") || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  dest="$dir/${revision}-${kind}.json"
  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    source_sha=$(fm_remote_sha256_file "$source") || return 1
    dest_sha=$(fm_remote_sha256_file "$dest") || return 1
    [ "$source_sha" = "$dest_sha" ] || return 1
    printf '%s\n' "$dest"
    return 0
  fi
  [ ! -e "$dest" ] && [ ! -L "$dest" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.artifact.XXXXXX") || return 1
  cp "$source" "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$dest"
}

fm_remote_meta_value() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

fm_remote_meta_validate() {
  local id=$1 provider=$2 task_type=$3 file="$STATE/$1.meta" key
  fm_remote_private_file_safe "$file" || return 1
  for key in kind executor provider task_type remote_state; do
    [ "$(grep -c "^$key=" "$file" 2>/dev/null || true)" -eq 1 ] || return 1
  done
  [ "$(fm_remote_meta_value "$file" kind)" = scout ] || return 1
  [ "$(fm_remote_meta_value "$file" executor)" = remote-agent ] || return 1
  [ "$(fm_remote_meta_value "$file" provider)" = "$provider" ] || return 1
  [ "$(fm_remote_meta_value "$file" task_type)" = "$task_type" ] || return 1
  [ "$(fm_remote_meta_value "$file" remote_state)" = "$(fm_remote_task_dir "$id")" ] || return 1
  ! grep -Eq '^(window|worktree|harness|backend|endpoint_task_id)=' "$file"
}

fm_remote_meta_write() {
  local id=$1 provider=$2 task_type=$3 remote_dir meta tmp
  remote_dir=$(fm_remote_task_dir "$id") || return 1
  meta="$STATE/$id.meta"
  [ ! -e "$meta" ] && [ ! -L "$meta" ] || return 2
  (umask 077; mkdir -p "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.remote-meta.XXXXXX") || return 1
  {
    printf 'kind=scout\nexecutor=remote-agent\nprovider=%s\ntask_type=%s\nremote_state=%s\n' \
      "$provider" "$task_type" "$remote_dir"
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ln "$tmp" "$meta" 2>/dev/null; then rm -f -- "$tmp"; return 0; fi
  rm -f -- "$tmp"
  [ -e "$meta" ] || [ -L "$meta" ] && return 2
  return 1
}

fm_remote_status_append() {
  local id=$1 line=$2 file
  file="$STATE/$id.status"
  (umask 077; mkdir -p "$STATE") || return 1
  if ! declare -F fm_wake_status_append >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
  fi
  fm_wake_status_append "$STATE" "$file" "$line"
}

fm_remote_error_classify() {
  local file=$1 text
  text=$(jq -r '[.error.code?,.error.message?,.error.hint?,.message?] | map(select(type == "string")) | join(" " )' "$file" 2>/dev/null || true)
  [ -n "$text" ] || text=$(head -c 4096 "$file" 2>/dev/null || true)
  case "$(printf '%s' "$text" | tr '[:lower:]' '[:upper:]')" in
    *RATE*LIMIT*|*TOO*MANY*REQUEST*|*HTTP*429*|*QUOTA*) printf 'rate-limited\n' ;;
    *AUTH*|*SSO*|*FORBIDDEN*|*HTTP*401*|*HTTP*403*) printf 'auth\n' ;;
    *UNSUPPORTED*|*NOT*IMPLEMENTED*|*UNKNOWN*COMMAND*) printf 'unsupported\n' ;;
    *TIMEOUT*|*TIMED*OUT*) printf 'timeout\n' ;;
    *NETWORK*|*FETCH*FAILED*|*ECONN*|*UNAVAILABLE*|*HTTP*502*|*HTTP*503*|*HTTP*504*) printf 'unavailable\n' ;;
    *NOT*FOUND*|*HTTP*404*) printf 'remote-not-found\n' ;;
    *) printf 'provider-error\n' ;;
  esac
}

# Reduce an iDA final answer before it crosses the provider adapter's stdout
# boundary. The complete provider/session payload remains private temporary
# input; only this bounded, best-effort redacted final text may become a
# process-event result or report. This deliberately targets credential and
# identifier shapes rather than rewriting ordinary research prose.
fm_remote_redact_result_text() {
  local max=${FM_REMOTE_RESULT_MAX_CHARS:-131072}
  local prompt_file=${1-}
  case "$max" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$max" -le 1048576 ] || return 1
  FM_REMOTE_REDACT_MAX="$max" FM_REMOTE_REDACT_PROMPT_FILE="$prompt_file" perl -CSDA -0777 -pe '
    BEGIN {
      my $path = $ENV{FM_REMOTE_REDACT_PROMPT_FILE} // "";
      if (length($path) && open(my $fh, "<", $path)) {
        local $/; $prompt = <$fh>; close($fh); $prompt =~ s/\s+\z// if defined $prompt;
      }
    }
    s/\Q$prompt\E/[REDACTED PRIVATE PROMPT]/g if defined($prompt) && length($prompt);
    s/-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----/[REDACTED PRIVATE KEY]/gsi;
    s/\bBearer\s+[A-Za-z0-9._~+\/=:-]+/Bearer [REDACTED]/gi;
    s/\b((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|oecid)\s*[:=]\s*)[^\s,;]+/$1[REDACTED]/gi;
    s/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?\b/[REDACTED TOKEN]/g;
    s/\b[A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/[REDACTED EMAIL]/g;
    s/\b[0-9]{15,20}\b/[REDACTED LONG ID]/g;
    s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
    $_ = substr($_, 0, $ENV{FM_REMOTE_REDACT_MAX});
  '
}
