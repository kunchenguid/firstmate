#!/usr/bin/env bash
# Behavior tests for bin/fm-timeout-lib.sh's bounds, fm_exec_timed and fm_run_timed:
# TERM to the command's process group at the bound, KILL once the grace has
# passed, a forwarded signal, the caller replaced rather than wrapped, and a
# refusal instead of an unbounded run when nothing on the host can enforce the
# bound. Most cases pin the perl watchdog, the preferred mechanism and the only
# one a stock macOS host has, under a PATH that holds no timeout variant; the
# GNU fallback case runs only where a real timeout exists.
# shellcheck disable=SC2016 # each bounded bash -c script expands its own arguments
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-timeout-lib)

# A PATH with perl and the shell tools the bounded commands use, and no
# timeout variant: fm_exec_timed must take its perl watchdog here.
PERL_ONLY="$TMP_ROOT/perl-only-bin"
mkdir -p "$PERL_ONLY"
for tool in perl bash sleep; do
  ln -s "$(command -v "$tool")" "$PERL_ONLY/$tool"
done

# exec_timed <path> <seconds> <grace> <command...>: source the library under
# the ordinary PATH, then run the bounded call under <path> as the last command
# of a subshell, exactly as a real caller does.
exec_timed() {
  local path=$1
  shift
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH=$path fm_exec_timed "$@"
  )
}

RUN124="$TMP_ROOT/run124-bin"
mkdir -p "$RUN124"
printf '#!/bin/sh\nshift 3\n"$@"\nexit 124\n' > "$RUN124/timeout"
chmod +x "$RUN124/timeout"

run_timed() {
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH="$RUN124:$PATH" fm_run_timed "$@"
  )
}

wait_for_file() {  # <path>
  local i=0
  while [ ! -s "$1" ]; do
    i=$((i + 1))
    [ "$i" -lt 500 ] || fail "timed out waiting for $1"
    sleep 0.02
  done
}

test_passes_the_command_status_and_output_through() {
  local out rc=0
  out=$(exec_timed "$PERL_ONLY" 5 1 bash -c 'echo to-stdout; echo to-stderr >&2; exit 7' 2>&1) || rc=$?
  [ "$rc" -eq 7 ] || fail "the watchdog did not pass the command's own status through (rc=$rc)"
  assert_contains "$out" "to-stdout" "the watchdog lost the command's stdout"
  assert_contains "$out" "to-stderr" "the watchdog lost the command's stderr"
  pass "fm_exec_timed passes a command's status and output through unchanged"
}

# Exercise the installed system Bash explicitly, including stock macOS 3.2:
# neither a top-level call nor a subshell may abort before starting its command.
# Unset BASHPID so newer system Bash also covers the missing-variable case.
test_system_bash_preserves_completion_and_signal_statuses() {
  local mode status command out rc
  for mode in top-level subshell; do
    for status in 0 7 137 143; do
      case "$status" in
        137) command='echo ran; kill -KILL $$' ;;
        143) command='echo ran; kill -TERM $$' ;;
        *) command="echo ran; exit $status" ;;
      esac
      rc=0
      out=$(PATH=$PERL_ONLY /bin/bash -c '
        . "$1/bin/fm-timeout-lib.sh"
        unset BASHPID
        if [ "$2" = subshell ]; then
          ( fm_exec_timed 5 1 bash -c "$3" )
        else
          fm_exec_timed 5 1 bash -c "$3"
        fi
      ' _ "$ROOT" "$mode" "$command" 2>&1) || rc=$?
      [ "$rc" -eq "$status" ] || fail "system Bash $mode lost command status $status (rc=$rc: $out)"
      [ "$out" = ran ] || fail "system Bash $mode did not run the command cleanly: $out"
    done
  done
  pass "system Bash top-level and subshell calls preserve success, failure, and signal status"
}

# A command that honors TERM ends at the bound, long before the grace would
# have forced it, and is gone afterwards.
test_term_ends_a_cooperative_command_at_the_bound() {
  local dir rc=0 started elapsed pid
  dir="$TMP_ROOT/term"
  mkdir -p "$dir"
  started=$SECONDS
  exec_timed "$PERL_ONLY" 1 30 bash -c 'echo $$ > "$1"; exec sleep 300' _ "$dir/pid" || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || fail "an expired bound did not report 124 (rc=$rc)"
  [ "$elapsed" -ge 1 ] || fail "the bound fired before it elapsed (${elapsed}s)"
  [ "$elapsed" -lt 15 ] || fail "a TERM-honoring command waited out the grace (${elapsed}s): TERM was not sent at the bound"
  pid=$(cat "$dir/pid")
  ! kill -0 "$pid" 2>/dev/null || fail "the bounded command outlived its bound"
  pass "fm_exec_timed sends TERM at the bound and a cooperative command ends there"
}

