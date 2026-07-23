#!/usr/bin/env bash
# Shared bounded command runner for operations whose descendants must be
# terminated and reaped before the caller releases lifecycle or Git locks.
# Usage: fm_run_bounded <positive-seconds> <command> [args...]

fm_run_bounded() {
  local seconds=$1
  shift
  command -v perl >/dev/null 2>&1 || {
    echo "error: perl is required for bounded process-tree control" >&2
    return 127
  }
  # shellcheck disable=SC2016
  perl -MPOSIX=:sys_wait_h -e '
    sub remember_descendants {
      my ($seen) = @_;
      my %children;
      open my $ps, "-|", "ps", "-axo", "pid=,ppid=" or return;
      while (<$ps>) {
        my ($pid, $ppid) = /(\d+)\s+(\d+)/;
        push @{$children{$ppid}}, $pid if defined $pid;
      }
      close $ps;
      my @queue = keys %$seen;
      for (my $i = 0; $i < @queue; $i++) {
        for my $child (@{$children{$queue[$i]} || []}) {
          next if $seen->{$child}++;
          push @queue, $child;
        }
      }
    }
    sub alive {
      grep { kill 0, $_ } @_;
    }
    sub stop_seen {
      my ($seen) = @_;
      remember_descendants($seen);
      my @targets = alive(keys %$seen);
      kill "TERM", reverse @targets if @targets;
      for (1 .. 20) {
        remember_descendants($seen);
        @targets = alive(keys %$seen);
        last unless @targets;
        select undef, undef, undef, 0.05;
      }
      remember_descendants($seen);
      @targets = alive(keys %$seen);
      kill "KILL", reverse @targets if @targets;
      for (1 .. 20) {
        last unless alive(keys %$seen);
        select undef, undef, undef, 0.05;
      }
    }
    sub exit_status {
      my ($status) = @_;
      return ($status & 127) ? 128 + ($status & 127) : $status >> 8;
    }
    my $timeout = shift;
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) {
      exec @ARGV;
      exit 127;
    }
    my %seen = ($pid => 1);
    my $timed_out = 0;
    local $SIG{ALRM} = sub { $timed_out = 1 };
    alarm $timeout;
    my $status;
    while (1) {
      remember_descendants(\%seen);
      my $waited = waitpid $pid, WNOHANG;
      if ($waited == $pid) {
        $status = $?;
        last;
      }
      if ($timed_out) {
        stop_seen(\%seen);
        waitpid $pid, 0;
        alarm 0;
        exit 124;
      }
      select undef, undef, undef, 0.01;
    }
    alarm 0;
    stop_seen(\%seen);
    exit exit_status($status);
  ' "$seconds" "$@"
}
