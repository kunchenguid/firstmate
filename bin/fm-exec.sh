#!/usr/bin/env bash
# fm-exec.sh - run task-scoped commands through the task's recorded executor.
#
# Usage:
#   fm-exec.sh <task-id> check
#   fm-exec.sh <task-id> run [--lease <opaque-id>] -- <argv...>
#   fm-exec.sh <task-id> inspect
#   fm-exec.sh <task-id> logs <opaque-run-id>
#   fm-exec.sh <task-id> release
#
# The canonical state/<task-id>.meta selects the executor.  Its absence means
# local execution; a Crabbox task records executor=crabbox and one nonempty
# executor_profile=.  Every state mutation takes the existing metadata lock,
# validates the canonical metadata and private artifacts, and writes only
# task-scoped private records.  The execution journal intentionally excludes
# argv, environment, credentials, and command output.  Crabbox's provider JSON
# is stored verbatim only after JSON validation, so the provider remains the
# authority for cost and expiry.
set -u

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  printf 'fm-exec: state directory is unavailable or symlinked: %s\n' "$STATE" >&2
  exit 1
}
STATE="$(CDPATH='' cd "$STATE" && pwd -P)" || {
  printf 'fm-exec: state directory cannot be resolved\n' >&2
  exit 1
}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-command-execution.sh
. "$SCRIPT_DIR/fm-command-execution.sh"

FM_EXEC_LOCK=
FM_EXEC_LOCK_HELD=0
FM_EXEC_STATE_DEVICE=
FM_EXEC_META=
FM_EXEC_JOURNAL=
FM_EXEC_SNAPSHOT=
FM_EXEC_TASK_ID=
FM_EXEC_CWD=
FM_EXEC_EXECUTOR=
FM_EXEC_PROFILE=

fm_exec_die() {
  printf 'fm-exec: %s\n' "$*" >&2
  exit 1
}

fm_exec_cleanup() {
  if [ "$FM_EXEC_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$FM_EXEC_LOCK" || true
  fi
}
trap fm_exec_cleanup EXIT

fm_exec_timestamp() {
  LC_ALL=C TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ'
}

fm_exec_opaque_valid() {
  local value=${1-}
  [ -n "$value" ] || return 1
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
}

fm_exec_private_artifact_valid_or_absent() {  # <path>
  local path=$1
  [ ! -L "$path" ] || return 1
  [ ! -e "$path" ] && return 0
  fm_pr_private_file_valid "$path" 600 "$FM_EXEC_STATE_DEVICE"
}

fm_exec_require_state() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] \
    || fm_exec_die "state directory is unavailable or symlinked: $STATE"
  STATE=$(CDPATH='' cd "$STATE" && pwd -P) \
    || fm_exec_die "state directory cannot be resolved"
  FM_EXEC_STATE_DEVICE=$(fm_pr_file_device "$STATE") \
    || fm_exec_die "cannot read state directory device"
  [ -n "$FM_EXEC_STATE_DEVICE" ] \
    || fm_exec_die "state directory has no device identity"
}

fm_exec_exact_meta_value() {  # <key> <required: 0|1>
  local key=$1 required=$2 count value
  count=$(grep -c "^$key=" "$FM_EXEC_META" 2>/dev/null || true)
  case "$count:$required" in
    0:0) printf '' ; return 0 ;;
    1:*) ;;
    *) return 1 ;;
  esac
  value=$(grep "^$key=" "$FM_EXEC_META" | cut -d= -f2-)
  if [ "$required" = 1 ] && [ -z "$value" ]; then
    return 1
  fi
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  printf '%s' "$value"
}