# A command that ignores TERM survives the bound and is killed only once the
# grace has passed, so the grace is what separates the two.
test_kill_ends_a_term_ignoring_command_after_the_grace() {
  local dir rc=0 started elapsed pid
  dir="$TMP_ROOT/kill"
  mkdir -p "$dir"
  started=$SECONDS
  exec_timed "$PERL_ONLY" 1 2 bash -c 'trap "" TERM; echo $$ > "$1"; exec sleep 300' _ "$dir/pid" || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || fail "a KILL-forced expiry did not report 124 (rc=$rc)"
  [ "$elapsed" -ge 3 ] || fail "a TERM-ignoring command ended before bound plus grace (${elapsed}s): the grace was skipped"
  [ "$elapsed" -lt 20 ] || fail "a TERM-ignoring command was not killed after the grace (${elapsed}s)"
  pid=$(cat "$dir/pid")
  ! kill -0 "$pid" 2>/dev/null || fail "the TERM-ignoring command survived the KILL"
  pass "fm_exec_timed kills a TERM-ignoring command once the grace has passed"
}

# The bounded command sits where the plain call sat: the calling subshell is
# replaced by the bounding process, whose child the command is. This holds for
# whichever mechanism the host selects, and for the perl watchdog explicitly.
test_the_bound_replaces_the_calling_shell() {
  local dir path caller parent
  dir="$TMP_ROOT/replace"
  mkdir -p "$dir"
  for path in "$PATH" "$PERL_ONLY"; do
    rm -f "$dir/caller" "$dir/parent"
    (
      . "$ROOT/bin/fm-timeout-lib.sh"
      perl -e 'print getppid(), "\n"' > "$dir/caller"
      PATH=$path fm_exec_timed 5 1 bash -c 'echo "$PPID" > "$1"' _ "$dir/parent"
    ) || fail "the bounded probe failed under PATH=$path"
    caller=$(cat "$dir/caller")
    parent=$(cat "$dir/parent")
    [ "$caller" = "$parent" ] \
      || fail "the command's parent $parent is not the replaced caller $caller under PATH=$path"
  done
  pass "fm_exec_timed replaces the calling shell instead of wrapping it"
}

# The regression a direct-child watchdog had: the command dies at the bound
# but a descendant that ignores TERM keeps the captured output open, so the
# caller waits for the descendant instead of the bound.
test_a_descendant_holding_the_output_cannot_outlast_the_bound() {
  local dir out rc=0 started elapsed pid
  dir="$TMP_ROOT/descendant"
  mkdir -p "$dir"
  started=$SECONDS
  # The positional parameter belongs to the bounded shell.
  # shellcheck disable=SC2016
  out=$(exec_timed "$PERL_ONLY" 1 30 bash -c '
    ( trap "" TERM; exec sleep 300 ) &
    echo $! > "$1"
    wait
  ' _ "$dir/pid") || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || fail "an expired bound did not report 124 (rc=$rc)"
  [ "$elapsed" -lt 15 ] \
    || fail "a TERM-ignoring descendant held the captured output for ${elapsed}s past a 1s bound"
  pid=$(cat "$dir/pid")
  ! kill -0 "$pid" 2>/dev/null || fail "the TERM-ignoring descendant survived the bound"
  pass "fm_exec_timed reaps a descendant that would otherwise hold the output past the bound"
}

# A TERM delivered to the bounding process itself - a harness tearing down a
# hook, an operator stopping the caller - reaches the command, and a command
# that then exits on its own reports its own status, not the bound's.
test_a_signal_to_the_bounding_process_reaches_the_command() {
  local dir watchdog rc=0
  dir="$TMP_ROOT/forward"
  mkdir -p "$dir"
  # Backgrounded directly, the subshell's pid is the watchdog it becomes.
  # The positional parameters belong to the bounded shell.
  # shellcheck disable=SC2016
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH=$PERL_ONLY
    fm_exec_timed 60 30 bash -c '
      trap "echo forwarded > \"\$2\"; exit 3" TERM
      echo $$ > "$1"
      while :; do sleep 0.1; done
    ' _ "$dir/pid" "$dir/term"
  ) 2>/dev/null &
  watchdog=$!
  wait_for_file "$dir/pid"
  kill -TERM "$watchdog" || fail "could not signal the bounding process"
  wait "$watchdog" || rc=$?
  [ "$(cat "$dir/term" 2>/dev/null)" = forwarded ] || fail "the TERM never reached the bounded command"
  [ "$rc" -eq 3 ] || fail "a forwarded TERM did not report the command's own status (rc=$rc)"
  pass "fm_exec_timed forwards a TERM it receives to the bounded command"
}

