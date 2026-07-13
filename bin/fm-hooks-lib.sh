#!/usr/bin/env bash
# Shared best-effort runner for the local lifecycle hook points
# (config/hooks/<hook-name>; docs/extension-points.md owns the hook-point
# catalog and the operator-facing contract).
#
# A hook is an optional local, gitignored executable an operator installs at
# a documented lifecycle point; firstmate ships none, so an absent hook is a
# complete no-op with zero behavior change for anyone not using it.
#
# Hooks are purely additive fleet-local wiring and NEVER gate the calling flow:
# a missing or non-executable hook is silently skipped, a hook that exits
# non-zero is warned to stderr and swallowed, and the caller continues either
# way (fm_hook_run always returns 0). A hang cannot gate the flow either: the
# hook runs under a time budget of FM_HOOK_TIMEOUT seconds (default 120) via
# 'timeout' or macOS 'gtimeout' with a 5s kill-after grace, so even a hook that
# traps or ignores SIGTERM is stopped, and a timed-out hook is warned and
# skipped exactly like a failing one. FM_HOOK_TIMEOUT=0 is a deliberate opt-out
# that runs the hook with no time limit. When neither timeout binary exists the
# hook runs unbounded after a stderr warning - a missing timeout binary never
# fails the calling flow.
#
# Each hook receives its values both as positional arguments and as FM_HOOK_*
# environment variables, so a hook can read whichever is convenient; the
# per-hook argument and environment sets are listed in docs/extension-points.md.
# By convention the first positional argument is the task id, which the runner
# also uses to label its warnings.

# fm_hook_run <config-dir> <hook-name> [NAME=VALUE ...] -- <arg>...
# Run <config-dir>/hooks/<hook-name> with the given positional arguments and
# with each NAME=VALUE pair exported into its environment.
# A no-op (return 0) when the hook is absent or not executable. Non-fatal: a
# failing or timed-out hook is warned to stderr and this function still
# returns 0 so the calling flow continues. Bounded by FM_HOOK_TIMEOUT as
# described in the header. Always returns 0.
fm_hook_run() {
  local config_dir=$1 hook_name=$2
  shift 2
  local hook_env=()
  while [ $# -gt 0 ]; do
    case $1 in
      --) shift; break ;;
      *) hook_env+=("$1"); shift ;;
    esac
  done
  local hook="$config_dir/hooks/$hook_name"
  [ -f "$hook" ] && [ -x "$hook" ] || return 0
  local budget="${FM_HOOK_TIMEOUT:-120}" timeout_bin="" hook_status=0
  case "$budget" in
    ''|*[!0-9]*) budget=120 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  fi
  local task_label=${1:-}
  if [ -n "$timeout_bin" ]; then
    env ${hook_env[@]+"${hook_env[@]}"} "$timeout_bin" -k 5 "$budget" "$hook" "$@" || hook_status=$?
  else
    echo "warning: neither 'timeout' nor 'gtimeout' on PATH; $hook_name hook for $task_label runs unbounded" >&2
    env ${hook_env[@]+"${hook_env[@]}"} "$hook" "$@" || hook_status=$?
  fi
  if [ "$hook_status" -ne 0 ]; then
    if [ -n "$timeout_bin" ] && { [ "$hook_status" -eq 124 ] || [ "$hook_status" -eq 137 ]; }; then
      echo "warning: $hook_name hook timed out after ${budget}s for $task_label; continuing" >&2
    else
      echo "warning: $hook_name hook failed (exit $hook_status) for $task_label; continuing" >&2
    fi
  fi
  return 0
}
