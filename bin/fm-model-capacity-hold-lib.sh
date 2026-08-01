#!/usr/bin/env bash
# Read-only enforcement for the one home-wide registered model-capacity hold.
# Firstmate-controlled paths that can launch or prompt a model call this before
# mutation. Interrupt and cleanup-only paths remain available.

fm_model_capacity_hold_path() {
  printf '%s/.model-capacity-hold\n' "${STATE:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"
}

fm_model_capacity_hold_value() {  # <path> <key>
  local path=$1 key=$2 count
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  count=$(grep -c "^$key=" "$path" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^$key=//p" "$path"
}

fm_model_capacity_hold_refuse() {  # <operation>
  local operation=$1 marker schema id reason dispatch
  marker=$(fm_model_capacity_hold_path)
  [ -e "$marker" ] || return 0
  schema=$(fm_model_capacity_hold_value "$marker" schema) || schema=invalid
  id=$(fm_model_capacity_hold_value "$marker" hold_id) || id=unknown
  reason=$(fm_model_capacity_hold_value "$marker" reason) || reason='malformed hold record'
  dispatch=$(fm_model_capacity_hold_value "$marker" dispatch_ref) || dispatch=unknown
  if [ "$schema" != fm-model-capacity-hold.v1 ]; then
    printf 'error: model-capacity hold record is malformed; refusing %s until %s is reconciled\n' "$operation" "$marker" >&2
    return 1
  fi
  printf 'error: model-capacity hold %s is active; refusing %s (reason=%s; dispatch_ref=%s)\n' \
    "$id" "$operation" "$reason" "$dispatch" >&2
  return 1
}
