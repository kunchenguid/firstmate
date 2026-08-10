#!/usr/bin/env bash
# bin/executors/local.sh - transparent local command-execution adapter.
#
# Invariants: run changes directory only in a subshell, then execs the supplied
# argv without rewriting it. stdout, stderr, and the command's exit code pass
# through unchanged. Local has no provider cost, lease, expiry, run status, or
# logs. Its release operation is a no-op and never allocates or destroys state.

fm_executor_local_check() {
  return 0
}

fm_executor_local_prepare() {  # <profile>
  [ -z "$1" ] || {
    echo "error: local executor does not accept a profile" >&2
    return 1
  }
  return 0
}

fm_executor_local_run() {  # <cwd> <profile> <lease> <argv...>
  local cwd=$1 profile=$2 lease=$3
  shift 3
  [ -d "$cwd" ] || {
    echo "error: local executor cwd '$cwd' is not a directory" >&2
    return 1
  }
  [ -z "$profile" ] || {
    echo "error: local executor does not accept a profile" >&2
    return 1
  }
  [ -z "$lease" ] || {
    echo "error: local executor does not accept a lease" >&2
    return 1
  }
  (
    cd "$cwd" || exit 1
    "$@"
  )
}

fm_executor_local_inspect() {  # <opaque-handle>
  echo "error: local executor has no provider handle to inspect" >&2
  return 1
}

fm_executor_local_logs() {  # <opaque-run-id>
  echo "error: local executor has no retained provider logs" >&2
  return 1
}

fm_executor_local_release() {  # <opaque-lease>
  [ -z "$1" ] || {
    echo "error: local executor does not accept a lease" >&2
    return 1
  }
  return 0
}
