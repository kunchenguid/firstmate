#!/usr/bin/env bash
# fm-workspace-placement.sh - sourceable workspace-placement lifecycle owner.
#
# - prepare <placement> <direct|clone> <task-id> <workspace> [preset] [additional-workspace] [kit-ref...]
#   sets the result globals only after the adapter has created a usable placement.
# - Docker Sandboxes receive an explicit official preset, may mount one
#   additional workspace, and accept zero or more kit references; host retains
#   its historical four-argument form.
# - wrap-launch <placement> <handle> <cwd> <command...> sets
#   FM_WORKSPACE_PLACEMENT_LAUNCH as an argv-preserving Bash array; it never
#   executes or supervises the command.
# - inspect and release accept only the explicit opaque handle supplied by the
#   caller; a requested adapter never falls back to another adapter.
#
# Adapter command assumptions live in each adapter header. This module has no
# side effects when sourced beyond defining functions and its module variables.

FM_WORKSPACE_PLACEMENT_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_WORKSPACE_PLACEMENT_DIR="$(cd "$(dirname "$FM_WORKSPACE_PLACEMENT_SCRIPT")" && pwd)" || return 1
unset FM_WORKSPACE_PLACEMENT_SCRIPT
# shellcheck disable=SC2034 # Public source-library variable consumed by placement callers.
FM_WORKSPACE_PLACEMENT_KNOWN='host docker-sandbox'

fm_workspace_placement_error() {
  printf 'error: %s\n' "$*" >&2
}

fm_workspace_placement_validate() {  # <placement>
  if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    fm_workspace_placement_error 'workspace placement is required (host or docker-sandbox)'
    return 2
  fi
  case "$1" in
    host|docker-sandbox) return 0 ;;
    *)
      fm_workspace_placement_error "unknown workspace placement '$1' (expected host or docker-sandbox)"
      return 2
      ;;
  esac
}

fm_workspace_placement_source() {  # <placement>
  local placement=$1
  fm_workspace_placement_validate "$placement" || return 1
  case "$placement" in
    host)
      if [ -z "${_FM_WORKSPACE_PLACEMENT_HOST_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_WORKSPACE_PLACEMENT_DIR/placements/host.sh" || return 1
        _FM_WORKSPACE_PLACEMENT_HOST_SOURCED=1
      fi
      ;;
    docker-sandbox)
      if [ -z "${_FM_WORKSPACE_PLACEMENT_DOCKER_SANDBOX_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_WORKSPACE_PLACEMENT_DIR/placements/docker-sandbox.sh" || return 1
        _FM_WORKSPACE_PLACEMENT_DOCKER_SANDBOX_SOURCED=1
      fi
      ;;
  esac
}

fm_workspace_placement_result_clear() {
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_ACQUIRED_HANDLE=''
  # shellcheck disable=SC2034 # Public result globals consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_HANDLE=''
  # shellcheck disable=SC2034 # Public result globals consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_WORKSPACE=''
  # shellcheck disable=SC2034 # Public result globals consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_CWD=''
  # shellcheck disable=SC2034 # Public result globals consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_ISOLATED=''
}

fm_workspace_placement_result_set() {  # <handle> <workspace> <cwd> <yes|no>
  # shellcheck disable=SC2034 # Public result globals consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_HANDLE=$1
  # shellcheck disable=SC2034 # Public result globals consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_WORKSPACE=$2
  # shellcheck disable=SC2034 # Public result globals consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_CWD=$3
  # shellcheck disable=SC2034 # Public result globals consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_ISOLATED=$4
}

# fm_workspace_placement_check: verify the named provider is usable now.
fm_workspace_placement_check() {  # <placement>
  local placement=$1
  fm_workspace_placement_source "$placement" || return 1
  case "$placement" in
    host) fm_workspace_placement_host_check ;;
    docker-sandbox) fm_workspace_placement_docker_sandbox_check ;;
    *) fm_workspace_placement_error "no check implementation for placement '$placement'"; return 1 ;;
  esac
}

