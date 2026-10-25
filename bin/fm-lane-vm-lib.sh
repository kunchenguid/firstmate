# shellcheck shell=bash
# Delete a finished task's own Lima lane VMs.
# Usage: . bin/fm-lane-vm-lib.sh; fm_lane_vm_cleanup <task-id> <state-dir>
#
# A worker names each lane VM after its bare task id (bin/fm-brief.sh owns that
# rule), never its branch prefix: exactly `<task-id>` or `<task-id>-<suffix>`.
# Cleanup deletes those names and nothing else, so a stopped VM of a finished
# task stops holding disk. A VM name that also matches another live task's id
# in <state-dir> (a `<id>.meta` record) is left alone, because that task may
# still be using it. An absent limactl is a quiet no-op; a list or delete
# failure warns and never blocks the rest of cleanup.

# fm_lane_vm_name_matches <vm-name> <task-id>: true for <task-id> or <task-id>-*.
fm_lane_vm_name_matches() {
  case "$1" in
    "$2"|"$2"-*) return 0 ;;
  esac
  return 1
}

# fm_lane_vm_claimed_by_other_task <vm-name> <task-id> <state-dir>
fm_lane_vm_claimed_by_other_task() {
  local vm=$1 id=$2 state=$3 meta other
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    other=$(basename "$meta" .meta)
    [ "$other" != "$id" ] || continue
    fm_lane_vm_name_matches "$vm" "$other" && return 0
  done
  return 1
}

fm_lane_vm_cleanup() {
  local id=$1 state=$2 names vm
  [ -n "$id" ] || return 0
  command -v limactl >/dev/null 2>&1 || return 0
  names=$(limactl list --quiet 2>/dev/null) || {
    echo "warning: could not list Lima VMs; $id's lane VMs were not cleaned up" >&2
    return 0
  }
  while IFS= read -r vm; do
    [ -n "$vm" ] || continue
    fm_lane_vm_name_matches "$vm" "$id" || continue
    if fm_lane_vm_claimed_by_other_task "$vm" "$id" "$state"; then
      echo "note: keeping Lima VM $vm; its name also matches another live task" >&2
      continue
    fi
    limactl delete --force "$vm" >/dev/null 2>&1 \
      || echo "warning: could not delete Lima VM $vm for $id" >&2
  done <<< "$names"
  return 0
}
