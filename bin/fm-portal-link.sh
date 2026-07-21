#!/usr/bin/env bash
# Link a longer-running task to one authenticated portal request.
# Usage: fm-portal-link.sh <task-id> <captain-message-id>
# The task's eventual terminal wake must load portal-respond and answer through
# fm-portal-followup.sh before cleanup. No message body enters task metadata.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-portal-lib.sh
. "$SCRIPT_DIR/fm-portal-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 2 ]; then
  echo 'usage: fm-portal-link.sh <task-id> <captain-message-id>' >&2
  exit 2
fi
task=$1
id=$2
fmp_task_id_valid "$task" || { echo 'fm-portal-link: invalid task id' >&2; exit 2; }
fmp_id_valid "$id" || { echo 'fm-portal-link: invalid captain message id' >&2; exit 2; }
fmp_load_config || { echo 'fm-portal-link: connector configuration is unavailable' >&2; exit 1; }
fmp_portal_prepare || { echo 'fm-portal-link: private portal state is unavailable' >&2; exit 1; }
meta="$FMP_STATE/$task.meta"
[ -f "$meta" ] && [ ! -L "$meta" ] || { echo 'fm-portal-link: task metadata is unavailable' >&2; exit 1; }

fm_lock_acquire_wait "$FMP_LOCK"
fmp_record_load "$id" || { fm_lock_release "$FMP_LOCK"; echo 'fm-portal-link: portal request is unavailable' >&2; exit 1; }
case "$FMP_RECORD_STATE" in
  claimed|pending|queued|linked) ;;
  *) fm_lock_release "$FMP_LOCK"; echo 'fm-portal-link: portal request cannot be linked in its current state' >&2; exit 1 ;;
esac
existing=$(fmp_meta_get "$meta" portal_request)
if [ -n "$existing" ] && [ "$existing" != "$id" ]; then
  fm_lock_release "$FMP_LOCK"
  echo 'fm-portal-link: task is already linked to another portal request' >&2
  exit 1
fi
other=$(fmp_task_for_request "$id" 2>/dev/null) || other=
if [ -n "$other" ] && [ "$other" != "$task" ]; then
  fm_lock_release "$FMP_LOCK"
  echo 'fm-portal-link: portal request is already linked to another task' >&2
  exit 1
fi
fmp_record_set_state "$id" linked "$task" 0 || { fm_lock_release "$FMP_LOCK"; exit 1; }
fmp_meta_link_set "$meta" "$id" || {
  fmp_record_set_state "$id" pending "" 0 || true
  fm_lock_release "$FMP_LOCK"
  echo 'fm-portal-link: could not record task link' >&2
  exit 1
}
fm_lock_release "$FMP_LOCK"
printf '%s\n' "$id"
