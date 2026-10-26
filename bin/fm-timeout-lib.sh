#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback. An omp shell defines timeout as
#       a builtin; command -v reports that builtin, and invoking the name runs
#       it. timeout and gtimeout are selected only when type -P yields an
#       executable path, and that path is what fm_run_timed and fm_exec_timed
#       invoke, so a builtin or function of the same name cannot shadow the
#       runner.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks), and a command killed by
#       signal n, which reports 128+n on every mechanism - so a SIGKILLed child
#       is 137 and a SIGTERMed one 143, never the 0 a caller would read as
#       success. A signal-death status the wrapper records while the runner
#       already reports the bound is the bound's own TERM, not the command's
#       exit, and is reported as 124 too. Only 137 raised by GNU/BSD timeout's
#       own KILL escalation, with no status recorded by the bounded command,
#       also collapses into 124: there it means the bound fired, not that the
#       command chose to die.
#
#   fm_exec_timed <seconds> <grace-seconds> <command> [args...]
#       Replaces the calling shell with the bounded command, so it must be the
#       last command of a subshell: the bound kills the command, not the
#       caller. The command runs in its own process group; TERM goes to that
#       group at the bound, and KILL once <grace-seconds> more have passed,
#       for a command that ignores TERM or is mid-way through work it will not
#       abandon. A TERM, INT, or HUP delivered to the bounding process is
#       forwarded to the group and starts the same grace. The perl watchdog
#       also starts that escalation when its own parent dies before it could
#       be signalled (an owner torn down by an outer group-kill cannot leave
#       the bounded subtree orphaned behind it). The owner is captured before
#       the watchdog starts: FM_EXEC_TIMED_OWNER_PID when the caller names it,
#       else the calling script ($$) when fm_exec_timed runs in a subshell,
#       else the shell's parent. The escalation starts once that owner is gone
#       or the watchdog's parent changes, so an owner that dies while the
#       watchdog is still starting is detected too. The timeout/gtimeout
#       fallback does not track the owner: it bounds the command only by its
#       deadline and grace, so owner death alone does not stop the command.
#       Exit status is the command's own, except 124 (the bound was hit) or
#       137 (GNU timeout's status when its KILL had to fire); fm_timed_out
#       accepts both. The seconds and grace values must be positive integers
#       (125 otherwise). The perl watchdog is
#       preferred: once termination has begun it also KILLs whatever the group
#       left behind, so a descendant that outlives the command and holds its
#       output cannot keep a capturing caller waiting, and GNU timeout, the
#       fallback, cannot be followed by that reap from a replaced shell. A
#       descendant that moves into a process group of its own is outside both
#       signals and the reap (the Claude and Pi CLIs do this for every tool
#       command they run), so it ends only through the command's own TERM
#       handling; that is what the grace is for, and a command KILLed after
#       the grace can leave such a descendant running. With
#       no perl, timeout, or gtimeout on the host it refuses with 127 rather
#       than run unbounded: there is no bash fallback, because a monitor-mode
#       watchdog cannot replace the caller.
#
#   fm_timed_out <status>
#       0 iff <status> is how fm_run_timed or fm_exec_timed reports the bound.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four fm_run_timed mechanisms terminate the whole process GROUP, not just
# the direct child, so a hung grandchild (a vendor CLI spawned by a wrapper
# script, a git fetch spawned by a sweep) that remains in that group cannot
# outlive the bound. GNU/BSD `timeout` does this by default because it does not
# run the command in the foreground process group; the perl fallback does it
# explicitly with setpgid plus a negative pid, and the bash fallback uses
# monitor mode to give the bounded child its own process group before signaling
# its negative pid.
# Cancellation (TERM, INT, or HUP received while waiting) immediately KILLs
# the runner's owned group before exiting with 143, 130, or 129 respectively.
# Nested bounds create separate groups, and an outer runner may KILL this one
# as soon as its wrapper exits:
# cancellation cannot spend a grace period leaving that separate group alive.
# This is owned-group cleanup, not a recursive guarantee across nested groups.
# With three nested Perl runners, outer expiry can kill an inner watchdog before
# it cleans up its separate command group, leaving a native query running beyond
# the returned outer bound. The home-summary refresh -> fleet snapshot ->
# crew-state -> fm_nm_bounded path has this limitation.
# tests/fm-timeout-lib.test.sh covers two nested bounds, not that three-runner path.
set -u