fm_exec_require_metadata() {
  local binding_count binding executor_count profile_count
  FM_EXEC_META="$STATE/$FM_EXEC_TASK_ID.meta"
  [ -f "$FM_EXEC_META" ] && [ ! -L "$FM_EXEC_META" ] \
    || fm_exec_die "task metadata is unavailable: $FM_EXEC_META"
  [ "$(fm_pr_file_link_count "$FM_EXEC_META")" = 1 ] \
    || fm_exec_die "task metadata has ambiguous ownership"
  [ "$(fm_pr_file_device "$FM_EXEC_META")" = "$FM_EXEC_STATE_DEVICE" ] \
    || fm_exec_die "task metadata is on a different device from canonical state"

  FM_EXEC_CWD=$(fm_exec_exact_meta_value worktree 1) \
    || fm_exec_die "task metadata has missing, empty, or duplicate worktree"
  [ -d "$FM_EXEC_CWD" ] && [ ! -L "$FM_EXEC_CWD" ] \
    || fm_exec_die "task worktree is unavailable or symlinked"
  local physical_cwd
  physical_cwd=$(CDPATH='' cd "$FM_EXEC_CWD" && pwd -P) \
    || fm_exec_die "task worktree cannot be resolved"
  [ "$FM_EXEC_CWD" = "$physical_cwd" ] \
    || fm_exec_die "task worktree is not a canonical physical path"

  binding_count=$(grep -c '^endpoint_task_id=' "$FM_EXEC_META" 2>/dev/null || true)
  case "$binding_count" in
    0) ;;
    1)
      binding=$(fm_exec_exact_meta_value endpoint_task_id 1) \
        || fm_exec_die "task metadata has an invalid endpoint task binding"
      [ "$binding" = "$FM_EXEC_TASK_ID" ] \
        || fm_exec_die "task metadata belongs to endpoint task $binding, not $FM_EXEC_TASK_ID"
      ;;
    *) fm_exec_die "task metadata has a duplicate endpoint task binding" ;;
  esac

  executor_count=$(grep -c '^executor=' "$FM_EXEC_META" 2>/dev/null || true)
  profile_count=$(grep -c '^executor_profile=' "$FM_EXEC_META" 2>/dev/null || true)
  case "$executor_count:$profile_count" in
    0:0)
      FM_EXEC_EXECUTOR=local
      FM_EXEC_PROFILE=
      ;;
    1:1)
      FM_EXEC_EXECUTOR=$(fm_exec_exact_meta_value executor 1) \
        || fm_exec_die "task metadata has an invalid executor"
      FM_EXEC_PROFILE=$(fm_exec_exact_meta_value executor_profile 1) \
        || fm_exec_die "task metadata has an invalid executor profile"
      [ "$FM_EXEC_EXECUTOR" = crabbox ] \
        || fm_exec_die "task metadata has unsupported executor '$FM_EXEC_EXECUTOR'"
      ;;
    0:*)
      fm_exec_die "local task metadata must not carry an executor profile"
      ;;
    *)
      fm_exec_die "task metadata has missing or duplicate executor fields"
      ;;
  esac

  FM_EXEC_JOURNAL="$STATE/$FM_EXEC_TASK_ID.execution"
  FM_EXEC_SNAPSHOT="$STATE/$FM_EXEC_TASK_ID.execution-provider.json"
  fm_exec_private_artifact_valid_or_absent "$FM_EXEC_JOURNAL" \
    || fm_exec_die "task execution journal is unsafe"
  fm_exec_private_artifact_valid_or_absent "$FM_EXEC_SNAPSHOT" \
    || fm_exec_die "task provider snapshot is unsafe"
}

fm_exec_lock_metadata() {
  FM_EXEC_LOCK=$(fm_meta_lock_path "$FM_EXEC_META") \
    || fm_exec_die "cannot resolve task metadata lock"
  if ! fm_lock_try_acquire "$FM_EXEC_LOCK"; then
    fm_exec_die "task execution mutation is already in progress"
  fi
  FM_EXEC_LOCK_HELD=1
  fm_exec_require_metadata
}

fm_exec_validate_journal() {
  [ -e "$FM_EXEC_JOURNAL" ] || return 0
  jq -s -e --arg task "$FM_EXEC_TASK_ID" '
    all(.[];
      type == "object"
      and .schema == "fm-execution-record.v1"
      and .task == $task
      and (.executor == "local" or .executor == "crabbox")
      and (.profile == null or (.profile | type == "string" and length > 0))
      and (.lease == null or (.lease | type == "string" and length > 0))
      and (.run_id == null or (.run_id | type == "string" and length > 0))
      and (.event == "run-start" or .event == "run-finish" or .event == "release")
      and (.started_at == null or (.started_at | type == "string" and length > 0))
      and (.finished_at == null or (.finished_at | type == "string" and length > 0))
      and (.exit_code == null or (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255))
    )
  ' "$FM_EXEC_JOURNAL" >/dev/null 2>&1
}

