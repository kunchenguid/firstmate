#!/usr/bin/env bash
# Durable goal assessment, consumed by existing lifecycle owners, not a scheduler.
# The public interface is fm-task-state.sh lifecycle|reconcile|action <task>.
# JSON validation/CAS mechanics are in fm-task-lifecycle.py; this boundary owns
# task leases and the existing per-task metadata lock, in that order.
# Readers return legacy only for an absent record; corrupt or stale records are
# unknown and never grant execution authority. No source-time side effects.
FM_TASK_LIFECYCLE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_task_lifecycle() { # <read|reconcile|action|init|mode|due> <task> [arguments...]
  if [ "$1" = mode ]; then
    local path="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}/$2/lifecycle.json"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then printf 'legacy\n'; return 0; fi
  fi
  local lifecycle_home=${FM_HOME:?}
  case "${FM_SUPERVISION_ACTOR:-main}:$1" in
    branch:inspect|branch:refresh|branch:branch-patch|branch:effect|branch:bind-inbox|branch:observe-receipt|branch:handoff-binding|branch:handoff-effect|branch:readback|branch:action)
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
  local operation=$1 id=$2 lock lifecycle_rc=0
  shift 2
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_TASK_LIFECYCLE_BIN/fm-wake-lib.sh"
  # shellcheck source=bin/fm-lease-lib.sh
  . "$FM_TASK_LIFECYCLE_BIN/fm-lease-lib.sh"
  fm_lease_valid_id "$id" || exit 2
  case "$(fm_lease_actor):$operation" in
    main:*|branch:inspect|branch:refresh|branch:branch-patch|branch:action|branch:observe-receipt|branch:readback) ;;
    *) echo "REFUSED: lifecycle assessment belongs to main" >&2; exit 6 ;;
  esac
  fm_lease_guard "$id" "goal reconciliation" || exit $?
  lock=$(fm_meta_lock_path "$STATE/$id.meta") || exit 1
  trap 'lifecycle_rc=$?; fm_lock_release "$lock"; fm_lease_guard_release; exit "$lifecycle_rc"' EXIT
  fm_lock_acquire_wait "$lock" || exit 1
  fm_task_lifecycle "$operation" "$id" "$@"
)

# Existing effect owners call this with their captured execution identity.
# It records facts only; never accepts a goal or changes an outstanding action.
# The caller already owns the task lease. Pass locked only inside its meta lock.
fm_task_lifecycle_owner_receipt() ( # <task> <generation> <merge|cleanup> <facts-json> [locked]
  local id=$1 generation=$2 kind=$3 facts=$4 lock receipt_rc=0
  [ -e "${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}/$id/lifecycle.json" ] || exit 0
  if [ "${5:-}" != locked ]; then
    lock=$(fm_meta_lock_path "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta") || exit 1
    fm_lock_acquire_wait "$lock" || exit 1
    trap 'receipt_rc=$?; fm_lock_release "$lock"; exit "$receipt_rc"' EXIT
  fi
  fm_task_lifecycle owner-receipt "$id" --execution-generation "$generation" --kind "$kind" --facts "$facts" >/dev/null
)

# Preflight before the existing merge/cleanup owner's first external effect.
# Semantic acceptance is separate; unknown state must be read back first.
fm_task_lifecycle_receipt_preflight() { # <task> [merge|cleanup]
  local id=$1 effect=${2:-merge} record
  [ -e "${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}/$id/lifecycle.json" ] || return 0
  record=$(fm_task_lifecycle read "$id") || return 1
  printf '%s' "$record" | jq -e --arg effect "$effect" '
    (.next_action.phase != "attempted" and .next_action.phase != "uncertain") or
    ($effect == "cleanup" and .disposition == "archived" and .next_action.kind != "cleanup")
  ' >/dev/null || {
    echo 'REFUSED: outstanding lifecycle effect requires exact readback before merge or cleanup' >&2
    return 1
  }
}

# Existing action owners already hold their lease guard for the whole control
# transaction. Acquire only the inner metadata lock; never release their lease
# from a child process or recursively take the non-reentrant lease lock.
fm_task_lifecycle_under_meta() (
  local operation=$1 id=$2 lock
  shift 2
  lock=$(fm_meta_lock_path "$STATE/$id.meta") || exit 1
  trap 'fm_lock_release "$lock"' EXIT
  fm_lock_acquire_wait "$lock" || exit 1
  fm_task_lifecycle "$operation" "$id" "$@"
)

fm_task_lifecycle_execution_allowed() { # <task>; legacy behavior stays compatible
  local mode
  mode=$(fm_task_lifecycle mode "$1") || return 1
  case "$mode" in open|legacy) return 0 ;; esac
  printf 'REFUSED: task %s execution disposition is %s; reconcile its durable goal before continuing\n' "$1" "$mode" >&2
  return 1
}

# Ack owners call this only for exact task identities in their own row claim.
# Under an outer presentation/queue lock this is read-only: enroll separately
# under the lease/meta lock before retrying the acknowledgement.
fm_task_lifecycle_ack_guard() { # <task>
  [ "${PI_CODING_AGENT:-}" = true ] || return 0
  local id=$1 data="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" path record
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ -f "$data/$id/brief.md" ] || return 0
  path="$data/$id/lifecycle.json"
  [ -e "$path" ] || [ -L "$path" ] || return 0
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
