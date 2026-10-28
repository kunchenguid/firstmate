#!/usr/bin/env bash
# Record a Lima VM a worker created in its task meta, so teardown deletes it
# (bin/fm-lane-vm-lib.sh owns the lane_vms= contract). Adding a name already
# recorded is a no-op, and a name that is not the task id or does not start
# with `<task-id>-` is refused. The meta is rewritten atomically under its meta
# lock.
# Usage: fm-lane-vm-record.sh <task-meta> <vm-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lane-vm-lib.sh
. "$SCRIPT_DIR/fm-lane-vm-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: fm-lane-vm-record.sh <task-meta> <vm-name>" >&2
  exit 2
fi
META=$1
VM=$2
case "$VM" in
  ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
    echo "error: invalid Lima VM name: $VM" >&2
    exit 2
    ;;
esac
TASK_ID=$(basename "$META" .meta)
if ! fm_lane_vm_name_owned "$VM" "$TASK_ID"; then
  echo "error: Lima VM name $VM must be $TASK_ID or start with $TASK_ID-" >&2
  exit 2
fi
META_LOCK=$(fm_meta_lock_path "$META") || {
  echo "error: not a task meta: $META" >&2
  exit 2
}

META_TMP=
META_LOCK_HELD=0
lane_vm_record_cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap lane_vm_record_cleanup EXIT
trap 'exit 1' HUP INT TERM

fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: task metadata is unavailable: $META" >&2; exit 1; }
RECORDED=$(fm_lane_vm_recorded "$META")
case " $RECORDED " in
  *" $VM "*) exit 0 ;;
esac
META_TMP=$(mktemp "$(dirname "$META")/.fm-lane-vm-meta.XXXXXX")
LANE_VMS_LINE="lane_vms=${RECORDED:+$RECORDED }$VM"
LANE_VMS_WRITTEN=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    lane_vms=*) continue ;;
    pr=*)
      if [ "$LANE_VMS_WRITTEN" = 0 ]; then
        printf '%s\n' "$LANE_VMS_LINE" >> "$META_TMP"
        LANE_VMS_WRITTEN=1
      fi
      ;;
  esac
  printf '%s\n' "$line" >> "$META_TMP"
done < "$META"
[ "$LANE_VMS_WRITTEN" = 1 ] || printf '%s\n' "$LANE_VMS_LINE" >> "$META_TMP"
chmod 0600 "$META_TMP"
mv -f -- "$META_TMP" "$META"
META_TMP=