# A caller that names its owner before launching the watchdog is watched even
# when that owner died while the watchdog was still starting: the watchdog's
# parent is then not the named owner, so the escalation starts at once rather
# than at the bound.
test_a_named_owner_that_is_gone_ends_the_command() {
  local dir gone rc=0 started elapsed pid
  dir="$TMP_ROOT/owner"
  mkdir -p "$dir"
  sleep 0 &
  gone=$!
  wait "$gone" 2>/dev/null || true
  started=$SECONDS
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH=$PERL_ONLY FM_EXEC_TIMED_OWNER_PID=$gone \
      fm_exec_timed 60 1 bash -c 'echo $$ > "$1"; exec sleep 300' _ "$dir/pid"
  ) || rc=$?
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 15 ] || fail "a watchdog whose named owner was gone ran to its bound (${elapsed}s)"
  [ "$rc" -ne 0 ] || fail "a command ended by its owner's death reported success"
  if [ -s "$dir/pid" ]; then
    pid=$(cat "$dir/pid")
    ! kill -0 "$pid" 2>/dev/null || fail "the bounded command outlived its named owner"
  fi
  pass "fm_exec_timed ends the command when its named owner is already gone"
}

# With no named owner the calling script is captured before the watchdog
# starts, so a script that dies while its subshell is still on the way into
# fm_exec_timed - the watchdog then starts already reparented - is still
# detected instead of leaving the command running to its bound.
test_an_owner_that_dies_during_startup_ends_the_command() {
  local dir watchdog started pid
  dir="$TMP_ROOT/startup-owner"
  mkdir -p "$dir"
  # shellcheck disable=SC2016
  PATH=$PERL_ONLY bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    (
      perl -e "print getppid(), qq(\\n)" > "$2/watchdog"
      while kill -0 "$$" 2>/dev/null; do sleep 0.05; done
      fm_exec_timed 60 1 bash -c "echo \$\$ > \"\$1\"; exec sleep 300" _ "$2/pid"
    ) >/dev/null 2>&1 &
    exit 0
  ' _ "$ROOT" "$dir"
  wait_for_file "$dir/watchdog"
  watchdog=$(cat "$dir/watchdog")
  started=$SECONDS
  while kill -0 "$watchdog" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge 15 ]; then
      if [ -s "$dir/pid" ]; then
        pid=$(cat "$dir/pid")
        kill -KILL -- "-$pid" 2>/dev/null || true
      fi
      kill -KILL "$watchdog" 2>/dev/null || true
      fail "a watchdog whose owner died during startup ran on toward its bound"
    fi
    sleep 0.02
  done
  pass "fm_exec_timed ends the command when its owner dies during watchdog startup"
}

# A top-level calling shell has its own PID in $$, unlike a Bash subshell.
# Capture its parent before exec: that parent can exit while the top-level
# shell is still on its way into the watchdog.
test_a_top_level_parent_that_dies_during_startup_ends_the_command() {
  local dir watchdog started pid
  dir="$TMP_ROOT/top-level-parent"
  mkdir -p "$dir"
  PATH=$PERL_ONLY bash -c '
    bash -c '\''
      . "$1/bin/fm-timeout-lib.sh"
      echo "$$" > "$2/watchdog"
      while kill -0 "$PPID" 2>/dev/null; do sleep 0.05; done
      fm_exec_timed 60 1 bash -c "echo \$\$ > \"\$1\"; exec sleep 300" _ "$2/pid"
    '\'' _ "$1" "$2" >/dev/null 2>&1 &
    while [ ! -s "$2/watchdog" ]; do sleep 0.02; done
    exit 0
  ' _ "$ROOT" "$dir"
  wait_for_file "$dir/watchdog"
  watchdog=$(cat "$dir/watchdog")
  started=$SECONDS
  while kill -0 "$watchdog" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge 15 ]; then
      if [ -s "$dir/pid" ]; then
        pid=$(cat "$dir/pid")
        kill -KILL -- "-$pid" 2>/dev/null || true
      fi
      kill -KILL "$watchdog" 2>/dev/null || true
      fail "top-level watchdog lost its pre-exec parent and ran toward its bound"
    fi
    sleep 0.02
  done
  pass "fm_exec_timed preserves a top-level shell's parent across exec startup"
}

# perl is preferred whenever it exists, because only its watchdog can reap a
# leftover descendant after replacing the caller.
test_perl_is_preferred_over_timeout() {
  local dir out
  dir="$TMP_ROOT/prefer"
  mkdir -p "$dir/bin"
  for tool in perl bash; do
    ln -s "$(command -v "$tool")" "$dir/bin/$tool"
  done
  printf '#!/bin/sh\necho timeout-used > "%s"\nexit 99\n' "$dir/timeout-used" > "$dir/bin/timeout"
  chmod +x "$dir/bin/timeout"
  out=$(exec_timed "$dir/bin" 5 1 bash -c 'echo ran') || fail "the bounded call failed: $out"
  [ "$out" = ran ] || fail "the bounded call printed '$out'"
  [ ! -e "$dir/timeout-used" ] || fail "fm_exec_timed used timeout although perl was available"
  pass "fm_exec_timed prefers its perl watchdog over timeout"
}