fm_exec_append_record() {  # <event> <executor> <profile> <lease> <run-id> <started> <finished> <exit-code-or-empty>
  local event=$1 executor=$2 profile=$3 lease=$4 run_id=$5 started=$6 finished=$7 exit_code=$8 tmp record
  fm_exec_validate_journal || fm_exec_die "task execution journal is malformed"
  fm_exec_private_artifact_valid_or_absent "$FM_EXEC_JOURNAL" \
    || fm_exec_die "task execution journal is unsafe"
  tmp=$(mktemp "$STATE/.fm-exec-record.XXXXXX") \
    || fm_exec_die "cannot allocate an execution record transaction"
  chmod 600 "$tmp" || { rm -f "$tmp"; fm_exec_die "cannot secure execution record transaction"; }
  if [ -e "$FM_EXEC_JOURNAL" ]; then
    cat "$FM_EXEC_JOURNAL" > "$tmp" || { rm -f "$tmp"; fm_exec_die "cannot read execution journal"; }
  fi
  record=$(jq -cn \
    --arg event "$event" --arg task "$FM_EXEC_TASK_ID" --arg executor "$executor" \
    --arg profile "$profile" --arg lease "$lease" --arg run_id "$run_id" \
    --arg started "$started" --arg finished "$finished" --arg exit_code "$exit_code" '
      {
        schema: "fm-execution-record.v1",
        event: $event,
        task: $task,
        executor: $executor,
        profile: (if $profile == "" then null else $profile end),
        lease: (if $lease == "" then null else $lease end),
        run_id: (if $run_id == "" then null else $run_id end),
        started_at: (if $started == "" then null else $started end),
        finished_at: (if $finished == "" then null else $finished end),
        exit_code: (if $exit_code == "" then null else ($exit_code | tonumber) end)
      }') || { rm -f "$tmp"; fm_exec_die "cannot encode execution record"; }
  printf '%s\n' "$record" >> "$tmp" || { rm -f "$tmp"; fm_exec_die "cannot append execution record"; }
  [ "$(fm_pr_file_device "$tmp")" = "$FM_EXEC_STATE_DEVICE" ] \
    || { rm -f "$tmp"; fm_exec_die "execution record transaction crossed devices"; }
  fm_exec_private_artifact_valid_or_absent "$FM_EXEC_JOURNAL" \
    || { rm -f "$tmp"; fm_exec_die "task execution journal changed unexpectedly"; }
  mv -f "$tmp" "$FM_EXEC_JOURNAL" \
    || { rm -f "$tmp"; fm_exec_die "cannot commit execution record"; }
  fm_exec_private_artifact_valid_or_absent "$FM_EXEC_JOURNAL" \
    || fm_exec_die "committed execution journal is unsafe"
}

fm_exec_unreleased_lease() {
  [ -e "$FM_EXEC_JOURNAL" ] || return 1
  fm_exec_validate_journal || return 1
  jq -ers '
    reduce .[] as $record
      (null;
        if $record.event == "run-start" and ($record.lease | type == "string") then
          $record.lease
        elif $record.event == "release"
          and ($record.lease | type == "string")
          and $record.exit_code == 0
          and . == $record.lease then
          null
        else
          .
        end) // empty
  ' "$FM_EXEC_JOURNAL"
}

fm_exec_run_id() {
  local now pid nonce
  now=$(date +%s) || return 1
  pid=${BASHPID:-$$}
  nonce=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return 1
  case "$now:$pid:$nonce" in *[!0-9a-f:]*|*::*) return 1 ;; esac
  printf 'run-%s-%s-%s\n' "$now" "$pid" "$nonce"
}

fm_exec_store_snapshot() {
  local handle=$1 tmp status
  command -v jq >/dev/null 2>&1 || fm_exec_die "jq is required to validate provider JSON"
  tmp=$(mktemp "$STATE/.fm-exec-provider.XXXXXX") \
    || fm_exec_die "cannot allocate provider snapshot transaction"
  chmod 600 "$tmp" || { rm -f "$tmp"; fm_exec_die "cannot secure provider snapshot transaction"; }
  if fm_command_execution_inspect "$FM_EXEC_EXECUTOR" "$handle" > "$tmp"; then
    :
  else
    status=$?
    rm -f "$tmp"
    return "$status"
  fi
  if ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fm_exec_die "provider inspect did not return a JSON object"
  fi
  [ "$(fm_pr_file_device "$tmp")" = "$FM_EXEC_STATE_DEVICE" ] \
    || { rm -f "$tmp"; fm_exec_die "provider snapshot transaction crossed devices"; }
  fm_exec_private_artifact_valid_or_absent "$FM_EXEC_SNAPSHOT" \
    || { rm -f "$tmp"; fm_exec_die "task provider snapshot changed unexpectedly"; }
  mv -f "$tmp" "$FM_EXEC_SNAPSHOT" \
    || { rm -f "$tmp"; fm_exec_die "cannot commit provider snapshot"; }
  fm_exec_private_artifact_valid_or_absent "$FM_EXEC_SNAPSHOT" \
    || fm_exec_die "committed provider snapshot is unsafe"
  cat "$FM_EXEC_SNAPSHOT"
}

