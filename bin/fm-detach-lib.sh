# shellcheck shell=bash
# Portable detachment for firstmate's long-lived supervision processes.
# Usage: . bin/fm-wake-lib.sh; . bin/fm-detach-lib.sh
# It builds on fm-wake-lib.sh's pid helpers (fm_pid_alive, fm_pid_start), so
# source that first.
#
# Why this exists. On a background-notify primary (claude, grok) the watcher and
# the away-mode daemon are launched from a harness-tracked BACKGROUND TASK. When
# the harness reaps that task it SIGTERMs the task's whole PROCESS GROUP, so an
# ordinary child dies with its parent - which took supervision down entirely
# every time a background task was reaped. Escaping the process GROUP is what
# makes a supervision process survive; `nohup` and a bare `&` do not.
# The evidence (a process-group-kill measurement, and the guard-state table for a
# detached watcher) is recorded in docs/turnend-guard.md.
#
# Two primitives can escape the group, and supervision must never be unable to
# START, so fm_detach_spawn uses whichever the host has: `setsid(1)` where it
# exists (Linux), else perl fork + POSIX::setsid() - the same idiom bin/fm-watch.sh's
# run_check and bin/fm-watch-checkpoint.sh already use to put a timed child in its
# own process group, and the only one available on macOS, which has no setsid(1).
# With NEITHER on PATH there is no honest way to detach, so fm_detach_spawn fails
# loudly and names the fix rather than quietly returning no pid. Both paths meet
# the same contract and orphan the detached process immediately (the forking parent
# exits at once), so init reaps it and it never becomes a zombie of the caller.

# fm_detach_spawn <stdout-file> <command> [args...]
# Launch <command> in its OWN session and process group, with stdin on /dev/null
# and stdout+stderr on <stdout-file> (truncated), and print the detached pid. The
# caller is NOT the detached process's parent, so it cannot `wait` on it: poll the
# pid (see fm_detach_follow) instead. The child inherits the caller's environment,
# so FM_HOME and the rest of firstmate's context carry over unchanged.
fm_detach_spawn() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || return 2
  if command -v setsid >/dev/null 2>&1; then
    fm_detach_spawn_setsid "$out" "$@"
  elif command -v perl >/dev/null 2>&1; then
    fm_detach_spawn_perl "$out" "$@"
  else
    printf 'fm_detach_spawn: cannot detach %s: neither setsid(1) nor perl is on PATH.\n' "$1" >&2
    printf 'fm_detach_spawn: firstmate supervision cannot start without one - install perl, or util-linux for setsid(1).\n' >&2
    return 127
  fi
}

# setsid(1) execs the command into a fresh session, so the shell it execs is the
# detached process itself and reports its own pid. The backgrounded job is wrapped
# in a subshell that exits immediately, so the detached process is orphaned to init
# rather than left as a child of the caller (a dead child would linger as a zombie,
# which fm_detach_follow could not tell apart from a live one).
fm_detach_spawn_setsid() {
  local out=$1 pidfile pid i
  shift
  pidfile=$(mktemp "${TMPDIR:-/tmp}/fm-detach.XXXXXX") || return 1
  # shellcheck disable=SC2016 # single quotes are deliberate: $$ and $@ must expand in the DETACHED shell (its own pid, its own args), not in this one.
  ( setsid sh -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' fm-detach "$pidfile" "$@" < /dev/null > "$out" 2>&1 & )
  pid=
  i=0
  while [ "$i" -lt 100 ]; do
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  rm -f "$pidfile"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

fm_detach_spawn_perl() {
  local out=$1
  shift
  perl -e '
    use POSIX ();
    my $out = shift;
    my $pid = fork();
    die "fork failed: $!\n" unless defined $pid;
    if (!$pid) {
      POSIX::setsid();
      open(STDIN, "<", "/dev/null") or die "cannot read /dev/null: $!\n";
      open(STDOUT, ">", $out) or die "cannot write $out: $!\n";
      open(STDERR, ">&", \*STDOUT) or die "cannot dup stdout: $!\n";
      exec { $ARGV[0] } @ARGV or die "exec failed: $!\n";
    }
    print "$pid\n";
  ' "$out" "$@"
}

# fm_detach_follow <pid> [poll-seconds]
# Block until the process now running as <pid> is gone. A harness-tracked task
# calls this to become the FOLLOWER of the detached process it just launched: the
# task stays live for as long as that process lives, so the harness still sees
# exactly one live background task and its completion still wakes the primary. The
# inversion that matters: a reap of the follower does NOT touch the detached
# process, where killing the follower's own child (the old shape) killed
# supervision outright.
# The follow is pinned to the followed process's START TIME, the exec-stable half
# of fm_pid_identity (a freshly detached process's command line still changes when
# it execs the target, its start time does not). A recycled pid therefore ENDS the
# follow rather than trapping it: an unbounded `kill -0` poll would keep the
# harness task live forever behind an unrelated process, and the wake the watcher
# already enqueued would sit undrained. Callers that need a stronger identity than
# "same process" - the arm's attach path, which also demands the singleton lock and
# a fresh beacon - poll that themselves; this is the floor every follower needs,
# including the away-mode daemon's, which has no watcher lock to match against.
fm_detach_follow() {
  local pid=$1 poll=${2:-0.5} start
  start=$(fm_pid_start "$pid") || return 0
  while fm_pid_alive "$pid" && [ "$(fm_pid_start "$pid")" = "$start" ]; do
    sleep "$poll"
  done
}