# Print the PATH path of timeout, else gtimeout, when that path is executable.
fm_external_timeout_path() {
  local name timeout_path
  for name in timeout gtimeout; do
    timeout_path=$(type -P "$name" 2>/dev/null) || true
    if [ -n "$timeout_path" ] && [ -x "$timeout_path" ]; then
      printf '%s\n' "$timeout_path"
      return 0
    fi
  done
  return 1
}

fm_timeout_mechanism() {
  local timeout_path
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif timeout_path=$(fm_external_timeout_path); then
    printf '%s\n' "${timeout_path##*/}"
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

fm_run_bash_timeout() (
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  child_pid=''
  watchdog_pid=''
  trap 'rm -f "$command_status" "$deadline_status" 2>/dev/null || true' EXIT
  trap 'fm_run_bash_timeout_interrupt 143' TERM
  trap 'fm_run_bash_timeout_interrupt 130' INT
  trap 'fm_run_bash_timeout_interrupt 129' HUP
  # shellcheck disable=SC2329 # Invoked indirectly by the signal traps above.
  fm_run_bash_timeout_interrupt() {
    trap "" TERM INT HUP
    [ -z "$child_pid" ] || kill -KILL -- "-$child_pid" 2>/dev/null || true
    [ -z "$watchdog_pid" ] || kill -KILL -- "-$watchdog_pid" 2>/dev/null || true
    [ -z "$child_pid" ] || wait "$child_pid" 2>/dev/null || true
    [ -z "$watchdog_pid" ] || wait "$watchdog_pid" 2>/dev/null || true
    exit "$1"
  }
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
)

fm_run_external_timeout() (
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  runner_pid=
  trap 'rm -f "$status_file" 2>/dev/null || true' EXIT
  trap 'fm_run_external_timeout_interrupt 143' TERM
  trap 'fm_run_external_timeout_interrupt 130' INT
  trap 'fm_run_external_timeout_interrupt 129' HUP
  # shellcheck disable=SC2329 # Invoked indirectly by the signal traps above.
  fm_run_external_timeout_interrupt() {
    trap "" TERM INT HUP
    if [ -n "$runner_pid" ]; then
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      wait "$runner_pid" 2>/dev/null || true
    fi
    exit "$1"
  }
  # Run the executable path asynchronously (never a bare name: that is the omp
  # timeout builtin, and backgrounding it leaves $! empty) so its pid - also
  # the process-group id created by GNU/BSD timeout without --foreground -
  # remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@" <&0 &
  runner_pid=$!
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  if [ "${_FM_RUN_TIMED_RAW_STATUS:-0}" = 1 ]; then
    case "$runner_rc" in
      124|137) kill -KILL -- "-$runner_pid" 2>/dev/null || true ;;
    esac
    return "$runner_rc"
  fi
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$command_rc" -le 255 ]; then
        case "$runner_rc" in
          124) [ "$command_rc" -lt 128 ] && return "$command_rc" ;;
          *) return "$command_rc" ;;
        esac
      fi
      ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
)

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1 timeout_path
  shift
  case "$(fm_timeout_mechanism)" in
    timeout|gtimeout)
      timeout_path=$(fm_external_timeout_path) || return 127
      fm_run_external_timeout "$timeout_path" "$seconds" "$@"
      ;;
    perl)
      perl -MPOSIX=setpgid -e '
        my ($t, $raw_status) = (shift, shift);
        my ($pid, $pending) = (0, 0);
        sub terminate {
          my $rc = shift;
          $SIG{$_} = "IGNORE" for qw(ALRM TERM INT HUP);
          if ($rc == 124) {
            kill "TERM", -$pid;
            select undef, undef, undef, 0.2;
          }
          kill "KILL", -$pid;
          waitpid $pid, 0;
          exit $rc;
        }
        for my $pair ([ALRM => 124], [TERM => 143], [INT => 130], [HUP => 129]) {
          my ($sig, $rc) = @$pair;
          $SIG{$sig} = sub { $pid ? terminate($rc) : ($pending = $rc) };
        }
        my $child = fork;
        die "fork failed" unless defined $child;
        if (!$child) {
          $SIG{$_} = "DEFAULT" for qw(ALRM TERM INT HUP);
          setpgid(0, 0);
          exec @ARGV;
          exit 127;
        }
        setpgid($child, $child);
        $pid = $child;
        terminate($pending) if $pending;
        alarm $t;
        waitpid $pid, 0;
        exit($raw_status ? $? >> 8 : (($? & 127) ? 128 + ($? & 127) : $? >> 8));
      ' \
        "$seconds" "${_FM_RUN_TIMED_RAW_STATUS:-0}" "$@"
      ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}

