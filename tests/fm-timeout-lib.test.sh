#!/usr/bin/env bash
# tests/fm-timeout-lib.test.sh - the exit-status contract of the shared bounded
# runner (bin/fm-timeout-lib.sh).
#
# Every caller in bin/ decides whether a bounded command succeeded by reading
# fm_run_timed's status, and bin/fm-spawn.sh's setup hook refuses a spawn on
# that status alone, so the four mechanisms have to agree on what failure looks
# like. These cases drive the real runner against real child processes and
# assert the status it reports: a normal exit survives, a signal death is
# nonzero (128 + signal, the shell convention), and the bound still reports 124.
#
# Each case runs under every mechanism the host can reach, forced explicitly, so
# a host with GNU timeout installed still exercises the perl fallback that a
# coreutils-less machine actually uses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-timeout-lib)

# The mechanisms this host can actually run. bash is dependency-free and always
# present; perl is the one a stock macOS host falls through to.
available_mechanisms() {
  printf 'bash\n'
  command -v perl >/dev/null 2>&1 && printf 'perl\n'
  return 0
}

# Drop a child script and print its path.
write_child() { # <name> <body>
  local path="$TMP_ROOT/$1"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# Run fm_run_timed in a fresh shell with one mechanism forced, and print the
# status it reported. Output is discarded; this suite is about the status.
run_timed_status() { # <mechanism> <seconds> <command...>
  local mechanism=$1
  shift
  FM_TIMEOUT_MECHANISM_OVERRIDE="$mechanism" bash -c \
    '. "$1"; shift; fm_run_timed "$@"' _ "$LIB" "$@" >/dev/null 2>&1
  printf '%s\n' "$?"
}

test_mechanism_forcing_reaches_the_path_under_test() {
  local mechanism seen
  # Without this the whole suite could pass vacuously by testing one mechanism
  # four times, which is exactly what happens on a host with GNU timeout if the
  # override only honors bash.
  for mechanism in $(available_mechanisms); do
    seen=$(FM_TIMEOUT_MECHANISM_OVERRIDE="$mechanism" bash -c '. "$1"; fm_timeout_mechanism' _ "$LIB")
    assert_equals "$mechanism" "$seen" \
      "forcing the $mechanism mechanism did not select it, so cases below would not exercise it"
  done
  pass "each available mechanism can be forced, so every case below reaches the path it names"
}

test_signal_killed_command_is_not_reported_as_success() {
  local mechanism child status
  # A hook killed by the OOM killer or a segfault must not read as success:
  # bin/fm-spawn.sh launches a worker into the worktree when this status is 0.
  child=$(write_child kill-self 'kill -9 $$')
  for mechanism in $(available_mechanisms); do
    status=$(run_timed_status "$mechanism" 10 "$child")
    assert_not_equals 0 "$status" \
      "the $mechanism mechanism reported a SIGKILLed command as success"
    assert_equals 137 "$status" \
      "the $mechanism mechanism did not report SIGKILL as 128 + 9"
  done
  pass "a command killed by a signal reports 128 + the signal on every mechanism"
}

test_a_terminating_signal_other_than_kill_is_also_nonzero() {
  local mechanism child status
  child=$(write_child term-self 'kill -TERM $$')
  for mechanism in $(available_mechanisms); do
    status=$(run_timed_status "$mechanism" 10 "$child")
    assert_equals 143 "$status" \
      "the $mechanism mechanism did not report SIGTERM as 128 + 15"
  done
  pass "a command killed by SIGTERM reports 128 + the signal on every mechanism"
}

test_ordinary_exit_statuses_survive_the_runner() {
  local mechanism child status
  child=$(write_child exit-zero 'exit 0')
  for mechanism in $(available_mechanisms); do
    status=$(run_timed_status "$mechanism" 10 "$child")
    expect_code 0 "$status" "the $mechanism mechanism lost a successful command's status"
  done

  child=$(write_child exit-seven 'exit 7')
  for mechanism in $(available_mechanisms); do
    status=$(run_timed_status "$mechanism" 10 "$child")
    expect_code 7 "$status" "the $mechanism mechanism lost a failing command's own exit status"
  done
  pass "a command that exits normally reports its own status on every mechanism"
}

test_the_bound_still_reports_124() {
  local mechanism child status
  # 124 is the whole library's "the bound was hit" convention, and the setup
  # hook's timeout refusal reads it, so it must not collide with the signal
  # statuses above even though the runner kills the child with TERM then KILL.
  child=$(write_child sleep-past-bound 'sleep 30')
  for mechanism in $(available_mechanisms); do
    status=$(run_timed_status "$mechanism" 1 "$child")
    expect_code 124 "$status" "the $mechanism mechanism did not report a hit bound as 124"
  done
  pass "a command that runs past its bound still reports 124 on every mechanism"
}

test_mechanism_forcing_reaches_the_path_under_test
test_ordinary_exit_statuses_survive_the_runner
test_signal_killed_command_is_not_reported_as_success
test_a_terminating_signal_other_than_kill_is_also_nonzero
test_the_bound_still_reports_124

echo "# all fm-timeout-lib tests passed"
