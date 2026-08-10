#!/usr/bin/env bash
# host.sh - identity workspace-placement adapter.
#
# Interface invariants:
# - Only direct mode is supported; host placement never claims isolation.
# - The workspace and launch argv are retained exactly as the caller supplied.
# - Handles are host:<workspace>; inspect and release require that exact handle.
#
# Command assumptions: none. This adapter invokes no external provider.

fm_workspace_placement_host_handle_workspace() {  # <handle>
  local handle=$1 workspace
  case "$handle" in
    host:*) workspace=${handle#host:} ;;
    *)
      fm_workspace_placement_error "invalid host placement handle '$handle'"
      return 2
      ;;
  esac
  if [ -z "$workspace" ]; then
    fm_workspace_placement_error 'invalid host placement handle with empty workspace'
    return 2
  fi
  printf '%s' "$workspace"
}

fm_workspace_placement_host_check() {
  return 0
}

fm_workspace_placement_host_prepare() {  # <direct|clone> <task-id> <workspace>
  local mode=$1 task_id=$2 workspace=$3
  if [ "$mode" != 'direct' ]; then
    fm_workspace_placement_error "host placement does not support mode '$mode' (expected direct)"
    return 2
  fi
  if [ -z "$task_id" ]; then
    fm_workspace_placement_error 'host placement requires a task identity'
    return 2
  fi
  if [ -z "$workspace" ]; then
    fm_workspace_placement_error 'host placement requires a workspace'
    return 2
  fi
  fm_workspace_placement_result_set "host:$workspace" "$workspace" "$workspace" 'no'
}

fm_workspace_placement_host_wrap_launch() {  # <handle> <cwd> <command> [arg...]
  fm_workspace_placement_host_handle_workspace "$1" >/dev/null || return 1
  FM_WORKSPACE_PLACEMENT_LAUNCH=("${@:3}")
}

fm_workspace_placement_host_inspect() {  # <handle>
  fm_workspace_placement_host_handle_workspace "$1" >/dev/null || return 1
  FM_WORKSPACE_PLACEMENT_PRESENT='1'
}

fm_workspace_placement_host_release() {  # <handle> [force]
  fm_workspace_placement_host_handle_workspace "$1" >/dev/null || return 1
  # Identity placement owns no external resource to release.
  return 0
}