fm_timed_out() {  # <status>
  case ${1:-} in
    124 | 137) return 0 ;;
  esac
  return 1
}

# The perl watchdog forks the command into its own process group (both sides
# call setpgid, so the group exists before either can signal it) and polls
# waitpid(WNOHANG) against wall-clock deadlines rather than using alarm+die,
# which keeps the bound off perl's platform-dependent syscall-restart signal
# semantics and off the drift of counting sleep intervals.
fm_exec_timed() {  # <seconds> <grace-seconds> <command...>
  local seconds=${1:-} grace=${2:-} value owner timeout_path
  for value in "$seconds" "$grace"; do
    case "$value" in
      '' | 0* | *[!0-9]*)
        echo "fm_exec_timed: usage: fm_exec_timed <positive-seconds> <positive-grace-seconds> <command> [args...]" >&2
        exit 125
        ;;
    esac
  done
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "fm_exec_timed: usage: fm_exec_timed <positive-seconds> <positive-grace-seconds> <command> [args...]" >&2
    exit 125
  fi
  owner=${FM_EXEC_TIMED_OWNER_PID:-$$}
  unset FM_EXEC_TIMED_OWNER_PID
  if command -v perl >/dev/null 2>&1; then
    exec perl -MPOSIX=WNOHANG,setpgid -MTime::HiRes=time -e '
      my ($bound, $grace, $owner, $shell_parent) = (shift, shift, shift, shift);
      # exec preserves the shell PID, including in Bash 3.2 subshells where
      # BASHPID is unavailable. Keep the pre-exec parent for startup races.
      $owner = $shell_parent if $owner == $$;
      my $parent = getppid();
      my ($pid, $pending, $kill_at, $timed_out) = (0, "", 0, 0);
      for my $sig (qw(TERM INT HUP)) {
        $SIG{$sig} = sub {
          if ($pid) { kill $sig, -$pid } else { $pending = $sig }
          $kill_at ||= time + $grace;
        };
      }
      my $child = fork;
      exit 127 unless defined $child;
      if ($child == 0) {
        $SIG{$_} = "DEFAULT" for qw(TERM INT HUP);
        setpgid(0, 0);
        exec @ARGV;
        exit 127;
      }
      setpgid($child, $child);
      $pid = $child;
      kill $pending, -$pid if $pending;
      my $deadline = time + $bound;
      sub finish {
        my $status = shift;
        kill "KILL", -$pid if $kill_at;
        exit 124 if $timed_out;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
      }
      while (1) {
        my $done = waitpid $pid, WNOHANG;
        finish($?) if $done == $pid;
        exit 127 if $done == -1;
        if ($kill_at) {
          if (time >= $kill_at) {
            kill "KILL", -$pid;
            waitpid $pid, 0;
            finish($?);
          }
        } elsif (time >= $deadline) {
          $timed_out = 1;
          $kill_at = time + $grace;
          kill "TERM", -$pid;
        } elsif (getppid() != $parent || !kill(0, $owner)) {
          $kill_at = time + $grace;
          kill "TERM", -$pid;
        }
        select undef, undef, undef, 0.05;
      }
    ' -- "$seconds" "$grace" "$owner" "$PPID" "$@"
  elif timeout_path=$(fm_external_timeout_path); then
    exec "$timeout_path" -k "$grace" "$seconds" "$@"
  fi
  printf 'fm_exec_timed: cannot bound %s within %ss: none of perl, timeout, or gtimeout is available\n' "${1##*/}" "$seconds" >&2
  exit 127
}