test_refuses_rather_than_running_unbounded() {
  local dir out rc=0
  dir="$TMP_ROOT/unboundable"
  mkdir -p "$dir/bin"
  ln -s "$(command -v bash)" "$dir/bin/bash"
  out=$(exec_timed "$dir/bin" 5 1 bash -c ': > "$1"' _ "$dir/ran" 2>&1) || rc=$?
  [ "$rc" -eq 127 ] || fail "fm_exec_timed ran with nothing to bound it (rc=$rc)"
  assert_contains "$out" "cannot bound bash within 5s" "the refusal did not say what it could not bound"
  [ ! -e "$dir/ran" ] || fail "the command ran although nothing could bound it"
  pass "fm_exec_timed refuses instead of running unbounded when no mechanism exists"
}

test_rejects_malformed_bounds_before_running_anything() {
  local dir out rc
  dir="$TMP_ROOT/malformed"
  mkdir -p "$dir"
  for args in '0 1' '5 0' '05 1' '5 x' '' '5'; do
    rc=0
    # shellcheck disable=SC2086 # deliberate splitting of the bound pair
    out=$(exec_timed "$PERL_ONLY" $args bash -c ': > "$1"' _ "$dir/ran" 2>&1) || rc=$?
    [ "$rc" -eq 125 ] || fail "bounds '$args' were not rejected (rc=$rc: $out)"
    [ ! -e "$dir/ran" ] || fail "bounds '$args' still ran the command"
  done
  rc=0
  out=$(exec_timed "$PERL_ONLY" 5 1 2>&1) || rc=$?
  [ "$rc" -eq 125 ] || fail "a call with no command was not rejected (rc=$rc: $out)"
  assert_contains "$out" "usage: fm_exec_timed" "the rejection did not print the usage"
  pass "fm_exec_timed rejects a zero, padded, non-numeric, or missing bound and a missing command"
}

test_gnu_timeout_kills_a_term_ignoring_command_after_the_grace() {
  local dir fb rc=0 started elapsed verdict
  if ! command -v timeout >/dev/null 2>&1; then
    pass "fm_exec_timed's GNU timeout fallback (skipped: no timeout binary on this host)"
    return 0
  fi
  dir="$TMP_ROOT/gnu"
  fb="$dir/bin"
  mkdir -p "$fb"
  # No perl here, so the call falls back to GNU timeout.
  for tool in timeout bash sleep; do
    ln -s "$(command -v "$tool")" "$fb/$tool"
  done
  started=$SECONDS
  exec_timed "$fb" 1 2 bash -c 'trap "" TERM; exec sleep 300' || rc=$?
  elapsed=$((SECONDS - started))
  verdict=$( . "$ROOT/bin/fm-timeout-lib.sh"; fm_timed_out "$rc" && echo expired)
  [ "$verdict" = expired ] || fail "the GNU path's expiry status $rc is not a timed-out status"
  [ "$elapsed" -ge 3 ] || fail "the GNU path ended a TERM-ignoring command before bound plus grace (${elapsed}s)"
  [ "$elapsed" -lt 20 ] || fail "the GNU path did not kill a TERM-ignoring command after the grace (${elapsed}s)"
  pass "fm_exec_timed's GNU timeout fallback kills a TERM-ignoring command once the grace has passed"
}

test_timed_out_names_exactly_the_bound_statuses() {
  local status verdict
  for status in 124 137 0 1 125 127 143 ''; do
    verdict=$( . "$ROOT/bin/fm-timeout-lib.sh"; if fm_timed_out "$status"; then echo yes; else echo no; fi)
    case "$status" in
      124|137) [ "$verdict" = yes ] || fail "status '$status' was not read as the bound" ;;
      *) [ "$verdict" = no ] || fail "status '$status' was misread as the bound" ;;
    esac
  done
  pass "fm_timed_out accepts 124 and 137 and nothing else"
}

test_run_timed_reports_the_bound_when_the_wrapper_records_a_signal_death() {
  local rc=0
  run_timed 5 bash -c 'kill -TERM $$' || rc=$?
  [ "$rc" -eq 124 ] || fail "a bound-killed read leaked the signal death as its own status (rc=$rc)"
  pass 'fm_run_timed reports 124 when the bound TERMs a read whose wrapper recorded 143'
}

test_run_timed_passes_a_natural_exit_through_a_fired_bound() {
  local out rc=0
  out=$(run_timed 5 bash -c 'echo through') || rc=$?
  [ "$rc" -eq 0 ] || fail "a completed read lost its own status to the fired bound (rc=$rc)"
  [ "$out" = through ] || fail 'a completed read lost its output to the fired bound'
  pass 'fm_run_timed passes a natural exit through when the bound fired after completion'
}

