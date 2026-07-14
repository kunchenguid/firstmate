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
# the hook with stdout discarded and stderr captured to a private temp file,
# which is relayed to firstmate's own stderr once the hook is done. Diagnostics
# still reach the operator; an orphaned descendant can hold nothing but that temp
# file, so firstmate can never be stalled by a hook. Only stdin stays inherited.
#
# The relay is bounded at FM_HOOK_STDERR_MAX_BYTES (default 65536): a chatty or
# looping hook gets its first bytes relayed and the rest discarded with an
# explicit truncation warning, so it can never dump an unbounded volume into a
# caller that captures firstmate's output - bin/fm-bootstrap.sh's session-start
# liveness sweep reads fm-spawn.sh through out=$(... 2>&1) straight into the
# session-start digest.
#
# The temp file is created private (mode 0600, and never through a pre-planted
# symlink) and is unlinked as soon as the runner holds its descriptors, so hook
# stderr - which can carry tokens or URLs - is never readable by another user and
# nothing is left behind in TMPDIR even if firstmate is interrupted mid-hook. Its
# blocks are reclaimed the moment the hook and any descendant holding the
# inherited descriptor exit, so a runaway hook's stderr is transient rather than
# accumulating in TMPDIR.
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
# Print the path of a freshly created private (0600) empty file to capture one
# hook's stderr into, so the hook never holds firstmate's own stderr. When mktemp
# is unavailable, falls back to creating a pid-keyed name under 'set -C', which
# refuses to follow a symlink or clobber an existing path rather than letting a
# pre-planted name in a shared TMPDIR redirect the write. Prints nothing when no
# private file could be created, which the caller reads as "discard the stderr".
# Always returns 0.
fm_hook_errfile() {
  local dir="${TMPDIR:-/tmp}" file="" candidate n=0
  file=$(umask 077; mktemp "${dir%/}/fm-hook-err.XXXXXX" 2>/dev/null) || file=""
  if [ -z "$file" ]; then
    while [ "$n" -lt 20 ]; do
      candidate="${dir%/}/fm-hook-err.$$.$n"
      if (umask 077; set -C; : > "$candidate") 2>/dev/null; then
        file=$candidate
        break
      fi
      n=$((n + 1))
    done
  fi
  printf '%s\n' "$file"
}

