#!/usr/bin/env bash
# Shared bounded command runner for operations whose descendants must be
# terminated and reaped before the caller releases lifecycle or Git locks.
# Usage: fm_run_bounded <positive-seconds> <command> [args...]
# Returns 125 when termination of the owned process group cannot be verified.

FM_PROCESS_TREE_CLEANUP_FAILURE_STATUS=125

fm_run_bounded() {
  local seconds=$1
  shift
  command -v perl >/dev/null 2>&1 || {
    echo "error: perl is required for bounded process-tree control" >&2
    return 127
  }
  # shellcheck disable=SC2016
  perl -MPOSIX=:sys_wait_h -e '
    sub group_members {
      my ($group) = @_;
      my @members;
      open my $ps, "-|", "ps", "-axo", "pid=,pgid=" or return;
      while (<$ps>) {
        my ($pid, $pgid) = /^\s*(\d+)\s+(\d+)\s*$/;
        push @members, $pid if defined $pgid && $pgid == $group;
      }
      close $ps or return;
      return \@members;
    }
    sub reap_root {
      my ($root, $reaped) = @_;
      return if $$reaped;
      my $waited = waitpid $root, WNOHANG;
      $$reaped = 1 if $waited == $root || $waited == -1;
    }
    sub install_guard {
      my ($group) = @_;
      my $guard = $ENV{FM_PROCESS_TREE_GUARD_FILE} || return 1;
      my $tmp = "$guard.$$";
      open my $file, ">", $tmp or return 0;
      print {$file} "$group\n";
      close $file or do { unlink $tmp; return 0 };
      rename $tmp, $guard or do { unlink $tmp; return 0 };
      return 1;
    }
    sub clear_guard {
      my ($group) = @_;
      my $guard = $ENV{FM_PROCESS_TREE_GUARD_FILE} || return 1;
      open my $file, "<", $guard or return 0;
      my $recorded = <$file>;
      close $file;
      return 0 if !defined $recorded;
      chomp $recorded;
      return 0 if $recorded ne "$group";
      return unlink $guard;
    }
    sub terminate_group {
      my ($group, $root, $reaped) = @_;
      my $members = group_members($group);
      if (!defined $members) {
        kill "TERM", -$group;
        select undef, undef, undef, 0.2;
        kill "KILL", -$group;
        reap_root($root, $reaped);
        return 0;
      }
      return 1 unless @$members;
      kill "TERM", -$group;
      for (1 .. 10) {
        select undef, undef, undef, 0.1;
        reap_root($root, $reaped);
        $members = group_members($group);
        return 0 if !defined $members;
        return 1 unless @$members;
        kill "TERM", -$group;
      }
      kill "KILL", -$group;
      for (1 .. 20) {
        select undef, undef, undef, 0.1;
        reap_root($root, $reaped);
        $members = group_members($group);
        return 0 if !defined $members;
        return 1 unless @$members;
        kill "KILL", -$group;
      }
      return 0;
    }
    sub exit_status {
      my ($status) = @_;
      return ($status & 127) ? 128 + ($status & 127) : $status >> 8;
    }
    my $cleanup_failure = shift;
    my $timeout = shift;
    my $requested_status = 0;
    local $SIG{ALRM} = sub { $requested_status ||= 124 };
    local $SIG{HUP} = sub { $requested_status ||= 129 };
    local $SIG{INT} = sub { $requested_status ||= 130 };
    local $SIG{QUIT} = sub { $requested_status ||= 131 };
    local $SIG{TERM} = sub { $requested_status ||= 143 };
    pipe my $ready_read, my $ready_write or die "pipe failed";
    pipe my $start_read, my $start_write or die "pipe failed";
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) {
      close $ready_read;
      close $start_write;
      $SIG{HUP} = "DEFAULT";
      $SIG{INT} = "DEFAULT";
      $SIG{QUIT} = "DEFAULT";
      $SIG{TERM} = "DEFAULT";
      setpgrp 0, 0;
      if (getpgrp(0) != $$) {
        syswrite $ready_write, "E";
        exit $cleanup_failure;
      }
      syswrite $ready_write, "R";
      close $ready_write;
      my $start = "";
      my $read = sysread $start_read, $start, 1;
      close $start_read;
      exit $cleanup_failure if !defined $read || $read != 1 || $start ne "S";
      exec @ARGV;
      exit 127;
    }
    close $ready_write;
    close $start_read;
    my $ready = "";
    while (length $ready < 1) {
      my $read = sysread $ready_read, $ready, 1;
      next if !defined $read && $requested_status;
      last if !defined $read || $read == 0;
    }
    close $ready_read;
    my $root_reaped = 0;
    if ($ready ne "R") {
      close $start_write;
      waitpid $pid, 0;
      print STDERR "error: cannot establish bounded command process group\n";
      exit $cleanup_failure;
    }
    if (!install_guard($pid)) {
      close $start_write;
      terminate_group($pid, $pid, \$root_reaped);
      print STDERR "error: cannot establish bounded command process-group guard\n";
      exit $cleanup_failure;
    }
    if (!$requested_status) {
      syswrite $start_write, "S";
    }
    close $start_write;
    alarm $timeout;
    my $status;
    while (1) {
      my $waited = waitpid $pid, WNOHANG;
      if ($waited == $pid) {
        $status = $?;
        $root_reaped = 1;
        last;
      }
      last if $requested_status;
      select undef, undef, undef, 0.05;
    }
    alarm 0;
    if (!terminate_group($pid, $pid, \$root_reaped)) {
      print STDERR "error: bounded command process cleanup could not be verified for group $pid\n";
      exit $cleanup_failure;
    }
    if (!clear_guard($pid)) {
      print STDERR "error: bounded command process-group guard could not be cleared for group $pid\n";
      exit $cleanup_failure;
    }
    exit $requested_status if $requested_status;
    exit exit_status($status);
  ' "$FM_PROCESS_TREE_CLEANUP_FAILURE_STATUS" "$seconds" "$@"
}
