#!/usr/bin/env bash
# Narrow Dashboard owner for an explicit task archive request.
#
# Usage: fm-dashboard-archive.sh <task-id> --expect-state <queued|in_flight>
#   --expect-updated-at <timestamp> --expect-spawn-gen <generation|none>
#
# The canonical task record owner performs the archive transition first.
# Existing task retirement then owns endpoint, volatile record and Treehouse
# cleanup. A cleanup refusal is reported separately and never rolls back or
# mislabels the explicit business archive.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

id=${1-}
[ -n "$id" ] || exit 2
shift
expected_state=
expected_updated_at=
expected_generation=
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || exit 2
  case "$1" in
    --expect-state) expected_state=$2 ;;
    --expect-updated-at) expected_updated_at=$2 ;;
    --expect-spawn-gen) expected_generation=$2 ;;
    *) exit 2 ;;
  esac
  shift 2
done

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_valid_id "$id" || exit 2
case "$expected_state" in queued|in_flight) ;; *) exit 2 ;; esac
[ -n "$expected_updated_at" ] || exit 2
case "$expected_generation" in
  none) ;;
  ''|.*|*[!A-Za-z0-9._-]*) exit 2 ;;
esac
[ "$(fm_lease_actor)" = main ] || {
  printf '%s\n' 'REFUSED: Dashboard archive belongs to MAIN' >&2
  exit 6
}
export FM_SUPERVISION_ACTOR=main

dashboard_lock="$STATE/.dashboard-archive-$id.lock"
fm_lock_try_acquire "$dashboard_lock" || {
  printf 'REFUSED: another archive or lifecycle action is running for task %s\n' "$id" >&2
  exit 75
}
meta="$STATE/$id.meta"
control_lock=
spawn_lock=
provider_lock=
meta_lock=
release_operation_locks() {
  [ -z "$meta_lock" ] || { fm_lock_release "$meta_lock"; meta_lock=; }
  [ -z "$provider_lock" ] || { fm_lock_release "$provider_lock"; provider_lock=; }
  [ -z "$spawn_lock" ] || { fm_lock_release "$spawn_lock"; spawn_lock=; }
  [ -z "$control_lock" ] || { fm_lock_release "$control_lock"; control_lock=; }
  fm_lease_guard_release
}
cleanup() {
  local status=$?
  release_operation_locks
  fm_lock_release "$dashboard_lock"
  exit "$status"
}
trap cleanup EXIT

meta_value() { sed -n "s/^$1=//p" "$meta" | tail -n 1; }
receipt_result() { # <generation> [pending-detail]
  local generation=$1 pending=${2:-} receipt disposition cleanup message
  # shellcheck source=bin/fm-cleanup-receipt-lib.sh
  . "$SCRIPT_DIR/fm-cleanup-receipt-lib.sh"
  if receipt=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      fm_cleanup_receipt completion-read "$id" "$generation" 2>/dev/null); then
    disposition=$(printf '%s' "$receipt" | jq -r '.facts.copyDisposition // ""')
    case "$disposition" in
      retained-*) cleanup=retained; message='Archived; the task endpoint was cleaned up and the copy was retained to preserve unlanded or unverified work.' ;;
      returned-or-already-absent) cleanup=completed; message='Archived; task resources and the Treehouse workspace were cleaned up.' ;;
      *) cleanup=pending; message="Archived; resource cleanup remains pending${pending:+: $pending}" ;;
    esac
  else
    cleanup=pending
    message="Archived; resource cleanup remains pending${pending:+: $pending}"
  fi
  jq -cn --arg id "$id" --arg cleanup "$cleanup" --arg message "$message" \
    '{taskId:$id,archive:"archived",cleanup:$cleanup,message:$message}'
}

initial_executor=
initial_provider=
initial_meta_present=0
if [ -e "$meta" ] || [ -L "$meta" ]; then
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    printf 'REFUSED: task %s has unsafe execution metadata\n' "$id" >&2
    exit 75
  }
  initial_executor=$(meta_value executor)
  [ -n "$initial_executor" ] || initial_executor=local-agent
  initial_provider=$(meta_value provider)
  initial_meta_present=1
fi

local_transaction=0
executor=
current_generation=none
if [ "$initial_meta_present" = 1 ] && [ "$initial_executor" = local-agent ] \
  && [ "$expected_generation" != none ]; then
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-tasks-axi.sh" archive "$id" --expect-state "$expected_state" \
      --expect-updated-at "$expected_updated_at" --stop-local-generation "$expected_generation" || exit $?
  local_transaction=1
  executor=local-agent
  current_generation=$expected_generation
fi