# fm_workspace_placement_prepare: create a placement and publish its result.
# Docker Sandboxes require an explicit preset, accept one optional additional
# workspace, and accept zero or more kit references.  Host retains its
# historical four-argument call shape.
fm_workspace_placement_prepare() {  # <placement> <direct|clone> <task-id> <workspace> [preset] [additional-workspace] [kit-ref...]
  local placement=${1:-}
  fm_workspace_placement_result_clear
  if [ "$#" -lt 4 ]; then
    fm_workspace_placement_error 'usage: fm_workspace_placement_prepare <placement> <direct|clone> <task-id> <workspace> [preset] [additional-workspace] [kit-ref...]'
    return 2
  fi
  fm_workspace_placement_source "$placement" || return 1
  case "$placement" in
    host)
      [ "$#" -eq 4 ] || {
        fm_workspace_placement_error 'host placement does not accept a sandbox preset, additional workspace, or kits'
        return 2
      }
      fm_workspace_placement_host_prepare "$2" "$3" "$4"
      ;;
    docker-sandbox)
      if [ "$#" -gt 6 ]; then
        fm_workspace_placement_docker_sandbox_prepare "$2" "$3" "$4" "${5:-}" "${6:-}" "${@:7}"
      else
        fm_workspace_placement_docker_sandbox_prepare "$2" "$3" "$4" "${5:-}" "${6:-}"
      fi
      ;;
    *) fm_workspace_placement_error "no prepare implementation for placement '$placement'"; return 1 ;;
  esac
}

# fm_workspace_placement_wrap_launch: build, but do not execute, placement argv.
fm_workspace_placement_wrap_launch() {  # <placement> <handle> <cwd> <command> [arg...]
  local placement=${1:-}
  # shellcheck disable=SC2034 # Public launch array consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_LAUNCH=()
  if [ "$#" -lt 4 ]; then
    fm_workspace_placement_error 'usage: fm_workspace_placement_wrap_launch <placement> <handle> <cwd> <command> [arg...]'
    return 2
  fi
  fm_workspace_placement_source "$placement" || return 1
  case "$placement" in
    host) fm_workspace_placement_host_wrap_launch "$2" "$3" "${@:4}" ;;
    docker-sandbox) fm_workspace_placement_docker_sandbox_wrap_launch "$2" "$3" "${@:4}" ;;
    *) fm_workspace_placement_error "no launch wrapper for placement '$placement'"; return 1 ;;
  esac
}

# fm_workspace_placement_inspect: set PRESENT=1 when its explicit handle exists.
fm_workspace_placement_inspect() {  # <placement> <handle>
  local placement=${1:-}
  # shellcheck disable=SC2034 # Public result global consumed by callers after sourcing.
  FM_WORKSPACE_PLACEMENT_PRESENT=''
  if [ "$#" -ne 2 ]; then
    fm_workspace_placement_error 'usage: fm_workspace_placement_inspect <placement> <handle>'
    return 2
  fi
  fm_workspace_placement_source "$placement" || return 1
  case "$placement" in
    host) fm_workspace_placement_host_inspect "$2" ;;
    docker-sandbox) fm_workspace_placement_docker_sandbox_inspect "$2" ;;
    *) fm_workspace_placement_error "no inspect implementation for placement '$placement'"; return 1 ;;
  esac
}

# fm_workspace_placement_release: release an explicit handle; force is opt-in.
fm_workspace_placement_release() {  # <placement> <handle> [force]
  local placement=${1:-}
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    fm_workspace_placement_error 'usage: fm_workspace_placement_release <placement> <handle> [force]'
    return 2
  fi
  if [ "${3:-}" != '' ] && [ "${3:-}" != 'force' ]; then
    fm_workspace_placement_error "unknown release option '$3' (expected force)"
    return 2
  fi
  fm_workspace_placement_source "$placement" || return 1
  case "$placement" in
    host) fm_workspace_placement_host_release "$2" "${3:-}" ;;
    docker-sandbox) fm_workspace_placement_docker_sandbox_release "$2" "${3:-}" ;;
    *) fm_workspace_placement_error "no release implementation for placement '$placement'"; return 1 ;;
  esac
}
