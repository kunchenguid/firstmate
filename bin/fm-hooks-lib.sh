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
# hook always runs under a time budget of FM_HOOK_TIMEOUT seconds (default 120),
# and a timed-out hook is warned and skipped exactly like a failing one. The
# budget is enforced by 'timeout' or macOS 'gtimeout' with a 5s kill-after grace
# when either is on PATH, and otherwise - the stock macOS case, which ships
# neither - by a shell-native watchdog that runs the hook in its own process
# group, polls it in whole-second ticks against the budget, then signals the
# whole group with SIGTERM followed by SIGKILL after a 5s grace, so even a hook
# that traps or ignores SIGTERM is stopped with no external binary. Both bounded
# paths signal the process group, not just the hook itself, so a hook blocked in
# a descendant leaves no orphan holding the caller's stdout: a caller reading
# fm_hook_run's output through a command substitution can never be stalled by
# one. FM_HOOK_TIMEOUT=0 is the only opt-out: it runs the hook with no time
# limit. Every path runs the hook with the caller's own stdio.
#
# Each hook receives its values both as positional arguments and as FM_HOOK_*
# environment variables, so a hook can read whichever is convenient; the
# per-hook argument and environment sets are listed in docs/extension-points.md.
# By convention the first positional argument is the task id, which the runner
# also uses to label its warnings.

# fm_hook_signal_group <signal> <pid>
# Signal the hook's process group, falling back to the bare pid if the group is
# already gone or was never created. Always returns 0.
fm_hook_signal_group() {
  local sig=$1 pid=$2
  kill "-$sig" "-$pid" 2>/dev/null ||
    kill "-$sig" "$pid" 2>/dev/null ||
    true
}

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
  local task_label=${1:-} timed_out=0
  if [ -n "$timeout_bin" ]; then
    env ${hook_env[@]+"${hook_env[@]}"} "$timeout_bin" -k 5 "$budget" "$hook" "$@" 0<&0 || hook_status=$?
  elif [ "$budget" -eq 0 ]; then
    env ${hook_env[@]+"${hook_env[@]}"} "$hook" "$@" 0<&0 || hook_status=$?
  else
    # Job control puts the hook in its own process group (pgid == its pid), so
    # the kills below reach its descendants too, matching what 'timeout' does.
    local hook_pid elapsed=0 grace=0 job_control=0
    case "$-" in *m*) job_control=1 ;; esac
    set -m
    env ${hook_env[@]+"${hook_env[@]}"} "$hook" "$@" 0<&0 &
    hook_pid=$!
    [ "$job_control" -eq 1 ] || set +m
    while kill -0 "$hook_pid" 2>/dev/null; do
      if [ "$elapsed" -ge "$budget" ]; then
        timed_out=1
        fm_hook_signal_group TERM "$hook_pid"
        while [ "$grace" -lt 5 ] && kill -0 "$hook_pid" 2>/dev/null; do
          sleep 1 || true
          grace=$((grace + 1))
        done
        fm_hook_signal_group KILL "$hook_pid"
        break
      fi
      sleep 1 || true
      elapsed=$((elapsed + 1))
    done
    wait "$hook_pid" 2>/dev/null || hook_status=$?
  fi
  if [ "$hook_status" -ne 0 ]; then
    if [ "$timed_out" -eq 1 ] ||
      { [ -n "$timeout_bin" ] && { [ "$hook_status" -eq 124 ] || [ "$hook_status" -eq 137 ]; }; }; then
      echo "warning: $hook_name hook timed out after ${budget}s for $task_label; continuing" >&2
    else
      echo "warning: $hook_name hook failed (exit $hook_status) for $task_label; continuing" >&2
    fi
  fi
  return 0
}
