#!/usr/bin/env bash
# fm-command-execution.sh - explicit command-executor dispatch.
#
# Source this file and call only these functions:
#   fm_command_execution_check <executor>
#   fm_command_execution_prepare <executor> <profile>
#   fm_command_execution_run <executor> <cwd> <profile> <lease> <argv...>
#   fm_command_execution_inspect <executor> <opaque-handle>
#   fm_command_execution_logs <executor> <opaque-run-id>
#   fm_command_execution_release <executor> <opaque-lease>
#
# The executor is always explicit: known values are local and crabbox, and an
# unknown value fails rather than selecting a fallback.  cwd is required for
# every run.  Local routing has no provider identity and therefore requires both
# profile and lease empty.  Crabbox routing requires exactly one nonempty
# provider identity, profile or lease.  This module writes no state and never
# parses provider prose: any stdout is caller-recordable provider data and
# opaque values stay caller-owned.
#
# Crabbox execution can incur provider cost, and provider leases may expire.
# Callers must record and reconcile opaque lease/run IDs themselves.  Release is
# caller-owned: crabbox stop is issued only for a nonempty caller-supplied lease;
# local release is a no-op.  Warm preparation is unavailable until Crabbox offers
# a documented machine-readable prewarm lease handle, so this module never
# creates an unrecordable warm lease.

FM_COMMAND_EXECUTION_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_COMMAND_EXECUTION_LIB_DIR="$(cd "$(dirname "$FM_COMMAND_EXECUTION_SCRIPT")" && pwd)"
unset FM_COMMAND_EXECUTION_SCRIPT
FM_COMMAND_EXECUTION_KNOWN="local crabbox"

# fm_command_execution_validate: reject an executor that this owner does not know.
fm_command_execution_validate() {  # <executor>
  local executor=${1:-}
  case "$executor" in
    local|crabbox) return 0 ;;
    *)
      echo "error: unknown command executor '$executor' (known: $FM_COMMAND_EXECUTION_KNOWN)" >&2
      return 1
      ;;
  esac
}

# fm_command_execution_source: load the selected adapter without selecting one.
fm_command_execution_source() {  # <executor>
  local executor=${1:-}
  fm_command_execution_validate "$executor" || return 1
  case "$executor" in
    local)
      # shellcheck source=/dev/null
      . "$FM_COMMAND_EXECUTION_LIB_DIR/executors/local.sh"
      ;;
    crabbox)
      # shellcheck source=/dev/null
      . "$FM_COMMAND_EXECUTION_LIB_DIR/executors/crabbox.sh"
      ;;
  esac
}

# fm_command_execution_check: test the selected executor's availability.
fm_command_execution_check() {  # <executor>
  [ "$#" -eq 1 ] || {
    echo "error: usage: fm_command_execution_check <executor>" >&2
    return 1
  }
  local executor=$1
  fm_command_execution_source "$executor" || return 1
  case "$executor" in
    local) fm_executor_local_check ;;
    crabbox) fm_executor_crabbox_check ;;
  esac
}

# fm_command_execution_prepare: optionally prepare a selected executor profile.
fm_command_execution_prepare() {  # <executor> <profile>
  [ "$#" -eq 2 ] || {
    echo "error: usage: fm_command_execution_prepare <executor> <profile>" >&2
    return 1
  }
  local executor=$1
  fm_command_execution_source "$executor" || return 1
  case "$executor" in
    local) fm_executor_local_prepare "$2" ;;
    crabbox) fm_executor_crabbox_prepare "$2" ;;
  esac
}

# fm_command_execution_run: execute argv through one explicit profile or lease.
fm_command_execution_run() {  # <executor> <cwd> <profile> <lease> <argv...>
  [ "$#" -ge 5 ] || {
    echo "error: usage: fm_command_execution_run <executor> <cwd> <profile> <lease> <argv...>" >&2
    return 1
  }
  local executor=$1 cwd=$2 profile=$3 lease=$4
  shift 4
  [ -n "$cwd" ] || {
    echo "error: command execution requires an explicit nonempty cwd" >&2
    return 1
  }
  case "$executor" in
    local)
      if [ -n "$profile" ] || [ -n "$lease" ]; then
        echo "error: local command execution requires empty profile and lease" >&2
        return 1
      fi
      ;;
    crabbox)
      if { [ -n "$profile" ] && [ -n "$lease" ]; } || { [ -z "$profile" ] && [ -z "$lease" ]; }; then
        echo "error: Crabbox command execution requires exactly one nonempty routing axis: profile or lease" >&2
        return 1
      fi
      ;;
  esac
  fm_command_execution_source "$executor" || return 1
  case "$executor" in
    local) fm_executor_local_run "$cwd" "$profile" "$lease" "$@" ;;
    crabbox) fm_executor_crabbox_run "$cwd" "$profile" "$lease" "$@" ;;
  esac
}

# fm_command_execution_inspect: inspect one explicit opaque provider handle.
fm_command_execution_inspect() {  # <executor> <opaque-handle>
  [ "$#" -eq 2 ] && [ -n "$2" ] || {
    echo "error: usage: fm_command_execution_inspect <executor> <opaque-handle>" >&2
    return 1
  }
  local executor=$1
  fm_command_execution_source "$executor" || return 1
  case "$executor" in
    local) fm_executor_local_inspect "$2" ;;
    crabbox) fm_executor_crabbox_inspect "$2" ;;
  esac
}

# fm_command_execution_logs: stream logs for one explicit opaque run ID.
fm_command_execution_logs() {  # <executor> <opaque-run-id>
  [ "$#" -eq 2 ] && [ -n "$2" ] || {
    echo "error: usage: fm_command_execution_logs <executor> <opaque-run-id>" >&2
    return 1
  }
  local executor=$1
  fm_command_execution_source "$executor" || return 1
  case "$executor" in
    local) fm_executor_local_logs "$2" ;;
    crabbox) fm_executor_crabbox_logs "$2" ;;
  esac
}

# fm_command_execution_release: release one explicit caller-owned lease.
fm_command_execution_release() {  # <executor> <opaque-lease>
  [ "$#" -eq 2 ] || {
    echo "error: usage: fm_command_execution_release <executor> <opaque-lease>" >&2
    return 1
  }
  local executor=$1 lease=$2
  fm_command_execution_source "$executor" || return 1
  case "$executor" in
    local) fm_executor_local_release "$lease" ;;
    crabbox)
      [ -n "$lease" ] || {
        echo "error: refusing to release an empty Crabbox lease" >&2
        return 1
      }
      fm_executor_crabbox_release "$lease"
      ;;
  esac
}
