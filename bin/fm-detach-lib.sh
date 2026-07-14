# shellcheck shell=bash
# Portable detachment for firstmate's long-lived supervision processes.
# Usage: . bin/fm-detach-lib.sh
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
# `setsid(1)` does not exist on macOS, so the portable primitive is perl
# fork + POSIX::setsid() - the same idiom bin/fm-watch.sh's run_check and
# bin/fm-watch-checkpoint.sh already use to put a timed child in its own process
# group. The detached process is orphaned immediately (the forking perl exits at
# once), so init reaps it and it never becomes a zombie of the caller.

# fm_detach_spawn <stdout-file> <command> [args...]
# Launch <command> in its OWN session and process group, with stdin on /dev/null
# and stdout+stderr on <stdout-file>, and print the detached pid. The caller is
# NOT the detached process's parent, so it cannot `wait` on it: poll the pid (see
# fm_detach_follow) instead. The child inherits the caller's environment, so
# FM_HOME and the rest of firstmate's context carry over unchanged.
fm_detach_spawn() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || return 2
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
# Block until <pid> is gone. A harness-tracked task calls this to become the
# FOLLOWER of the detached process it just launched: the task stays live for as
# long as that process lives, so the harness still sees exactly one live
# background task and its completion still wakes the primary. The inversion that
# matters: a reap of the follower does NOT touch the detached process, where
# killing the follower's own child (the old shape) killed supervision outright.
fm_detach_follow() {
  local pid=$1 poll=${2:-0.5}
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$poll"
  done
}
