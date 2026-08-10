#!/usr/bin/env bash
# docker-sandbox.sh - Docker Sandboxes workspace-placement adapter.
#
# Interface invariants:
# - direct mounts only the selected workspace plus an optional explicit
#   additional workspace; clone creates a private VM clone.
# - A Docker Sandbox always receives one official agent preset.  The adapter
#   accepts the caller-selected preset verbatim after requiring it be nonempty.
# - Sandbox names are deterministic fm-<task-id> values and existing names are
#   refused rather than adopted.
# - Handles bind the task identity to that deterministic name, so inspect and
#   release refuse mismatched handles.
# - Clone cwd is discovered with sbx exec after creation, never guessed.
#
# Official command assumptions: Docker Sandboxes documents `sbx create --name
# NAME AGENT PATH [PATH...]`, `--clone`, `sbx exec`, `sbx ls --quiet`, `sbx
# stop`, and `sbx rm`; this adapter uses only those documented sbx automation
# commands.

fm_workspace_placement_docker_sandbox_check() {
  if ! command -v sbx >/dev/null 2>&1; then
    fm_workspace_placement_error 'docker-sandbox placement requires the sbx CLI; install Docker Sandboxes and ensure sbx is on PATH'
    return 127
  fi
}

fm_workspace_placement_docker_sandbox_name() {  # <task-id>
  local task_id=$1
  case "$task_id" in
    ''|*[![:alnum:].-]*)
      fm_workspace_placement_error "docker-sandbox task identity '$task_id' must use only letters, digits, dots, or hyphens"
      return 2
      ;;
  esac
  printf 'fm-%s' "$task_id"
}

fm_workspace_placement_docker_sandbox_handle() {  # <task-id>
  local task_id=$1 name
  name=$(fm_workspace_placement_docker_sandbox_name "$task_id") || return 1
  printf 'docker-sandbox:%s:%s' "$task_id" "$name"
}

fm_workspace_placement_docker_sandbox_handle_name() {  # <handle>
  local handle=$1 remainder task_id name expected
  case "$handle" in
    docker-sandbox:*:*) remainder=${handle#docker-sandbox:} ;;
    *)
      fm_workspace_placement_error "invalid docker-sandbox placement handle '$handle'"
      return 2
      ;;
  esac
  task_id=${remainder%%:*}
  name=${remainder#*:}
  if [ -z "$task_id" ] || [ -z "$name" ] || [ "$name" = "$task_id" ]; then
    fm_workspace_placement_error "invalid docker-sandbox placement handle '$handle'"
    return 2
  fi
  expected=$(fm_workspace_placement_docker_sandbox_name "$task_id") || return 1
  if [ "$name" != "$expected" ]; then
    fm_workspace_placement_error "docker-sandbox handle '$handle' does not match task identity '$task_id'"
    return 2
  fi
  printf '%s' "$name"
}

fm_workspace_placement_docker_sandbox_resolve_workspace() {  # <workspace>
  local workspace=$1 resolved
  if [ -z "$workspace" ]; then
    fm_workspace_placement_error 'docker-sandbox placement requires a workspace'
    return 2
  fi
  resolved=$(CDPATH='' cd -- "$workspace" 2>/dev/null && pwd -P) || {
    fm_workspace_placement_error "docker-sandbox workspace is not an accessible directory: $workspace"
    return 1
  }
  printf '%s' "$resolved"
}

# Return 0 for an exact name, 1 when absent, and 2 when sbx cannot list safely.
fm_workspace_placement_docker_sandbox_list_contains() {  # <name>
  local name=$1 item listing
  listing=$(sbx ls --quiet) || {
    fm_workspace_placement_error 'could not list Docker Sandboxes with sbx ls --quiet'
    return 2
  }
  while IFS= read -r item || [ -n "$item" ]; do
    [ "$item" = "$name" ] && return 0
  done <<EOF
$listing
EOF
  return 1
}

fm_workspace_placement_docker_sandbox_cleanup_unpublished() {  # <name>
  local name=$1
  sbx stop "$name" >/dev/null 2>&1 || true
  sbx rm "$name" >/dev/null 2>&1 || true
}

