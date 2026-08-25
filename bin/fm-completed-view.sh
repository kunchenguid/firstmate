#!/usr/bin/env bash
# List or explicitly dismiss completed-task static Herdr views.
#
# Usage:
#   fm-completed-view.sh list
#   fm-completed-view.sh dismiss <task-id>
#
# The data format, safety checks, hard retention bound, and exact-dismiss
# contract are owned by bin/fm-completed-view-lib.sh. Listing is read-only.
# Dismiss never trusts a label alone: it locks the completed-view registry and
# exact named Herdr session, then requires the bound pane/tab/workspace identity
# and no registered agent before closing the pane. Switch away from a completed
# tab before dismissing it so Herdr focus can be preserved.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-completed-view-lib.sh
. "$SCRIPT_DIR/fm-completed-view-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,8s/^# \{0,1\}//p' "$0" >&2
}

[ "$#" -ge 1 ] || { usage; exit 2; }
command=$1
shift

case "$command" in
  list)
    [ "$#" -eq 0 ] || { usage; exit 2; }
    fm_backend_source herdr >/dev/null
    fm_completed_view_list "$STATE"
    ;;
  dismiss)
    [ "$#" -eq 1 ] && fm_completed_view_valid_task_id "$1" || { usage; exit 2; }
    id=$1
    record=$(fm_completed_view_record_path "$STATE" "$id")
    [ -e "$record" ] || [ -L "$record" ] || {
      echo "error: no completed-task view for $id" >&2
      exit 1
    }
    registry_lock="$STATE/.completed-task-views.lock"
    if ! fm_lock_try_acquire "$registry_lock"; then
      echo "error: completed-task views are being changed; retry dismissal" >&2
      exit 1
    fi
    session_lock=
    cleanup() {
      local status=$?
      [ -z "$session_lock" ] || fm_lock_release "$session_lock" || true
      fm_lock_release "$registry_lock" || true
      return "$status"
    }
    trap cleanup EXIT
    fm_backend_source herdr >/dev/null
    fm_completed_view_record_load "$STATE" "$id" || {
      echo "error: completed-task view record for $id is invalid or incomplete; inspect it before manual cleanup" >&2
      exit 1
    }
    [ "$FM_COMPLETED_VIEW_RECORD_VERSION" = 2 ] || {
      echo "error: completed-task view creation for $id is incomplete; inspect the recorded workspace before manual cleanup" >&2
      exit 1
    }
    session_lock=$(fm_backend_herdr_presentation_session_lock_path \
      "$FM_COMPLETED_VIEW_RECORD_SESSION") || {
      echo "error: cannot resolve the exact Herdr session lock for $id" >&2
      exit 1
    }
    attempt=0
    while [ "$attempt" -lt 50 ]; do
      if fm_lock_try_acquire "$session_lock"; then
        break
      fi
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if [ "$attempt" -ge 50 ]; then
      session_lock=
      echo "error: Herdr presentation is busy; retry dismissal" >&2
      exit 1
    fi
    if ! fm_completed_view_remove_exact "$STATE" "$id"; then
      echo "error: completed-task view $id did not match its exact safe dismissal identity; nothing was removed" >&2
      exit 1
    fi
    printf 'dismissed completed-task view %s\n' "$id"
    ;;
  *)
    usage
    exit 2
    ;;
esac
