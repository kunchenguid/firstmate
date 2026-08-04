#!/usr/bin/env bash
set -u

usage() {
  echo "usage: fm-evidence-run.sh <--total|--progress> <seconds> <command> [args...]" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
MODE=$1
TIME_LIMIT=$2
shift 2
case "$MODE" in --total|--progress) ;; *) usage ;; esac
case "$TIME_LIMIT" in ''|*[!0-9]*|0) usage ;; esac

if [ "$MODE" = --total ] && command -v timeout >/dev/null 2>&1; then
  exec timeout -k 1 "$TIME_LIMIT" "$@"
fi
if [ "$MODE" = --total ] && command -v gtimeout >/dev/null 2>&1; then
  exec gtimeout -k 1 "$TIME_LIMIT" "$@"
fi

if command -v perl >/dev/null 2>&1; then
  exec perl -MIO::Select -MTime::HiRes=time -e '
    use Errno qw(EINTR);
    $| = 1;
    my $mode = shift;
    my $limit = shift;
    my $pid = 0;
    my $stopping = 0;
    my $reader;
    my $stop = sub {
      my $code = shift;
      return if $stopping++;
      alarm 0;
      if ($pid > 0) {
        kill "TERM", $pid;
        kill "TERM", -$pid;
        select undef, undef, undef, 0.2;
        kill "KILL", $pid;
        kill "KILL", -$pid;
        waitpid $pid, 0;
      }
      exit $code;
    };
    local $SIG{ALRM} = sub { $stop->(124) };
    local $SIG{HUP} = sub { $stop->(129) };
    local $SIG{INT} = sub { $stop->(130) };
    local $SIG{TERM} = sub { $stop->(143) };
    if ($mode eq "--progress") {
      pipe($reader, my $writer) or die "pipe failed";
      $pid = fork;
      die "fork failed" unless defined $pid;
      if (!$pid) {
        setpgrp(0, 0);
        close $reader;
        open STDOUT, ">&", $writer or die "stdout redirect failed";
        close $writer;
        exec @ARGV;
      }
      close $writer;
      my $select = IO::Select->new($reader);
      my $deadline = time + $limit;
      while (1) {
        my $remaining = $deadline - time;
        $stop->(124) if $remaining <= 0;
        my @ready = $select->can_read($remaining);
        $stop->(124) unless @ready;
        my $buffer = "";
        my $bytes = sysread($reader, $buffer, 8192);
        next if !defined($bytes) && $! == EINTR;
        die "read failed" unless defined $bytes;
        last if $bytes == 0;
        print STDOUT $buffer or die "write failed";
        $deadline = time + $limit;
      }
      close $reader;
    } else {
      $pid = fork;
      die "fork failed" unless defined $pid;
      if (!$pid) {
        setpgrp(0, 0);
        exec @ARGV;
      }
      alarm $limit;
    }
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;
    exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
  ' -- "$MODE" "$TIME_LIMIT" "$@"
fi
exit 124