fm_workspace_placement_docker_sandbox_prepare() {  # <direct|clone> <task-id> <workspace> <preset> [additional-workspace] [kit-ref...]
  local mode=$1 task_id=$2 workspace=$3 preset=$4 additional_workspace=${5:-}
  local name handle resolved_workspace resolved_additional clone_cwd state kit
  local -a kits=() create_argv
  if [ "$#" -gt 5 ]; then
    kits=("${@:6}")
  fi
  fm_workspace_placement_docker_sandbox_check || return 1
  case "$mode" in
    direct|clone) ;;
    *)
      fm_workspace_placement_error "docker-sandbox placement does not support mode '$mode' (expected direct or clone)"
      return 2
      ;;
  esac
  [ -n "$preset" ] || {
    fm_workspace_placement_error 'docker-sandbox placement requires an explicit official preset'
    return 2
  }
  name=$(fm_workspace_placement_docker_sandbox_name "$task_id") || return 1
  handle=$(fm_workspace_placement_docker_sandbox_handle "$task_id") || return 1
  resolved_workspace=$(fm_workspace_placement_docker_sandbox_resolve_workspace "$workspace") || return 1
  if [ -n "$additional_workspace" ]; then
    resolved_additional=$(fm_workspace_placement_docker_sandbox_resolve_workspace "$additional_workspace") || return 1
    [ "$resolved_additional" != "$resolved_workspace" ] || {
      fm_workspace_placement_error 'docker-sandbox additional workspace must differ from the selected workspace'
      return 2
    }
  fi
  if fm_workspace_placement_docker_sandbox_list_contains "$name"; then
    state=0
  else
    state=$?
  fi
  case "$state" in
    0)
      fm_workspace_placement_error "docker-sandbox identity collision: sandbox '$name' already exists"
      return 1
      ;;
    1) ;;
    *) return "$state" ;;
  esac
  create_argv=(sbx create --name "$name")
  if [ "${kits[0]+set}" = set ]; then
    for kit in "${kits[@]}"; do
      create_argv+=(--kit "$kit")
    done
  fi
  case "$mode" in
    direct)
      create_argv+=("$preset" "$resolved_workspace")
      if [ -n "$resolved_additional" ]; then
        create_argv+=("$resolved_additional")
        "${create_argv[@]}" >/dev/null || {
          fm_workspace_placement_error "could not create Docker Sandbox '$name' for the selected workspaces"
          return 1
        }
      else
        "${create_argv[@]}" >/dev/null || {
          fm_workspace_placement_error "could not create Docker Sandbox '$name' for the selected workspace"
          return 1
        }
      fi
      fm_workspace_placement_result_set "$handle" "$resolved_workspace" "$resolved_workspace" 'yes'
      ;;
    clone)
      [ -z "$resolved_additional" ] || {
        fm_workspace_placement_error 'docker-sandbox clone placement does not support an additional workspace'
        return 2
      }
      create_argv+=(--clone "$preset" "$resolved_workspace")
      "${create_argv[@]}" >/dev/null || {
        fm_workspace_placement_error "could not create cloned Docker Sandbox '$name'"
        return 1
      }
      clone_cwd=$(sbx exec "$name" pwd) || {
        fm_workspace_placement_docker_sandbox_cleanup_unpublished "$name"
        fm_workspace_placement_error "could not determine the working directory inside cloned Docker Sandbox '$name'; removed the unpublished placement when possible"
        return 1
      }
      case "$clone_cwd" in
        /*) ;;
        *)
          fm_workspace_placement_docker_sandbox_cleanup_unpublished "$name"
          fm_workspace_placement_error "Docker Sandbox '$name' returned a non-absolute clone working directory; removed the unpublished placement when possible"
          return 1
          ;;
      esac
      fm_workspace_placement_result_set "$handle" "$resolved_workspace" "$clone_cwd" 'yes'
      ;;
  esac
}

fm_workspace_placement_docker_sandbox_wrap_launch() {  # <handle> <cwd> <command> [arg...]
  local handle=$1 cwd=$2 name
  fm_workspace_placement_docker_sandbox_check || return 1
  name=$(fm_workspace_placement_docker_sandbox_handle_name "$handle") || return 1
  if [ -z "$cwd" ]; then
    fm_workspace_placement_error 'docker-sandbox launch requires an explicit resolved cwd'
    return 2
  fi
  FM_WORKSPACE_PLACEMENT_LAUNCH=(sbx exec -it -w "$cwd" "$name" "${@:3}")
}

fm_workspace_placement_docker_sandbox_inspect() {  # <handle>
  local name state
  fm_workspace_placement_docker_sandbox_check || return 1
  name=$(fm_workspace_placement_docker_sandbox_handle_name "$1") || return 1
  if fm_workspace_placement_docker_sandbox_list_contains "$name"; then
    state=0
  else
    state=$?
  fi
  case "$state" in
    0) FM_WORKSPACE_PLACEMENT_PRESENT='1'; return 0 ;;
    1) FM_WORKSPACE_PLACEMENT_PRESENT='0'; return 1 ;;
    *) return "$state" ;;
  esac
}

fm_workspace_placement_docker_sandbox_release() {  # <handle> [force]
  local handle=$1 force=${2:-} name state
  fm_workspace_placement_docker_sandbox_check || return 1
  name=$(fm_workspace_placement_docker_sandbox_handle_name "$handle") || return 1
  if fm_workspace_placement_docker_sandbox_list_contains "$name"; then
    state=0
  else
    state=$?
  fi
  case "$state" in
    0) ;;
    1) return 0 ;;
    *) return "$state" ;;
  esac
  sbx stop "$name" >/dev/null || {
    fm_workspace_placement_error "could not stop verified Docker Sandbox '$name'; refusing to remove it"
    return 1
  }
  if fm_workspace_placement_docker_sandbox_list_contains "$name"; then
    state=0
  else
    state=$?
  fi
  case "$state" in
    0) ;;
    1) return 0 ;;
    *) return "$state" ;;
  esac
  if [ "$force" = 'force' ]; then
    sbx rm --force "$name" >/dev/null || {
      fm_workspace_placement_error "could not forcibly remove verified Docker Sandbox '$name'"
      return 1
    }
  else
    sbx rm "$name" >/dev/null || {
      fm_workspace_placement_error "could not remove verified Docker Sandbox '$name'"
      return 1
    }
  fi
}
