#!/usr/bin/env bash
# bin/executors/crabbox.sh - explicit Crabbox command-execution adapter.
#
# This adapter emits only documented Crabbox command forms and never reads
# credentials, parses prose, or stores provider state. Crabbox runs can incur
# provider cost and lease expiry is provider-controlled, so callers record and
# reconcile opaque lease/run IDs themselves. crabbox stop <lease> is issued only
# for a nonempty lease explicitly supplied by that caller. Interactive Crabbox
# access remains outside this command-execution module.
#
# crabbox prewarm <profile> has no documented machine-readable lease-handle
# result. Preparing it would create an unrecordable, expiring resource, so
# prepare fails safely until that CLI surface exists; run-by-profile remains usable.

fm_executor_crabbox_tool_check() {
  command -v crabbox >/dev/null 2>&1 || {
    echo "error: executor=crabbox selected but the 'crabbox' CLI is not installed; install Crabbox or select executor=local" >&2
    return 1
  }
}

# fm_executor_crabbox_check: stream Crabbox's readiness verdict unchanged.
fm_executor_crabbox_check() {
  fm_executor_crabbox_tool_check || return 1
  crabbox doctor
}

fm_executor_crabbox_prepare() {  # <profile>
  local profile=$1
  fm_executor_crabbox_tool_check || return 1
  [ -n "$profile" ] || {
    echo "error: Crabbox preparation requires an explicit job profile" >&2
    return 1
  }
  echo "error: Crabbox warm preparation is unavailable: 'crabbox prewarm $profile' has no documented machine-readable lease handle. Use fm_command_execution_run with this explicit profile, or provide a verified caller-owned lease." >&2
  return 1
}

# fm_executor_crabbox_run: stream remote stdout/stderr and preserve its status.
fm_executor_crabbox_run() {  # <cwd> <profile> <lease> <argv...>
  local cwd=$1 profile=$2 lease=$3
  shift 3
  fm_executor_crabbox_tool_check || return 1
  # Crabbox's documented run forms bind the remote workspace to the profile/lease.
  : "$cwd"
  if [ -n "$lease" ]; then
    crabbox run --id "$lease" -- "$@"
  else
    crabbox run --profile "$profile" -- "$@"
  fi
}

# fm_executor_crabbox_inspect: stream the documented JSON status for one handle.
fm_executor_crabbox_inspect() {  # <opaque-lease-or-run-id>
  local handle=$1
  fm_executor_crabbox_tool_check || return 1
  crabbox status --id "$handle" --json
}

# fm_executor_crabbox_logs: stream documented logs for one opaque run ID.
fm_executor_crabbox_logs() {  # <opaque-run-id>
  local run_id=$1
  fm_executor_crabbox_tool_check || return 1
  crabbox logs "$run_id"
}

# fm_executor_crabbox_release: stop only the caller's explicit opaque lease.
fm_executor_crabbox_release() {  # <opaque-lease>
  local lease=$1
  fm_executor_crabbox_tool_check || return 1
  crabbox stop "$lease"
}
