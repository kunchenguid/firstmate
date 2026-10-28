# shellcheck shell=bash
# Delete a finished task's own Lima lane VMs.
# Usage: . bin/fm-lane-vm-lib.sh; fm_lane_vm_cleanup <task-id> <task-meta>
#
# Every home on the Mac shares one Lima directory, so a VM name alone never
# says which task owns it. A worker records each Lima VM it creates in its task
# meta as a space-separated `lane_vms=` line (bin/fm-lane-vm-record.sh), and
# cleanup deletes exactly those recorded names, so a stopped VM of a finished
# task stops holding disk. A recorded name must be <task-id> or start with
# `<task-id>-` (fm_lane_vm_name_owned); any other is skipped, so a corrupt or
# foreign record can never delete another task's VM. Teardown runs cleanup only
# on an opted-in home (config/lane-vm-cleanup). An absent limactl is a quiet
# no-op; a list or delete failure warns and never blocks the rest of cleanup.

# fm_lane_vm_name_owned <vm-name> <task-id>: true for <task-id> or <task-id>-*.
fm_lane_vm_name_owned() {
  case "$1" in
    "$2"|"$2"-?*) return 0 ;;
  esac
  return 1
}

# fm_lane_vm_recorded <task-meta>: the recorded VM names, space-separated.
fm_lane_vm_recorded() {
  local meta=$1 line value=
  [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      lane_vms=*) value=${line#lane_vms=} ;;
    esac
  done < "$meta"
  printf '%s' "$value"
}

fm_lane_vm_cleanup() {
  local id=$1 meta=$2 names vm owned
  [ -n "$id" ] || return 0
  command -v limactl >/dev/null 2>&1 || return 0
  names=$(limactl list --quiet 2>/dev/null) || {
    echo "warning: could not list Lima VMs; $id's lane VMs were not cleaned up" >&2
    return 0
  }
  owned=" $(fm_lane_vm_recorded "$meta") "
  while IFS= read -r vm; do
    [ -n "$vm" ] || continue
    case "$owned" in
      *" $vm "*) ;;
      *) continue ;;
    esac
    if ! fm_lane_vm_name_owned "$vm" "$id"; then
      echo "warning: skipping recorded Lima VM $vm; its name does not belong to $id" >&2
      continue
    fi
    limactl delete --force "$vm" >/dev/null 2>&1 \
      || echo "warning: could not delete Lima VM $vm for $id" >&2
  done <<< "$names"
  return 0
}
