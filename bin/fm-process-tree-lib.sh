#!/usr/bin/env bash
# Shared bounded command runner for operations whose descendants must be
# terminated and reaped before the caller releases lifecycle or Git locks.
# Usage: fm_run_bounded <positive-seconds> <command> [args...]
# After every call, FM_PROCESS_TREE_CLEANUP_STATUS is verified, unverified, or
# not-started, while the function return preserves the wrapped command status.

FM_PROCESS_TREE_SETUP_FAILURE_STATUS=126
FM_PROCESS_TREE_CLEANUP_STATUS=not-started

fm_process_tree_emit_snapshot() {
  local path=$1 size
  size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]') || return 0
  case "$size" in ''|*[!0-9]*|0) return 0 ;; esac
  perl -e '
    my ($path, $remaining) = @ARGV;
    open my $file, "<", $path or exit 0;
    while ($remaining > 0) {
      my $wanted = $remaining > 65536 ? 65536 : $remaining;
      my $read = read $file, my $buffer, $wanted;
      last if !defined $read || $read == 0;
      print $buffer;
      $remaining -= $read;
    }
  ' "$path" "$size"
}

fm_run_bounded() {
  local seconds=$1 result_file stdout_file stderr_file result status cleanup
  shift
  FM_PROCESS_TREE_CLEANUP_STATUS=not-started
  command -v perl >/dev/null 2>&1 || {
    echo "error: perl is required for bounded process-tree control" >&2
    return 127
  }
  result_file=$(mktemp "${TMPDIR:-/tmp}/fm-process-tree-result.XXXXXX") || {
    echo "error: cannot create bounded process-tree result channel" >&2
    return "$FM_PROCESS_TREE_SETUP_FAILURE_STATUS"
  }
  stdout_file=$(mktemp "${TMPDIR:-/tmp}/fm-process-tree-stdout.XXXXXX") || {
    rm -f "$result_file"
    echo "error: cannot create bounded process-tree output channel" >&2
    return "$FM_PROCESS_TREE_SETUP_FAILURE_STATUS"
  }
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/fm-process-tree-stderr.XXXXXX") || {
    rm -f "$result_file" "$stdout_file"
    echo "error: cannot create bounded process-tree diagnostic channel" >&2
    return "$FM_PROCESS_TREE_SETUP_FAILURE_STATUS"
  }
  # shellcheck disable=SC2016
  if FM_PROCESS_TREE_RESULT_FILE=$result_file perl -MPOSIX=:sys_wait_h -MErrno=EINTR -e '
    sub record_cleanup {
      my ($state) = @_;
      my $path = $ENV{FM_PROCESS_TREE_RESULT_FILE} || return;
      open my $file, ">", $path or return;
      print {$file} "$state\n";
      close $file;
    }
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
    sub anchored_members {
      my ($group, $anchor) = @_;
      my $members = group_members($group);
      return if !defined $members;
      my $anchor_present = grep { $_ == $anchor } @$members;
      return if !$anchor_present;
      return [grep { $_ != $anchor } @$members];
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
    sub terminate_owned {
      my ($group, $anchor) = @_;
      my $members = anchored_members($group, $anchor);
      return if !defined $members;
      return "alive" unless @$members;
      kill "TERM", -$group;
      for (1 .. 10) {
        select undef, undef, undef, 0.1;
        $members = anchored_members($group, $anchor);
        return if !defined $members;
        return "alive" unless @$members;
      }
      kill "KILL", -$group;
      for (1 .. 20) {
        select undef, undef, undef, 0.1;
        my $all_members = group_members($group);
        return if !defined $all_members;
        return "killed" unless @$all_members;
        my $anchor_present = grep { $_ == $anchor } @$all_members;
        return if !$anchor_present;
        my @remaining = grep { $_ != $anchor } @$all_members;
        return "killed" unless @remaining;
      }
      return;
    }
    sub shell_status {
      my ($status) = @_;
      return ($status & 127) ? 128 + ($status & 127) : $status >> 8;
    }
    sub finish_anchor {
      my ($anchor, $finish_write) = @_;
      my $written = syswrite $finish_write, "F";
      close $finish_write;
      return 0 if !defined $written || $written != 1;
      my $waited;
      do {
        $waited = waitpid $anchor, 0;
      } while ($waited == -1 && $! == EINTR);
      return $waited == $anchor;
    }
    sub reap_anchor {
      my ($anchor, $finish_write) = @_;
      close $finish_write;
      my $waited;
      do {
        $waited = waitpid $anchor, 0;
      } while ($waited == -1 && $! == EINTR);
      return $waited == $anchor;
    }
    my $setup_failure = shift;
    my $timeout = shift;
    my $requested_status = 0;
    local $SIG{ALRM} = sub { $requested_status ||= 124 };
    local $SIG{HUP} = sub { $requested_status ||= 129 };
    local $SIG{INT} = sub { $requested_status ||= 130 };
    local $SIG{QUIT} = sub { $requested_status ||= 131 };
    local $SIG{TERM} = sub { $requested_status ||= 143 };
    pipe my $ready_read, my $ready_write or die "ready pipe failed";
    pipe my $start_read, my $start_write or die "start pipe failed";
    pipe my $status_read, my $status_write or die "status pipe failed";
    pipe my $finish_read, my $finish_write or die "finish pipe failed";
    my $anchor = fork;
    die "anchor fork failed" unless defined $anchor;
    if (!$anchor) {
      close $ready_read;
      close $start_write;
      close $status_read;
      close $finish_write;
      $SIG{HUP} = "IGNORE";
      $SIG{INT} = "IGNORE";
      $SIG{QUIT} = "IGNORE";
      $SIG{TERM} = "IGNORE";
      setpgrp 0, 0;
      if (getpgrp(0) != $$) {
        syswrite $ready_write, "E";
        exit $setup_failure;
      }
      syswrite $ready_write, "R";
      close $ready_write;
      my $start = "";
      my $start_count = sysread $start_read, $start, 1;
      close $start_read;
      exit $setup_failure if !defined $start_count || $start_count != 1 || $start ne "S";
      my $command = fork;
      exit $setup_failure unless defined $command;
      if (!$command) {
        close $status_write;
        close $finish_read;
        $SIG{HUP} = "DEFAULT";
        $SIG{INT} = "DEFAULT";
        $SIG{QUIT} = "DEFAULT";
        $SIG{TERM} = "DEFAULT";
        delete $ENV{FM_PROCESS_TREE_RESULT_FILE};
        exec @ARGV;
        exit 127;
      }
      my $waited;
      do {
        $waited = waitpid $command, 0;
      } while ($waited == -1 && $! == EINTR);
      my $command_status = $waited == $command ? shell_status($?) : 127;
      syswrite $status_write, "$command_status\n";
      close $status_write;
      while (1) {
        my $finish = "";
        my $finish_count = sysread $finish_read, $finish, 1;
        exit 0 if defined $finish_count && $finish_count == 1 && $finish eq "F";
        select undef, undef, undef, 1;
      }
    }
    close $ready_write;
    close $start_read;
    close $status_write;
    close $finish_read;
    my $ready = "";
    while (length $ready < 1) {
      my $count = sysread $ready_read, $ready, 1;
      next if !defined $count && $! == EINTR;
      last if !defined $count || $count == 0;
    }
    close $ready_read;
    if ($ready ne "R") {
      close $start_write;
      close $finish_write;
      waitpid $anchor, 0;
      record_cleanup("not-started");
      print STDERR "error: cannot establish bounded command process-group anchor\n";
      exit $setup_failure;
    }
    if (!install_guard($anchor)) {
      close $start_write;
      close $finish_write;
      waitpid $anchor, 0;
      record_cleanup("not-started");
      print STDERR "error: cannot establish bounded command process-group guard\n";
      exit $setup_failure;
    }
    my $started = 0;
    if (!$requested_status) {
      my $written = syswrite $start_write, "S";
      $started = 1 if defined $written && $written == 1;
    }
    close $start_write;
    if (!$started) {
      close $status_read;
      close $finish_write;
      waitpid $anchor, 0;
      clear_guard($anchor);
      record_cleanup("not-started");
      print STDERR "error: cannot start bounded command under its process-group anchor\n";
      exit $setup_failure;
    }
    alarm $timeout;
    my $status_text = "";
    while (!$requested_status && $status_text !~ /\n/) {
      my $chunk = "";
      my $count = sysread $status_read, $chunk, 64;
      if (defined $count && $count > 0) {
        $status_text .= $chunk;
        next;
      }
      last if defined $count && $count == 0;
      next if !defined $count && $! == EINTR;
      last;
    }
    alarm 0;
    my $command_status;
    $command_status = 0 + $1 if $status_text =~ /^(\d+)\n/;
    my $anchor_state = terminate_owned($anchor, $anchor);
    if (!defined $anchor_state) {
      close $status_read;
      close $finish_write;
      record_cleanup("unverified");
      my $guard = $ENV{FM_PROCESS_TREE_GUARD_FILE} || "the reported process group";
      print STDERR "error: bounded command process cleanup could not be verified for anchored group $anchor; ownership remains guarded by $guard. Inspect that group, terminate only its remaining processes, and retry.\n";
      exit(defined $command_status ? $command_status : ($requested_status || $setup_failure));
    }
    close $status_read;
    my $anchor_reaped = $anchor_state eq "alive"
      ? finish_anchor($anchor, $finish_write)
      : reap_anchor($anchor, $finish_write);
    if (!$anchor_reaped) {
      record_cleanup("unverified");
      print STDERR "error: bounded command process-group anchor $anchor could not be reaped; retain guarded resources and retry after it exits.\n";
      exit(defined $command_status ? $command_status : ($requested_status || $setup_failure));
    }
    if (!clear_guard($anchor)) {
      record_cleanup("unverified");
      print STDERR "error: bounded command process-group guard could not be cleared for anchored group $anchor; retain guarded resources and retry.\n";
      exit(defined $command_status ? $command_status : ($requested_status || $setup_failure));
    }
    record_cleanup("verified");
    exit $requested_status if $requested_status;
    exit(defined $command_status ? $command_status : $setup_failure);
  ' "$FM_PROCESS_TREE_SETUP_FAILURE_STATUS" "$seconds" "$@" >"$stdout_file" 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi
  result=$(sed -n '1p' "$result_file" 2>/dev/null || true)
  fm_process_tree_emit_snapshot "$stdout_file"
  fm_process_tree_emit_snapshot "$stderr_file" >&2
  rm -f "$result_file" "$stdout_file" "$stderr_file"
  case "$result" in
    verified|unverified|not-started) cleanup=$result ;;
    *) cleanup=unverified ;;
  esac
  FM_PROCESS_TREE_CLEANUP_STATUS=$cleanup
  return "$status"
}

fm_run_bounded_capture() {
  local combine=0 output_name output_file output status
  if [ "${1:-}" = "--combine-stderr" ]; then
    combine=1
    shift
  fi
  output_name=$1
  shift
  output_file=$(mktemp "${TMPDIR:-/tmp}/fm-process-tree-output.XXXXXX") || {
    FM_PROCESS_TREE_CLEANUP_STATUS=not-started
    return "$FM_PROCESS_TREE_SETUP_FAILURE_STATUS"
  }
  if [ "$combine" -eq 1 ]; then
    if fm_run_bounded "$@" >"$output_file" 2>&1; then status=0; else status=$?; fi
  else
    if fm_run_bounded "$@" >"$output_file"; then status=0; else status=$?; fi
  fi
  output=$(cat "$output_file")
  rm -f "$output_file"
  printf -v "$output_name" '%s' "$output"
  return "$status"
}

fm_process_tree_cleanup_verified() {
  [ "$FM_PROCESS_TREE_CLEANUP_STATUS" = verified ]
}