[ "$#" -ge 2 ] || fm_exec_die "usage: fm-exec.sh <task-id> check|run|inspect|logs|release"
FM_EXEC_TASK_ID=$1
COMMAND=$2
shift 2
fm_task_id_creation_valid "$FM_EXEC_TASK_ID" \
  || fm_exec_die "invalid task id '$FM_EXEC_TASK_ID'"
fm_exec_require_state
fm_exec_require_metadata

case "$COMMAND" in
  check)
    [ "$#" -eq 0 ] || fm_exec_die "usage: fm-exec.sh <task-id> check"
    fm_command_execution_check "$FM_EXEC_EXECUTOR"
    ;;
  run)
    lease=
    case "${1-}" in
      --lease)
        [ "$#" -ge 3 ] || fm_exec_die "usage: fm-exec.sh <task-id> run [--lease <opaque-id>] -- <argv...>"
        lease=$2
        fm_exec_opaque_valid "$lease" \
          || fm_exec_die "lease must be a nonempty opaque identifier without control whitespace"
        shift 2
        ;;
    esac
    [ "${1-}" = -- ] || fm_exec_die "run requires -- before argv"
    shift
    [ "$#" -gt 0 ] || fm_exec_die "run requires an argv after --"
    [ "$FM_EXEC_EXECUTOR" != local ] || [ -z "$lease" ] \
      || fm_exec_die "local execution does not accept a lease"
    fm_exec_lock_metadata
    if [ -n "$lease" ]; then
      existing_lease=$(fm_exec_unreleased_lease || true)
      [ -z "$existing_lease" ] || [ "$existing_lease" = "$lease" ] \
        || fm_exec_die "task already has a different unreleased lease"
    fi
    run_id=$(fm_exec_run_id) || fm_exec_die "cannot create an opaque run identifier"
    started=$(fm_exec_timestamp) || fm_exec_die "cannot timestamp command start"
    profile=$FM_EXEC_PROFILE
    [ -z "$lease" ] || profile=
    fm_exec_append_record run-start "$FM_EXEC_EXECUTOR" "$profile" "$lease" "$run_id" "$started" "" ""
    if fm_command_execution_run "$FM_EXEC_EXECUTOR" "$FM_EXEC_CWD" "$profile" "$lease" "$@"; then
      status=0
    else
      status=$?
    fi
    finished=$(fm_exec_timestamp) || fm_exec_die "cannot timestamp command finish"
    fm_exec_append_record run-finish "$FM_EXEC_EXECUTOR" "$profile" "$lease" "$run_id" "$started" "$finished" "$status"
    exit "$status"
    ;;
  inspect)
    [ "$#" -eq 0 ] || fm_exec_die "usage: fm-exec.sh <task-id> inspect"
    [ "$FM_EXEC_EXECUTOR" = crabbox ] \
      || fm_exec_die "local execution has no provider lease to inspect"
    fm_exec_lock_metadata
    lease=$(fm_exec_unreleased_lease || true)
    fm_exec_opaque_valid "$lease" \
      || fm_exec_die "task has no unreleased Crabbox lease to inspect"
    fm_exec_store_snapshot "$lease"
    ;;
  logs)
    [ "$#" -eq 1 ] || fm_exec_die "usage: fm-exec.sh <task-id> logs <opaque-run-id>"
    fm_exec_opaque_valid "$1" \
      || fm_exec_die "run id must be a nonempty opaque identifier without control whitespace"
    fm_command_execution_logs "$FM_EXEC_EXECUTOR" "$1"
    ;;
  release)
    [ "$#" -eq 0 ] || fm_exec_die "usage: fm-exec.sh <task-id> release"
    fm_exec_lock_metadata
    if [ "$FM_EXEC_EXECUTOR" = local ]; then
      fm_command_execution_release local "" || exit $?
      released=$(fm_exec_timestamp) || fm_exec_die "cannot timestamp release"
      fm_exec_append_record release local "" "" "" "" "$released" 0
      exit 0
    fi
    lease=$(fm_exec_unreleased_lease || true)
    fm_exec_opaque_valid "$lease" \
      || fm_exec_die "task has no unreleased Crabbox lease to release"
    if fm_command_execution_release crabbox "$lease"; then
      status=0
    else
      status=$?
    fi
    released=$(fm_exec_timestamp) || fm_exec_die "cannot timestamp release"
    fm_exec_append_record release crabbox "" "$lease" "" "" "$released" "$status"
    exit "$status"
    ;;
  *) fm_exec_die "unsupported command '$COMMAND'" ;;
esac