# An omp shell defines timeout as a builtin, and a function of that name is
# ahead of both the builtin and the executable. command -v reports the name
# and a bare call runs the shadow, which drops the command's stdout and
# replaces its status. gtimeout is shadowed the same way, so a host whose
# external runner is gtimeout is covered without installing one.
test_run_timed_keeps_stdout_and_nonzero_status_when_a_function_shadows_timeout() {
  local out rc=0
  # The functions live in this subshell so they cannot leak into later cases.
  out=$(
    unset FM_TIMEOUT_MECHANISM_OVERRIDE
    # shellcheck disable=SC2329 # Steal a bare timeout invocation; the runner must not call it.
    timeout() { echo shadowed-timeout; return 0; }
    # shellcheck disable=SC2329 # Steal a bare gtimeout invocation; the runner must not call it.
    gtimeout() { echo shadowed-gtimeout; return 0; }
    . "$ROOT/bin/fm-timeout-lib.sh"
    fm_run_timed 5 bash -c 'echo hello-stdout; exit 7'
  ) || rc=$?
  [ "$rc" -eq 7 ] || fail "a function shadowing timeout changed the command status (rc=$rc out=$out)"
  [ "$out" = hello-stdout ] || fail "a function shadowing timeout changed the command stdout (rc=$rc out=$out)"
  pass "fm_run_timed keeps stdout and nonzero status when a function shadows timeout"
}

test_run_timed_perl_interrupt_cleanup() {
  local signal target disposition
  for signal in INT HUP TERM timeout; do
    for target in caller group; do
      [ "$signal:$target" != timeout:group ] || continue
      for disposition in default exit return ignore; do
        [ "$signal" != timeout ] || [ "$disposition" = default ] || continue
        PATH=$PERL_ONLY perl -MPOSIX=setpgid,WNOHANG -MTime::HiRes=time,sleep -MIO::Select -e '
          my ($root, $dir, $signal, $target, $disposition) = @ARGV;
          mkdir $dir or die "mkdir $dir: $!";
          pipe(my $output, my $writer) or die "pipe: $!";
          my $caller = fork;
          die "fork: $!" unless defined $caller;
          if (!$caller) {
            close $output;
            setpgid(0, 0) == 0 or die "setpgid: $!";
            $SIG{$_} = "DEFAULT" for qw(INT HUP TERM);
            open STDOUT, ">&", $writer or die "stdout: $!";
            close $writer;
            exec "/bin/bash", "-c", q{
              . "$1/bin/fm-timeout-lib.sh"
              case $4 in
                exit|return)
                  handler_exit=""
                  [ "$4" != exit ] || handler_exit="; exit 61"
                  for caught in INT HUP TERM; do
                    trap "printf \"handled $caught\\n\"$handler_exit" "$caught"
                done
                ;;
              ignore) trap "" INT HUP TERM ;;
            esac
            fm_run_timed "$3" perl -e '\''
              my $dir = shift;
              $SIG{$_} = "IGNORE" for qw(INT HUP TERM);
              my $child = fork;
              die "fork: $!" unless defined $child;
              if (!$child) {
                open my $f, ">", "$dir/descendant" or die $!;
                print $f "$$\n";
                close $f;
                sleep 300;
                exit;
              }
              open my $f, ">", "$dir/command" or die $!;
              print $f "$$\n";
              close $f;
              waitpid $child, 0;
            '\'' "$2"
            rc=$?
            printf "continued %s\n" "$rc"
            exit "$rc"
          }, "_", $root, $dir, ($signal eq "timeout" ? 1 : 30), $disposition;
          die "exec: $!";
        }
        close $writer;
        setpgid($caller, $caller);
        my ($command, $descendant, $status, $eof, $error);
        my $captured = "";
        eval {
          my $ready_by = time + 10;
          for my $entry ([command => \$command], [descendant => \$descendant]) {
            my ($name, $pid) = @$entry;
            until (-s "$dir/$name") {
              die "fixture not ready" if time >= $ready_by;
              sleep 0.02;
            }
            open my $f, "<", "$dir/$name" or die $!;
            $$pid = <$f>;
            chomp $$pid;
            die "invalid fixture pid" unless $$pid =~ /^\d+$/ && $$pid > 1;
          }
          if ($signal ne "timeout") {
            kill $signal, ($target eq "group" ? -$caller : $caller) or die "signal: $!";
          }
          my $end = time + 5;
          my $select = IO::Select->new($output);
          until (defined $status && $eof) {
            if (!defined $status && waitpid($caller, WNOHANG) == $caller) { $status = $? }
            if (!$eof && $select->can_read(0.02)) {
              my $n = sysread $output, my $buf, 4096;
              die "read: $!" unless defined $n;
              $captured .= $buf;
              $eof = 1 if !$n;
            }
            die "caller or captured stdout exceeded interrupt cleanup bound" if time >= $end;
          }
          my %number = (HUP => 1, INT => 2, TERM => 15);
          my $rc = ($status & 127) ? 128 + ($status & 127) : $status >> 8;
          my $expected = $signal eq "timeout" ? 124 : 128 + $number{$signal};
          $expected = 61 if $disposition eq "exit";
          die "incorrect status $rc" unless $rc == $expected;
          my $expected_output = $signal eq "timeout" || $disposition eq "ignore"
            ? "continued $expected\n" : $disposition eq "exit" ? "handled $signal\n"
            : $disposition eq "return" ? "handled $signal\ncontinued $expected\n" : "";
          die "incorrect caller behavior: $captured" unless $captured eq $expected_output;
          # Allow the host init to reap orphaned descendants after KILL.
          while (kill(0, $command) || kill(0, $descendant) || kill(0, -$command)) {
            die "owned command or group survived" if time >= $end;
            sleep 0.02;
          }
        };
        $error = $@;
        # These groups were created solely by this fixture, never the test runner.
        kill "KILL", -$command if $command;
        kill "KILL", -$caller;
        waitpid $caller, 0 unless defined $status;
        die "$signal to $target with $disposition disposition: $error" if $error;
      ' "$ROOT" "$TMP_ROOT/interrupt-$signal-$target-$disposition" "$signal" "$target" "$disposition" \
        || fail "fm_run_timed perl cleanup for $signal to $target with $disposition disposition"
      done
    done
  done
  pass "fm_run_timed perl reaps owned groups and preserves caller signal dispositions on INT/HUP/TERM and timeout"
}

