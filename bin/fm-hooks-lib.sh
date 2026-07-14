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
# the hook with stdout discarded and stderr captured, which is relayed to
# firstmate's own stderr once the hook is done. Diagnostics still reach the
# operator; an orphaned descendant can hold nothing firstmate waits on, so
# firstmate can never be stalled by a hook. Only stdin stays inherited.
#
# The capture is bounded at both ends by FM_HOOK_STDERR_MAX_BYTES (default 65536).
# The hook's stderr is a pipe drained by fm_hook_cap_writer, which keeps at most
# that many bytes in a private temp file and reads and discards the rest, and the
# relay out of that file is capped at the same size with an explicit truncation
# warning. So a chatty or looping hook can neither dump an unbounded volume into a
# caller that captures firstmate's output - bin/fm-bootstrap.sh's session-start
# liveness sweep reads fm-spawn.sh through out=$(... 2>&1) straight into the
# session-start digest - nor fill TMPDIR, and neither can a background descendant
# that survives the hook still holding that pipe.
#
# The temp file is created private (mode 0600, and never through a pre-planted
# symlink) and is unlinked as soon as the runner and the cap writer hold its
# descriptors, so hook stderr - which can carry tokens or URLs - is never readable
# by another user and nothing is left behind in TMPDIR even if firstmate is
# interrupted mid-hook.
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

# fm_hook_max_stderr_bytes
# Print the stderr cap, FM_HOOK_STDERR_MAX_BYTES (default 65536), ignoring a
# non-numeric setting. Always returns 0.
fm_hook_max_stderr_bytes() {
  local max="${FM_HOOK_STDERR_MAX_BYTES:-65536}"
  case "$max" in
    ''|*[!0-9]*) max=65536 ;;
  esac
  printf '%s\n' "$max"
}

