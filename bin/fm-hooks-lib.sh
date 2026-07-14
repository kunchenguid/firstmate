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
# group, polls it in sub-second ticks against the budget, then signals the whole
# group with SIGTERM followed by SIGKILL after a 5s grace, so even a hook that
# traps or ignores SIGTERM is stopped with no external binary. FM_HOOK_TIMEOUT=0
# is the only opt-out: it runs the hook with no time limit.
#
# Hooks never inherit the caller's stdout or stderr. A hook may exit cleanly and
# still leave a background descendant alive (a &-ed notifier, a nohup-ed sync),
# which no timeout and no process-group kill can reach, and such an orphan would
# hold whichever of firstmate's pipes it inherited open for as long as it lives -
# stalling a caller that reads this output through a command substitution (the
# session-start liveness sweep in bin/fm-bootstrap.sh captures fm-spawn.sh with
# out=$(... 2>&1), so both pipes are exposed). So every path - the timeout-binary
# path, the shell-watchdog path, and the unbounded FM_HOOK_TIMEOUT=0 path - runs
# the hook with stdout discarded and stderr captured to a temp file, which is
# relayed to firstmate's own stderr once the hook is done. Diagnostics still
# reach the operator; an orphaned descendant can hold nothing but the temp file,
# so firstmate can never be stalled by a hook. Only stdin stays inherited.
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

# fm_hook_errfile
# Print the path of a fresh empty file to capture one hook's stderr into, so the
# hook never holds firstmate's own stderr. Falls back to a pid-keyed name when
# mktemp is unavailable. Always returns 0.
fm_hook_errfile() {
  local dir="${TMPDIR:-/tmp}" file
  file=$(mktemp "${dir%/}/fm-hook-err.XXXXXX" 2>/dev/null) ||
    file="${dir%/}/fm-hook-err.$$"
  : > "$file" 2>/dev/null || true
  printf '%s\n' "$file"
}

# fm_hook_drain_errfile <file>
# Relay a finished hook's captured stderr to firstmate's stderr, then drop the
# file. Uses only builtins to read, so it works on a minimal PATH. Returns 0.
fm_hook_drain_errfile() {
  local file=$1 line
  if [ -s "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$line" >&2
    done < "$file"
  fi
  rm -f "$file" 2>/dev/null || true
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
  local task_label=${1:-} timed_out=0 hook_err
  hook_err=$(fm_hook_errfile)
  if [ -n "$timeout_bin" ]; then
    env ${hook_env[@]+"${hook_env[@]}"} "$timeout_bin" -k 5 "$budget" "$hook" "$@" \
      0<&0 >/dev/null 2>"$hook_err" || hook_status=$?
  elif [ "$budget" -eq 0 ]; then
    env ${hook_env[@]+"${hook_env[@]}"} "$hook" "$@" 0<&0 >/dev/null 2>"$hook_err" || hook_status=$?
  else
    # Job control puts the hook in its own process group (pgid == its pid), so
    # the kills below reach its descendants too, matching what 'timeout' does.
    # SECONDS, not a tick count, measures the budget, so the bound holds even if
    # a poll sleep is short-circuited.
    local hook_pid started grace_started job_control=0
    case "$-" in *m*) job_control=1 ;; esac
    set -m
    env ${hook_env[@]+"${hook_env[@]}"} "$hook" "$@" 0<&0 >/dev/null 2>"$hook_err" &
    hook_pid=$!
    [ "$job_control" -eq 1 ] || set +m
    started=$SECONDS
    while kill -0 "$hook_pid" 2>/dev/null; do
      if [ "$((SECONDS - started))" -ge "$budget" ]; then
        timed_out=1
        fm_hook_signal_group TERM "$hook_pid"
        grace_started=$SECONDS
        while [ "$((SECONDS - grace_started))" -lt 5 ] && kill -0 "$hook_pid" 2>/dev/null; do
          sleep 0.2 || true
        done
        fm_hook_signal_group KILL "$hook_pid"
        break
      fi
      sleep 0.2 || true
    done
    wait "$hook_pid" 2>/dev/null || hook_status=$?
  fi
  fm_hook_drain_errfile "$hook_err"
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