test_run_timed_perl_startup_interrupt_cleanup() {
  local startup_bin real_perl signal target monitor
  startup_bin="$TMP_ROOT/perl-startup-bin"
  real_perl=$(command -v perl)
  mkdir -p "$startup_bin"
  ln -s "$(command -v bash)" "$startup_bin/bash"
  printf '#!%s\n' "$real_perl" > "$startup_bin/perl"
  cat >> "$startup_bin/perl" <<'PERL'
use strict;
use warnings;
use Time::HiRes qw(sleep);
my $dir = $ENV{FM_TIMEOUT_STARTUP_DIR};
if (!-e "$dir/runner") {
  open my $f, ">", "$dir/runner" or die $!;
  print $f "$$\n";
  close $f;
  sleep 300;
}
exec $ENV{FM_TIMEOUT_STARTUP_PERL}, @ARGV;
die "exec: $!";
PERL
  chmod +x "$startup_bin/perl"
  for monitor in off on; do
    for signal in INT HUP TERM; do
      for target in caller group; do
        "$real_perl" -MPOSIX=setpgid,WNOHANG -MTime::HiRes=time,sleep -MIO::Select -e '
          my ($root, $bin, $dir, $signal, $target, $monitor, $real_perl) = @ARGV;
          mkdir $dir or die "mkdir: $!";
          pipe(my $output, my $writer) or die "pipe: $!";
          my $caller = fork;
          die "fork: $!" unless defined $caller;
          if (!$caller) {
            close $output;
            setpgid(0, 0) == 0 or die "setpgid: $!";
            $SIG{$_} = "DEFAULT" for qw(INT HUP TERM);
            open STDOUT, ">&", $writer or die "stdout: $!";
            close $writer;
            @ENV{qw(PATH FM_TIMEOUT_STARTUP_DIR FM_TIMEOUT_STARTUP_PERL)} = ($bin, $dir, $real_perl);
            exec "/bin/bash", "-c", q{
              . "$1/bin/fm-timeout-lib.sh"
              [ "$4" != on ] || set -m
              before=$-
              trap "printf \"handled $3\\n\"" "$3"
              fm_run_timed 30 bash -c '\''printf launched > "$1"'\'' _ "$2/command"
              rc=$?
              [ "$-" = "$before" ] || exit 98
              exit "$rc"
            }, "_", $root, $dir, $signal, $monitor;
            die "exec: $!";
          }
          close $writer;
          setpgid($caller, $caller);
          my ($runner, $status, $eof);
          my $captured = "";
          eval {
            my $ready_by = time + 5;
            until (-s "$dir/runner") {
              die "runner not ready" if time >= $ready_by;
              sleep 0.01;
            }
            open my $f, "<", "$dir/runner" or die $!;
            $runner = <$f>;
            chomp $runner;
            die "invalid runner pid" unless $runner =~ /^\d+$/ && $runner > 1;
            kill $signal, ($target eq "group" ? -$caller : $caller) or die "signal: $!";
            my $end = time + 5;
            my $select = IO::Select->new($output);
            until (defined $status && $eof) {
              if (!defined $status && waitpid($caller, WNOHANG) == $caller) { $status = $? }
              if (!$eof && $select->can_read(0.01)) {
                my $n = sysread $output, my $buf, 4096;
                die "read: $!" unless defined $n;
                $captured .= $buf;
                $eof = 1 if !$n;
              }
              die "startup interrupt exceeded cleanup bound" if time >= $end;
            }
            die "command launched despite startup interrupt" if -e "$dir/command";
            my %number = (HUP => 1, INT => 2, TERM => 15);
            my $rc = ($status & 127) ? 128 + ($status & 127) : $status >> 8;
            die "incorrect status $rc" unless $rc == 128 + $number{$signal};
            die "caller handler not preserved: $captured" unless $captured eq "handled $signal\n";
            die "runner survived startup interrupt" if kill(0, $runner) || kill(0, -$runner);
          };
          my $error = $@;
          if ($runner) {
            kill "KILL", -$runner;
            kill "KILL", $runner;
          }
          kill "KILL", -$caller;
          waitpid $caller, 0 unless defined $status;
          die "$signal to $target with monitor $monitor: $error" if $error;
        ' "$ROOT" "$startup_bin" "$TMP_ROOT/startup-$monitor-$signal-$target" "$signal" "$target" "$monitor" "$real_perl" \
          || fail "fm_run_timed perl startup $signal to $target with monitor $monitor"
      done
    done
  done
  pass "fm_run_timed perl cancels before handler installation and preserves caller job control and signal handlers"
}

