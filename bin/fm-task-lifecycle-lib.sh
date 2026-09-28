#!/usr/bin/env bash
# Durable goal assessment, consumed by existing lifecycle owners, not a scheduler.
# The public interface is fm-task-state.sh lifecycle|reconcile|action <task>.
# JSON validation/CAS mechanics are in fm-task-lifecycle.py; this boundary owns
# task leases and the existing per-task metadata lock, in that order.
# Readers return legacy only for an absent record; corrupt or stale records are
# unknown and never grant execution authority. No source-time side effects.
FM_TASK_LIFECYCLE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_task_lifecycle() { # <read|reconcile|action|init|observe> <task> [arguments...]
  local lifecycle_home=${FM_HOME:?}
  case "${FM_SUPERVISION_ACTOR:-main}:$1" in
    branch:branch-patch|branch:effect|branch:bind-inbox|branch:handoff-binding|branch:handoff-effect|branch:readback|branch:action)
      # Reuse the branch generation owner without claiming any queue row.
      # shellcheck source=bin/fm-wake-lib.sh
      . "$FM_TASK_LIFECYCLE_BIN/fm-wake-lib.sh"
      if [ "$(jq -r '.schema' "${FM_DATA_OVERRIDE:-$lifecycle_home/data}/$2/lifecycle.json" 2>/dev/null)" = fm-task-lifecycle.v2 ]; then
        if [ -z "${FM_BRANCH_GENERATION:-}" ] || ! fm_wake_branch_owner_matches "$STATE/.branch-eligible-owner" "${FM_LEASE_HOLDER_PID:-}" "$FM_BRANCH_GENERATION"; then
          echo 'REFUSED: delegated mutation has a stale branch generation' >&2; return 6
        fi
      fi
      ;;
  esac
  FM_HOME="$lifecycle_home" FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-${DATA:-$lifecycle_home/data}}" \
    FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-${STATE:-$lifecycle_home/state}}" \
    python3 "$FM_TASK_LIFECYCLE_BIN/fm-task-lifecycle.py" "$@"
}

fm_task_lifecycle_mutate() (
  local operation=$1 id=$2 lock
  shift 2
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_TASK_LIFECYCLE_BIN/fm-wake-lib.sh"
  # shellcheck source=bin/fm-lease-lib.sh
  . "$FM_TASK_LIFECYCLE_BIN/fm-lease-lib.sh"
  fm_lease_valid_id "$id" || exit 2
  case "$(fm_lease_actor):$operation" in
    main:*|branch:branch-patch|branch:action|branch:readback) ;;
    *) echo "REFUSED: lifecycle assessment belongs to main" >&2; exit 6 ;;
  esac
  fm_lease_guard "$id" "goal reconciliation" || exit $?
  lock=$(fm_meta_lock_path "$STATE/$id.meta") || exit 1
  trap 'fm_lock_release "$lock"; fm_lease_guard_release' EXIT
  fm_lock_acquire_wait "$lock" || exit 1
  fm_task_lifecycle "$operation" "$id" "$@"
)

# Ack owners call this only for exact task identities in their own row claim.
# Under an outer presentation/queue lock this is read-only: enroll separately
# under the lease/meta lock before retrying the acknowledgement.
fm_task_lifecycle_ack_guard() { # <task>
  [ "${PI_CODING_AGENT:-}" = true ] || return 0
  local id=$1 data="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" record
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ -f "$data/$id/brief.md" ] || return 0
  record=$(fm_task_lifecycle read "$id") || return 1
  [ "$record" != null ] || {
    printf 'REFUSED: retain task %s with fm-task-state.sh enroll before acknowledging its outcome\n' "$id" >&2
    return 1
  }
}

# No legacy migration or new execution authorization. Existing enrolled goals
# add a fail-closed stop at the ordinary steer/relaunch owner.
fm_task_lifecycle_execution_guard() { # <task>
  local id=$1 data="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" record
  [ -e "$data/$id/lifecycle.json" ] || [ -L "$data/$id/lifecycle.json" ] || return 0
  record=$(fm_task_lifecycle read "$id") || return 1
  printf '%s' "$record" | jq -e '.disposition == "open" and (.next_action.phase != "attempted") and (.next_action.phase != "uncertain")' >/dev/null || {
    printf 'REFUSED: task %s is terminal or has an attempted/uncertain effect; reconcile evidence before execution\n' "$id" >&2
    return 1
  }
}

# v2 delegates progression, never replacement execution or task retirement.
# Legacy callers keep their existing lifecycle authority.
fm_task_lifecycle_forbid_delegated_control() { # <task>
  [ "${FM_SUPERVISION_ACTOR:-main}" = branch ] || return 0
  local id=$1 data="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" record
  [ -e "$data/$id/lifecycle.json" ] || [ -L "$data/$id/lifecycle.json" ] || return 0
  record=$(fm_task_lifecycle read "$id") || return 6
  if [ "$(printf '%s' "$record" | jq -r '.schema')" = fm-task-lifecycle.v2 ]; then
    echo 'REFUSED: delegated task lifecycle control and retirement belong to MAIN' >&2
    return 6
  fi
}
