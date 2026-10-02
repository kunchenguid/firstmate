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
for tool in perl bash sh sleep; do
  ln -s "$(command -v "$tool")" "$PERL_ONLY/$tool"
done

# A PATH with perl but neither sh nor a BASHPID-capable caller: the frame pid
# resolution has nothing left to fall back on and must refuse.
NO_SH="$TMP_ROOT/no-sh-bin"
mkdir -p "$NO_SH"
for tool in perl bash touch; do
  ln -s "$(command -v "$tool")" "$NO_SH/$tool"
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
      # Bash 3.2 has no BASHPID; an exec'd child shell's PPID names this frame.
      printf '%s\n' "${BASHPID:-$(exec sh -c 'printf "%s\n" "$PPID"')}" > "$dir/caller"
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
  local dir watchdog started
  dir="$TMP_ROOT/startup-owner"
  mkdir -p "$dir"
  # shellcheck disable=SC2016
  PATH=$PERL_ONLY bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    (
      while kill -0 "$$" 2>/dev/null; do sleep 0.05; done
      fm_exec_timed 60 1 bash -c "exec sleep 300"
    ) >/dev/null 2>&1 &
    echo "$!" > "$2/watchdog"
    exit 0
  ' _ "$ROOT" "$dir"
  wait_for_file "$dir/watchdog"
  watchdog=$(cat "$dir/watchdog")
  started=$SECONDS
  while kill -0 "$watchdog" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge 15 ]; then
      kill -KILL "$watchdog" 2>/dev/null || true
      fail "a watchdog whose owner died during startup ran on toward its bound"
    fi
    sleep 0.02
  done
  pass "fm_exec_timed ends the command when its owner dies during watchdog startup"
}

# owner_death_without_bashpid <case>: run <dir>/start under a bash with no
# BASHPID - stock macOS Bash 3.2 has none, and a newer bash is made to lack it
# by unsetting it in-shell, which the shell does not repopulate the way it does
# after env -u. The start script lets the bounded command's owner die before
# the watchdog starts, so only the owner the library resolved can end the
# command before its bound. The escalation can reach the command before it
# records its pid, so a recorded pid is checked only when there is one; the
# library's own failure shows on stderr instead.
owner_death_without_bashpid() {  # <case>
  local dir=$TMP_ROOT/no-bashpid-$1 watchdog started
  # shellcheck disable=SC2016 # the bounded shell expands its own argument
  PATH=$PERL_ONLY bash -c 'unset BASHPID; . "$1/start"' _ "$dir"
  wait_for_file "$dir/watchdog"
  watchdog=$(cat "$dir/watchdog")
  started=$SECONDS
  while kill -0 "$watchdog" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge 15 ]; then
      kill -KILL "$watchdog" 2>/dev/null || true
      [ ! -s "$dir/command" ] || kill -KILL "$(cat "$dir/command")" 2>/dev/null || true
      fail "without BASHPID ($1) a watchdog whose owner died during startup ran on toward its bound"
    fi
    sleep 0.02
  done
  [ ! -s "$dir/errors" ] || fail "without BASHPID ($1) fm_exec_timed failed: $(cat "$dir/errors")"
  [ ! -s "$dir/command" ] || ! kill -0 "$(cat "$dir/command")" 2>/dev/null \
    || fail "without BASHPID ($1) the bounded command outlived its owner"
}

# write_bounded_command <dir>: the command both cases bound, which ignores TERM
# once it is running so only the grace's KILL can end it.
write_bounded_command() {  # <dir>
  mkdir -p "$1"
  # shellcheck disable=SC2016 # the bounded command expands its own pid
  printf '%s\n' 'trap "" TERM' 'echo "$$" > "$1"' 'exec sleep 300' > "$1/command.sh"
}

# A subshell caller's owner is the calling script ($$), which only the
# subshell's own pid tells apart from the frame about to become the watchdog.
test_a_subshell_owner_is_watched_without_bashpid() {
  local dir=$TMP_ROOT/no-bashpid-subshell
  write_bounded_command "$dir"
  cat > "$dir/start" <<FIXTURE
. "$ROOT/bin/fm-timeout-lib.sh"
(
  while kill -0 "\$\$" 2>/dev/null; do sleep 0.05; done
  fm_exec_timed 60 1 bash "$dir/command.sh" "$dir/command"
) >/dev/null 2>"$dir/errors" &
echo "\$!" > "$dir/watchdog"
FIXTURE
  owner_death_without_bashpid subshell
  pass "fm_exec_timed watches a subshell caller's script as owner without BASHPID"
}