test_run_timed_perl_preserves_completion_and_caller_traps() {
  local out rc status monitor
  for monitor in off on; do
    for status in 0 7 137 143; do
      rc=0
      out=$(PATH=$PERL_ONLY /bin/bash -c '
        . "$1/bin/fm-timeout-lib.sh"
        [ "$3" != on ] || set -m
        before_options=$-
        trap ": original INT" INT
        trap ": original HUP" HUP
        trap ": original TERM" TERM
        before=$(trap -p INT HUP TERM)
        fm_run_timed 5 bash -c '\''
          read -r line
          echo "$line"
          case $1 in
            137) kill -KILL $$ ;;
            143) kill -TERM $$ ;;
            *) exit "$1" ;;
          esac
        '\'' _ "$2"
        rc=$?
        [ "$-" = "$before_options" ] || exit 98
        [ "$(trap -p INT HUP TERM)" = "$before" ] || exit 99
        exit "$rc"
      ' _ "$ROOT" "$status" "$monitor" <<< input 2>/dev/null) || rc=$?
      [ "$rc" -eq "$status" ] || fail "Perl completion status $status became $rc"
      [ "$out" = input ] || fail "Perl completion lost stdin or stdout: $out"
    done
  done
  pass "fm_run_timed perl preserves stdin, output, completion statuses and caller traps"
}

run_timed_edge_fixture() {
  local mode=$1 signal=$2 dir real_perl
  dir="$TMP_ROOT/edge-$mode-$signal"
  real_perl=$(command -v perl)
  mkdir -p "$dir"
  cat > "$dir/TimeoutClockFixture.pm" <<'PERL'
package TimeoutClockFixture;
use Time::HiRes ();
my $dir = $ENV{FM_TIMEOUT_CLOCK_DIR};
my $mode = $ENV{FM_TIMEOUT_CLOCK_MODE};
my $monotonic = \&Time::HiRes::clock_gettime;
if (!-e "$dir/runner") {
  open my $f, ">", "$dir/runner" or die $!;
  print $f "$$\n";
  close $f;
}
if ($mode eq "jump") {
  my $reads = 0;
  no warnings 'redefine';
  *Time::HiRes::time = sub { return $reads++ ? -1e12 : 1e12 };
  *main::time = \&Time::HiRes::time;
}
my $held = 0;
*CORE::GLOBAL::kill = sub {
  my ($signal, @pids) = @_;
  my $sent = CORE::kill($signal, @pids);
  if ($mode eq "grace" && $signal eq "TERM" && !$held) {
    $held = 1;
    my $received = 0;
    for my $name (qw(INT HUP TERM)) {
      my $handler = $SIG{$name};
      die "fixture requires an installed signal handler" unless ref($handler) eq "CODE";
      $SIG{$name} = sub { $handler->(@_); $received = 1 };
    }
    open my $f, ">", "$dir/grace" or die $!;
    print $f "TERM delivered\n";
    close $f;
    my $end = $monotonic->(Time::HiRes::CLOCK_MONOTONIC()) + 10;
    until ($received) {
      die "fixture received no interrupt" if $monotonic->(Time::HiRes::CLOCK_MONOTONIC()) >= $end;
      select undef, undef, undef, 0.01;
    }
  }
  return $sent;
};
1;
PERL
  "$real_perl" -MPOSIX=setpgid,WNOHANG -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC,sleep -MIO::Select -e '
    my ($root, $path, $dir, $mode, $signal) = @ARGV;
    pipe(my $output, my $writer) or die "pipe: $!";
    my $caller = fork;
    die "fork: $!" unless defined $caller;
    if (!$caller) {
      close $output;
      setpgid(0, 0) == 0 or die "setpgid: $!";
      $SIG{$_} = "DEFAULT" for qw(INT HUP TERM);
      open STDOUT, ">&", $writer or die "stdout: $!";
      close $writer;
      open STDERR, ">", "$dir/stderr" or die $!;
      @ENV{qw(PATH PERL5LIB PERL5OPT FM_TIMEOUT_CLOCK_DIR FM_TIMEOUT_CLOCK_MODE)}
        = ($path, $dir, "-MTimeoutClockFixture", $dir, $mode);
      exec "/bin/bash", "-c", q{
        unset FM_TIMEOUT_MECHANISM_OVERRIDE
        . "$1/bin/fm-timeout-lib.sh"
        trap ":" INT HUP TERM
        rc=0
        fm_run_timed 1 bash -c '\''
          trap "" INT HUP TERM
          printf "%s\n" "$$" > "$1/command"
          exec sleep 300
        '\'' _ "$2" || rc=$?
        printf "result %s\n" "$rc"
        exit "$rc"
      }, "_", $root, $dir;
      die "exec: $!";
    }
    close $writer;
    setpgid($caller, $caller);
    my ($runner, $command, $status, $eof);
    my $captured = "";
    sub read_pid {
      my $path = shift;
      open my $f, "<", $path or die $!;
      my $pid = <$f>;
      chomp $pid;
      die "invalid fixture pid" unless $pid =~ /^\d+$/ && $pid > 1;
      return $pid;
    }
    eval {
      my $ready_by = clock_gettime(CLOCK_MONOTONIC) + 10;
      for my $entry ([runner => \$runner], [command => \$command]) {
        my ($name, $pid) = @$entry;
        until (-s "$dir/$name") {
          die "fixture not ready: $name" if clock_gettime(CLOCK_MONOTONIC) >= $ready_by;
          sleep 0.01;
        }
        $$pid = read_pid("$dir/$name");
      }
      if ($mode eq "grace") {
        until (-s "$dir/grace") {
          die "timeout cleanup did not start" if clock_gettime(CLOCK_MONOTONIC) >= $ready_by;
          sleep 0.01;
        }
        kill $signal, $caller or die "signal: $!";
      }
      my $end = clock_gettime(CLOCK_MONOTONIC) + 5;
      my $select = IO::Select->new($output);
      until (defined $status && $eof) {
        if (!defined $status && waitpid($caller, WNOHANG) == $caller) { $status = $? }
        if (!$eof && $select->can_read(0.01)) {
          my $n = sysread $output, my $buf, 4096;
          die "read: $!" unless defined $n;
          $captured .= $buf;
          $eof = 1 if !$n;
        }
        die "caller or stdout exceeded the bound" if clock_gettime(CLOCK_MONOTONIC) >= $end;
      }
      my %number = (HUP => 1, INT => 2, TERM => 15);
      my $expected = $mode eq "jump" ? 124 : 128 + $number{$signal};
      my $rc = ($status & 127) ? 128 + ($status & 127) : $status >> 8;
      die "expected status $expected, got $rc" unless $rc == $expected;
      die "incorrect caller output: $captured" unless $captured eq "result $expected\n";
      while (kill(0, $command) || kill(0, -$command) || kill(0, $runner)) {
        die "owned process or group survived" if clock_gettime(CLOCK_MONOTONIC) >= $end;
        sleep 0.01;
      }
    };
    my $error = $@;
    if ($error) {
      $command ||= eval { read_pid("$dir/command") } || 0;
      $runner ||= eval { read_pid("$dir/runner") } || 0;
      kill "KILL", -$command if $command;
      kill "KILL", -$runner if $runner;
      kill "KILL", -$caller;
      waitpid $caller, 0 unless defined $status;
      die "$mode/$signal: $error";
    }
  ' "$ROOT" "$PERL_ONLY" "$dir" "$mode" "$signal"
}