# fm_hook_cap_writer <max>
# Copy stdin - the pipe the hook writes its stderr into - to fd 8, the private,
# already-unlinked capture file, keeping at most <max>+1 bytes of it on disk and
# reading and discarding everything past that. The one byte over the cap is what
# lets fm_hook_drain_errfd tell a capped stream from an exactly-cap-sized one, so
# it can warn about the truncation.
# The hook writes into this pipe rather than straight into the file so that the
# on-disk size is bounded by firstmate rather than by the hook's restraint: a
# looping hook - or a background descendant that outlives it still holding the
# pipe - can neither grow the file until TMPDIR is full nor block on a pipe nobody
# reads. Reads on a timeout, so a partial chunk still reaches the file while such
# a survivor keeps the pipe open and EOF never comes. Builtins only, so it works
# on a minimal PATH. Always returns 0.
fm_hook_cap_writer() {
  local limit=$(($1 + 1))
  local chunk rc keep written=0 fd=3
  local LC_ALL=C
  # This is the one process that can outlive the hook - a descendant that survives
  # it keeps the pipe open, so this keeps reading - which means it must hold none
  # of firstmate's own descriptors, or it would stall a caller capturing
  # firstmate's output exactly as the orphan itself would. Inheriting them is not
  # hypothetical: bash saves the descriptors it redirects for a coprocess to high
  # fds in this child, so firstmate's stdout and stderr are both still in here,
  # alongside anything else the caller holds open (a lock, the capture file's read
  # end). Everything but stdin (the hook's stderr), stdout (the pipe whose EOF
  # tells firstmate this writer is done), and fd 8 (the capture file) is dropped.
  while [ "$fd" -le 30 ]; do
    [ "$fd" -eq 8 ] || eval "exec $fd>&-" 2>/dev/null || true
    fd=$((fd + 1))
  done
  exec 2>/dev/null || true
  while :; do
    chunk=""
    rc=0
    IFS= read -r -N 4096 -t 1 chunk || rc=$?
    if [ -n "$chunk" ] && [ "$written" -lt "$limit" ]; then
      keep=${chunk:0:$((limit - written))}
      printf '%s' "$keep" >&8 || true
      written=$((written + ${#keep}))
    fi
    # rc 0 is a full chunk and anything above 128 is the read's own timeout; only
    # a plain failure means EOF, which is the one thing that ends the drain.
    [ "$rc" -eq 0 ] || [ "$rc" -gt 128 ] || break
  done
  return 0
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
  local max
  max=$(fm_hook_max_stderr_bytes)
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
  local task_label=${1:-} timed_out=0 hook_err have_errfd=0 cap_done_fd=
  # fd 8 writes the capture file and fd 9 reads it back; the file is unlinked at
  # once, so nothing survives an interrupt and only these descriptors can reach
  # it. The hook gets neither: its stderr is a pipe into fm_hook_cap_writer, which
  # owns fd 8 and is what keeps the file inside the stderr cap no matter how much
  # the hook, or a descendant that outlives it, writes.
  hook_err=$(fm_hook_errfile)
  # SC2094 reads this as reading and writing one file by accident; opening both
  # ends of the same file is the point - fd 8 is what the cap writer writes the
  # captured stderr to and fd 9 is how the runner reads it back once the file is
  # unlinked.
  # shellcheck disable=SC2094
  if [ -n "$hook_err" ] && exec 8>"$hook_err" 9<"$hook_err"; then
    have_errfd=1
    rm -f "$hook_err" 2>/dev/null || true
    # The cap writer forks here, inheriting fd 8 (the file) and reading the hook's
    # stderr from its stdin pipe. A previous hook's cap writer can still be alive
    # draining an orphan's pipe, and bash warns when it replaces a live coproc;
    # that warning is noise here, not a problem, so it is kept out of firstmate's
    # stderr.
    { coproc FM_HOOK_CAP { fm_hook_cap_writer "$(fm_hook_max_stderr_bytes)"; } } 2>/dev/null
    # Copied now: bash clears the array once it reaps the cap writer, and the
    # relay below still needs its stdout to wait on.
    cap_done_fd=${FM_HOOK_CAP[0]}
    # fd 8 becomes the pipe into the cap writer, which now solely owns the file.
    # A plain fd, not the coproc's own: bash closes coproc descriptors in every
    # subshell, and the watchdog path runs the hook as a background job.
    exec 8>&"${FM_HOOK_CAP[1]}"
    eval "exec ${FM_HOOK_CAP[1]}>&-"
  else
    exec 8>/dev/null
  fi
  # Every launch below hands the hook stdout on /dev/null and stderr on a copy of
  # fd 8, and keeps fd 8 itself and fd 9 out of its table; stdin stays inherited.
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
  if [ "$have_errfd" -eq 1 ]; then
    # Closing firstmate's end of the pipe is EOF for the cap writer, which then
    # flushes and exits, closing its stdout - so reading that stdout to EOF is how
    # firstmate knows the capture is complete before it relays it. A descendant
    # that outlived the hook still holds the pipe, so the cap writer cannot exit
    # then; the read's timeout is what keeps such an orphan from stalling the
    # relay, and the cap writer's own read timeout has already flushed the hook's
    # stderr to the file by the time it expires.
    exec 8>&-
    IFS= read -r -t 3 -u "$cap_done_fd" _ 2>/dev/null || true
    eval "exec ${cap_done_fd}<&-" 2>/dev/null || true
    fm_hook_drain_errfd "$hook_name" "$task_label"
    exec 9<&-
  else
    exec 8>&-
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
# Fire an installed pr-ready hook for a task's PR URL at least once, and normally
# exactly once. The fire is recorded in the task's meta as pr_ready_hook=<url> and
# gated on that marker, not on whether this run is the one that appended pr=<url>:
# pr= is recorded by bin/fm-pr-check.sh but the hook is fired after work that can
# fail in between (bin/fm-pr-merge.sh's merge), and inferring the fire from the
# pr= transition would drop it forever the moment that work failed - pr= is
# already recorded, so no retry would ever see the transition again. Marking the
# fire itself keeps the guarantee across a failed merge, a retry, and a re-run
# alike. The marker is written after the hook returns, so the one way the hook
# fires twice is firstmate being hard-interrupted inside the hook's execution
# window, leaving no marker for the next run to see. That is the deliberate side
# to err on - writing the marker first would drop the fire entirely on the same
# interrupt - so a pr-ready hook should be idempotent for a (task, PR URL) pair.
# A task with no meta has nowhere to record the fire, so the hook is skipped.
# Nothing is recorded when no pr-ready hook is installed: firstmate ships none, so
# an operator without one gets exactly the meta they got before hook points
# existed.
# Always returns 0; fm_hook_run never gates its caller.
fm_hook_pr_ready_once() {
  local config_dir=$1 meta=$2 id=$3 url=$4
  local hook="$config_dir/hooks/pr-ready"
  [ -f "$hook" ] && [ -x "$hook" ] || return 0
  [ -f "$meta" ] || return 0
  ! grep -qxF "pr_ready_hook=$url" "$meta" || return 0
  fm_hook_run "$config_dir" pr-ready \
    "FM_HOOK_TASK_ID=$id" "FM_HOOK_PR_URL=$url" \
    -- "$id" "$url"
  echo "pr_ready_hook=$url" >> "$meta"
  return 0
}
