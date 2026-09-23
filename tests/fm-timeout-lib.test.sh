#!/usr/bin/env bash
# Behavior tests for bin/fm-timeout-lib.sh's exec-style bound, fm_exec_timed:
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
      printf '%s\n' "$BASHPID" > "$dir/caller"
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

test_passes_the_command_status_and_output_through
test_term_ends_a_cooperative_command_at_the_bound
test_kill_ends_a_term_ignoring_command_after_the_grace
test_the_bound_replaces_the_calling_shell
test_a_descendant_holding_the_output_cannot_outlast_the_bound
test_a_signal_to_the_bounding_process_reaches_the_command
test_perl_is_preferred_over_timeout
test_refuses_rather_than_running_unbounded
test_rejects_malformed_bounds_before_running_anything
test_gnu_timeout_kills_a_term_ignoring_command_after_the_grace
test_timed_out_names_exactly_the_bound_statuses