test_run_timed_perl_interrupt_wins_during_timeout_cleanup() {
  local signal
  for signal in INT HUP TERM; do
    run_timed_edge_fixture grace "$signal" || fail "Perl $signal during timeout cleanup lost its status"
  done
  pass "fm_run_timed perl preserves interruption status during timeout cleanup"
}

test_run_timed_perl_timeout_ignores_wall_clock_changes() {
  run_timed_edge_fixture jump TERM || fail "Perl timeout moved with a wall-clock jump"
  pass "fm_run_timed perl bounds its deadline and cleanup despite wall-clock changes"
}

test_run_timed_perl_interrupt_wins_during_timeout_cleanup
test_run_timed_perl_timeout_ignores_wall_clock_changes
test_run_timed_perl_interrupt_cleanup
test_run_timed_perl_startup_interrupt_cleanup
test_run_timed_perl_preserves_completion_and_caller_traps
test_passes_the_command_status_and_output_through
test_system_bash_preserves_completion_and_signal_statuses
test_run_timed_reports_the_bound_when_the_wrapper_records_a_signal_death
test_run_timed_passes_a_natural_exit_through_a_fired_bound
test_run_timed_keeps_stdout_and_nonzero_status_when_a_function_shadows_timeout
test_term_ends_a_cooperative_command_at_the_bound
test_kill_ends_a_term_ignoring_command_after_the_grace
test_the_bound_replaces_the_calling_shell
test_a_descendant_holding_the_output_cannot_outlast_the_bound
test_a_signal_to_the_bounding_process_reaches_the_command
test_a_named_owner_that_is_gone_ends_the_command
test_an_owner_that_dies_during_startup_ends_the_command
test_a_top_level_parent_that_dies_during_startup_ends_the_command
test_perl_is_preferred_over_timeout
test_refuses_rather_than_running_unbounded
test_rejects_malformed_bounds_before_running_anything
test_gnu_timeout_kills_a_term_ignoring_command_after_the_grace
test_timed_out_names_exactly_the_bound_statuses
