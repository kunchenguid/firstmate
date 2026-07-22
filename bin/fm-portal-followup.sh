#!/usr/bin/env bash
# Post the one terminal response for a task linked to a portal request.
# Usage:
#   fm-portal-followup.sh <task-id> --text-file <path>
#   fm-portal-followup.sh <task-id> -
# Success clears the task link only after the response and originating-message
# acknowledgement are durably complete. Retrying after any crash is idempotent.
# A deferred acknowledgement (exit 5) keeps the link; the poller resumes the
# reply after the earlier request completes and clears the link itself.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-portal-lib.sh
. "$SCRIPT_DIR/fm-portal-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -lt 2 ]; then
  echo 'usage: fm-portal-followup.sh <task-id> (--text-file <path>|-)' >&2
  exit 2
fi
task=$1
shift
fmp_task_id_valid "$task" || { echo 'fm-portal-followup: invalid task id' >&2; exit 2; }
meta="$FMP_STATE/$task.meta"
[ -f "$meta" ] && [ ! -L "$meta" ] || { echo 'fm-portal-followup: task metadata is unavailable' >&2; exit 1; }
id=$(fmp_meta_get "$meta" portal_request)
fmp_id_valid "$id" || { echo 'fm-portal-followup: task has no valid portal request link' >&2; exit 1; }

case "${1:-}" in
  --text-file)
    [ "$#" -eq 2 ] || { echo 'usage: fm-portal-followup.sh <task-id> (--text-file <path>|-)' >&2; exit 2; }
    "$SCRIPT_DIR/fm-portal-reply.sh" "$id" --text-file "$2" >/dev/null || exit $?
    ;;
  -)
    [ "$#" -eq 1 ] || { echo 'usage: fm-portal-followup.sh <task-id> (--text-file <path>|-)' >&2; exit 2; }
    "$SCRIPT_DIR/fm-portal-reply.sh" "$id" - >/dev/null || exit $?
    ;;
  *) echo 'usage: fm-portal-followup.sh <task-id> (--text-file <path>|-)' >&2; exit 2 ;;
esac

fm_lock_acquire_wait "$FMP_LOCK"
current=$(fmp_meta_get "$meta" portal_request)
if [ "$current" = "$id" ]; then
  fmp_meta_link_clear "$meta" || {
    fm_lock_release "$FMP_LOCK"
    echo 'fm-portal-followup: response completed but task link cleanup failed' >&2
    exit 1
  }
fi
fm_lock_release "$FMP_LOCK"
printf '%s\n' "$id"