# fm_hook_drain_errfd <hook-name> <task-label>
# Relay a finished hook's captured stderr - held open on fd 9 by fm_hook_run,
# whose file is already unlinked - to firstmate's stderr, up to
# FM_HOOK_STDERR_MAX_BYTES (default 65536). Beyond that the rest is discarded and
# the truncation is warned, so a chatty or looping hook cannot flood a caller that
# captures firstmate's output. Reads in fixed chunks with builtins only, so it
# works on a minimal PATH and an enormous single line is bounded too. Returns 0.
fm_hook_drain_errfd() {
  local hook_name=$1 task_label=$2
  local chunk relayed=0 truncated=0 tail_char=""
  # 'read -N' and ${#chunk} count characters, so the cap is only a byte cap in a
  # single-byte locale; without this a multibyte hook's stderr relays several
  # times FM_HOOK_STDERR_MAX_BYTES. Bash re-reads the locale on assignment and
  # again when this local goes out of scope, so the caller's locale is unchanged.
  local LC_ALL=C
  local max="${FM_HOOK_STDERR_MAX_BYTES:-65536}"
  case "$max" in
    ''|*[!0-9]*) max=65536 ;;
  esac
  while [ "$relayed" -lt "$max" ]; do
    chunk=""
    IFS= read -r -N 4096 chunk <&9 || true
    [ -n "$chunk" ] || break
    if [ "$((relayed + ${#chunk}))" -gt "$max" ]; then
      chunk=${chunk:0:$((max - relayed))}
      truncated=1
    fi
    printf '%s' "$chunk" >&2
    relayed=$((relayed + ${#chunk}))
    tail_char=${chunk: -1}
  done
  if [ "$truncated" -eq 0 ] && [ "$relayed" -ge "$max" ]; then
    chunk=""
    IFS= read -r -N 1 chunk <&9 || true
    [ -z "$chunk" ] || truncated=1
  fi
  if [ -n "$tail_char" ] && [ "$tail_char" != $'\n' ]; then
    printf '\n' >&2
  fi
  if [ "$truncated" -eq 1 ]; then
    echo "warning: $hook_name hook stderr truncated after ${max} bytes for $task_label; the rest was discarded" >&2
  fi
  return 0
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
  local task_label=${1:-} timed_out=0 hook_err have_errfd=0
  # fd 8 is the hook's stderr and fd 9 reads it back; the file is unlinked at
  # once, so nothing survives an interrupt and only these descriptors can reach
  # it. The hook gets neither fd, just its stderr on a copy of fd 8.
  hook_err=$(fm_hook_errfile)
  # SC2094 reads this as reading and writing one file by accident; opening both
  # ends of the same file is the point - fd 8 is what the hook writes its stderr
  # to and fd 9 is how the runner reads it back once the file is unlinked.
  # shellcheck disable=SC2094
  if [ -n "$hook_err" ] && exec 8>"$hook_err" 9<"$hook_err"; then
    have_errfd=1
    rm -f "$hook_err" 2>/dev/null || true
  else
    exec 8>/dev/null
  fi
  # Every launch below hands the hook stdout on /dev/null and stderr on a copy of
  # fd 8, and keeps fd 8 and fd 9 out of its table; stdin stays inherited.
  if [ "$budget" -eq 0 ]; then
    # The documented opt-out: no time limit at all, on every host, rather than
    # relying on a timeout binary's own "a duration of 0 disables it" semantics.
    env ${hook_env[@]+"${hook_env[@]}"} "$hook" "$@" \
      >/dev/null 2>&8 8>&- 9<&- || hook_status=$?
  else
    if command -v timeout >/dev/null 2>&1; then
      timeout_bin=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_bin=gtimeout
    fi
    if [ -n "$timeout_bin" ]; then
      env ${hook_env[@]+"${hook_env[@]}"} "$timeout_bin" -k 5 "$budget" "$hook" "$@" \
        >/dev/null 2>&8 8>&- 9<&- || hook_status=$?
    else
      # Job control puts the hook in its own process group (pgid == its pid), so
      # the kills below reach its descendants too, matching what 'timeout' does,
      # and it also keeps the backgrounded hook's stdin inherited rather than
      # redirected from /dev/null, as on the two foreground paths.
      # SECONDS, not a tick count, measures the budget, so the bound holds even
      # if a poll sleep is short-circuited. It counts whole-second boundaries
      # crossed since the hook started, so it reaches N somewhere between N-1 and
      # N real seconds; the kill therefore waits for it to EXCEED the budget,
      # which is what makes a short budget still give the hook its full time
      # rather than killing it the instant the first boundary happens to fall.
      local hook_pid started grace_started job_control=0
      case "$-" in *m*) job_control=1 ;; esac
      set -m
      env ${hook_env[@]+"${hook_env[@]}"} "$hook" "$@" \
        >/dev/null 2>&8 8>&- 9<&- &
      hook_pid=$!
      [ "$job_control" -eq 1 ] || set +m
      started=$SECONDS
      while kill -0 "$hook_pid" 2>/dev/null; do
        if [ "$((SECONDS - started))" -gt "$budget" ]; then
          timed_out=1
          fm_hook_signal_group TERM "$hook_pid"
          grace_started=$SECONDS
          while [ "$((SECONDS - grace_started))" -le 5 ] && kill -0 "$hook_pid" 2>/dev/null; do
            sleep 0.2 || true
          done
          fm_hook_signal_group KILL "$hook_pid"
          break
        fi
        sleep 0.2 || true
      done
      wait "$hook_pid" 2>/dev/null || hook_status=$?
    fi
  fi
  exec 8>&-
  if [ "$have_errfd" -eq 1 ]; then
    fm_hook_drain_errfd "$hook_name" "$task_label"
    exec 9<&-
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

# fm_hook_pr_ready_once <config-dir> <meta-path> <task-id> <pr-url>
# Fire the pr-ready hook for a task's PR URL exactly once, ever. The fire is
# recorded in the task's meta as pr_ready_hook=<url> and gated on that marker,
# not on whether this run is the one that appended pr=<url>: pr= is recorded by
# bin/fm-pr-check.sh but the hook is fired after work that can fail in between
# (bin/fm-pr-merge.sh's merge), and inferring the fire from the pr= transition
# would drop it forever the moment that work failed - pr= is already recorded, so
# no retry would ever see the transition again. Marking the fire itself keeps the
# guarantee across a failed merge, a retry, and a re-run alike.
# A task with no meta has nowhere to record the fire, so the hook is skipped.
# Always returns 0; fm_hook_run never gates its caller.
fm_hook_pr_ready_once() {
  local config_dir=$1 meta=$2 id=$3 url=$4
  [ -f "$meta" ] || return 0
  ! grep -qxF "pr_ready_hook=$url" "$meta" || return 0
  fm_hook_run "$config_dir" pr-ready \
    "FM_HOOK_TASK_ID=$id" "FM_HOOK_PR_URL=$url" \
    -- "$id" "$url"
  echo "pr_ready_hook=$url" >> "$meta"
  return 0
}