# A caller running fm_exec_timed in its own main shell is the frame the
# watchdog replaces, so its owner is its parent. $PPID is fixed at shell
# startup, so the caller must capture it and signal the capture before start
# exits: otherwise start can exit, and the caller can be reparented, before it
# ever reads $PPID, and it would then spin-wait on a live process forever.
test_a_main_shell_owner_is_watched_without_bashpid() {
  local dir=$TMP_ROOT/no-bashpid-main-shell
  write_bounded_command "$dir"
  cat > "$dir/caller" <<FIXTURE
unset BASHPID
. "$ROOT/bin/fm-timeout-lib.sh"
original_parent=\$PPID
: > "$dir/captured"
while kill -0 "\$original_parent" 2>/dev/null; do sleep 0.05; done
fm_exec_timed 60 1 bash "$dir/command.sh" "$dir/command"
FIXTURE
  cat > "$dir/start" <<FIXTURE
bash "$dir/caller" >/dev/null 2>"$dir/errors" &
echo "\$!" > "$dir/watchdog"
while [ ! -e "$dir/captured" ]; do sleep 0.02; done
FIXTURE
  owner_death_without_bashpid main-shell
  pass "fm_exec_timed watches a main-shell caller's parent as owner without BASHPID"
}

# Without BASHPID and without sh, fm_exec_timed has no way left to name its own
# frame pid, so it must refuse instead of silently keeping $$ as the owner -
# which would watch the wrong process and could never detect that owner's
# death.
test_refuses_when_it_cannot_resolve_its_frame_pid_without_bashpid() {
  local dir out rc=0
  dir="$TMP_ROOT/no-frame-pid"
  mkdir -p "$dir"
  out=$(PATH=$NO_SH bash -c '
    unset BASHPID
    . "$1/bin/fm-timeout-lib.sh"
    fm_exec_timed 5 1 touch "$2/ran"
  ' _ "$ROOT" "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm_exec_timed ran without resolving its frame pid (rc=$rc)"
  [ ! -e "$dir/ran" ] || fail "fm_exec_timed ran the command despite failing to resolve its frame pid"
  assert_contains "$out" "could not determine the calling shell pid" \
    "fm_exec_timed's refusal did not name why it failed"
  pass "fm_exec_timed refuses when BASHPID is unset and it cannot resolve its frame pid"
}

# perl is preferred whenever it exists, because only its watchdog can reap a
# leftover descendant after replacing the caller.
test_perl_is_preferred_over_timeout() {
  local dir out
  dir="$TMP_ROOT/prefer"
  mkdir -p "$dir/bin"
  for tool in perl bash sh; do
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
  for tool in bash sh; do
    ln -s "$(command -v "$tool")" "$dir/bin/$tool"
  done
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
  for tool in timeout bash sleep sh; do
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

test_passes_the_command_status_and_output_through
test_run_timed_reports_the_bound_when_the_wrapper_records_a_signal_death
test_run_timed_passes_a_natural_exit_through_a_fired_bound
test_term_ends_a_cooperative_command_at_the_bound
test_kill_ends_a_term_ignoring_command_after_the_grace
test_the_bound_replaces_the_calling_shell
test_a_descendant_holding_the_output_cannot_outlast_the_bound
test_a_signal_to_the_bounding_process_reaches_the_command
test_a_named_owner_that_is_gone_ends_the_command
test_an_owner_that_dies_during_startup_ends_the_command
test_a_subshell_owner_is_watched_without_bashpid
test_a_main_shell_owner_is_watched_without_bashpid
test_refuses_when_it_cannot_resolve_its_frame_pid_without_bashpid
test_perl_is_preferred_over_timeout
test_refuses_rather_than_running_unbounded
test_rejects_malformed_bounds_before_running_anything
test_gnu_timeout_kills_a_term_ignoring_command_after_the_grace
test_timed_out_names_exactly_the_bound_statuses