if [ "$local_transaction" = 0 ]; then
  fm_lease_guard "$id" 'Dashboard task archive' || exit $?
  control_lock="$STATE/.control-$id.lock"
  fm_lock_acquire_wait "$control_lock" || exit 75
  spawn_lock="$STATE/.spawn-$id.lock"
  fm_lock_acquire_wait "$spawn_lock" || exit 75
  case "${initial_executor:-local-agent}:$initial_provider" in
    cloud-worker:aime|remote-agent:aime)
      # shellcheck source=bin/fm-aime-cloud-lib.sh
      . "$SCRIPT_DIR/fm-aime-cloud-lib.sh"
      provider_lock=$(fm_aime_task_lock_path "$id") || exit 75
      fm_lock_acquire_wait "$provider_lock" || exit 75
      ;;
    remote-agent:ida)
      # shellcheck source=bin/fm-remote-agent-lib.sh
      . "$SCRIPT_DIR/fm-remote-agent-lib.sh"
      meta_lock=$(fm_meta_lock_path "$meta") || exit 75
      fm_lock_acquire_wait "$meta_lock" || exit 75
      provider_lock=$(fm_remote_task_lock_path "$id") || exit 75
      fm_lock_acquire_wait "$provider_lock" || exit 75
      ;;
  esac
  if [ -z "$meta_lock" ]; then
    meta_lock=$(fm_meta_lock_path "$meta") || exit 75
    fm_lock_acquire_wait "$meta_lock" || exit 75
  fi

  record=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" progress "$id") || exit $?
  current_state=$(printf '%s' "$record" | jq -r '.state // empty') || exit 1
  meta_present_after=0
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    meta_present_after=1
    [ -f "$meta" ] && [ ! -L "$meta" ] || exit 75
    executor=$(meta_value executor)
    provider=$(meta_value provider)
    [ "${executor:-local-agent}" = "${initial_executor:-local-agent}" ] && [ "$provider" = "$initial_provider" ] || {
      printf 'REFUSED: task %s execution owner changed since the dashboard snapshot\n' "$id" >&2; exit 75;
    }
    case "${executor:-local-agent}:$provider" in
      local-agent:*) current_generation=$(meta_value spawn_gen) ;;
      cloud-worker:aime|remote-agent:aime)
        fm_aime_state_load "$id" || exit 75
        current_generation=$(jq -r '.execution_generation // empty' "$AIME_STATE_FILE")
        ;;
      remote-agent:ida)
        fm_remote_state_load "$id" || exit 75
        current_generation="remote-$(jq -r '(.generation // 1) | tostring' "$REMOTE_STATE_FILE")"
        ;;
      *) printf 'REFUSED: task %s has an unsupported executor\n' "$id" >&2; exit 75 ;;
    esac
    [ -n "$current_generation" ] || exit 75
  elif [ "$expected_generation" != none ]; then
    if [ "$current_state" != archived ]; then
      printf 'REFUSED: task %s has no execution matching the dashboard generation\n' "$id" >&2
      exit 75
    fi
    current_generation=$expected_generation
  fi
  [ "$current_generation" = "$expected_generation" ] || {
    printf 'REFUSED: task %s execution generation changed since the dashboard snapshot\n' "$id" >&2
    exit 75
  }

  case "$current_state" in
  queued|in_flight)
    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" archive "$id" \
      --expect-state "$expected_state" --expect-updated-at "$expected_updated_at" || exit $?
    ;;
  archived) ;;
  *)
    printf 'REFUSED: task %s is no longer Waiting or Processing\n' "$id" >&2
    exit 75
    ;;
  esac

  release_operation_locks
fi

if [ "${meta_present_after:-1}" = 0 ] && [ "$current_generation" != none ]; then
  receipt_result "$current_generation" 'no active execution metadata remains'
  exit 0
fi
if [ "$current_generation" = none ]; then
  jq -cn --arg id "$id" \
    '{taskId:$id,archive:"archived",cleanup:"completed",message:"Archived; no task resources were recorded."}'
  exit 0
fi
cleanup_generation=$current_generation

retire_out=$(mktemp)
retire_err=$(mktemp)
retire_rc=0
case "${executor:-local-agent}" in
  local-agent)
    retire_args=(--expect-spawn-gen "$current_generation")
    ;;
  cloud-worker|remote-agent)
    retire_args=()
    ;;
  *)
    printf 'REFUSED: task %s has an unsupported executor\n' "$id" >&2
    exit 75
    ;;
esac
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  "$SCRIPT_DIR/fm-task-retire.sh" "$id" "${retire_args[@]+"${retire_args[@]}"}" \
  >"$retire_out" 2>"$retire_err" || retire_rc=$?
if [ "$retire_rc" -ne 0 ]; then
  detail=$(tail -n 1 "$retire_err")
  receipt_result "$cleanup_generation" "$detail"
  rm -f "$retire_out" "$retire_err"
  exit 0
fi

receipt_result "$cleanup_generation"
rm -f "$retire_out" "$retire_err"
