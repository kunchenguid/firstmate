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
# Each case runs under all four mechanisms - timeout, gtimeout, perl, bash -
# forced explicitly one at a time, so a CI host with GNU timeout still exercises
# the perl fallback a coreutils-less machine actually uses, and a stock Mac
# still exercises the timeout path CI runs on. A mechanism whose tool this host
# does not have is reported as an explicit skip rather than passed over.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-timeout-lib)

ALL_MECHANISMS='timeout gtimeout perl bash'

# The mechanisms this host can actually run. bash is dependency-free and always
# present; the other three need their tool installed. Asking the library rather
# than probing PATH here keeps the list honest: a mechanism is only "available"
# if forcing it actually makes fm_run_timed take that path.
available_mechanisms() {
  local mechanism
  for mechanism in $ALL_MECHANISMS; do
    [ "$(FM_TIMEOUT_MECHANISM_OVERRIDE="$mechanism" bash -c '. "$1"; fm_timeout_mechanism' _ "$LIB")" = "$mechanism" ] &&
      printf '%s\n' "$mechanism"
  done
  return 0
}

# Naming what this host cannot reach keeps a partial run from reading as a full
# one: on a stock Mac that is timeout and gtimeout, on CI it is usually neither.
report_unavailable_mechanisms() {
  local mechanism available
  available=$(available_mechanisms)
  for mechanism in $ALL_MECHANISMS; do
    case "$available" in
      *"$mechanism"*) ;;
      *) printf '# skip - the %s mechanism needs a %s binary this host does not have\n' \
        "$mechanism" "$mechanism" ;;
    esac
  done
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

resolve_mechanism() { # [<override>]
  if [ "$#" -ge 1 ]; then
    FM_TIMEOUT_MECHANISM_OVERRIDE="$1" bash -c '. "$1"; fm_timeout_mechanism' _ "$LIB"
  else
    bash -c 'unset FM_TIMEOUT_MECHANISM_OVERRIDE; . "$1"; fm_timeout_mechanism' _ "$LIB"
  fi
}

test_the_override_never_shifts_what_callers_get_by_default() {
  local detected expected
  # The knob exists for this suite, not for callers, so an unset or empty value
  # has to leave the documented precedence - timeout, gtimeout, perl, bash -
  # exactly as it was before the knob widened.
  if command -v timeout >/dev/null 2>&1; then
    expected=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    expected=gtimeout
  elif command -v perl >/dev/null 2>&1; then
    expected=perl
  else
    expected=bash
  fi

  detected=$(resolve_mechanism)
  assert_equals "$expected" "$detected" "an unset override did not leave host detection unchanged"
  detected=$(resolve_mechanism '')
  assert_equals "$expected" "$detected" "an empty override did not leave host detection unchanged"
  detected=$(resolve_mechanism 'not-a-mechanism')
  assert_equals "$expected" "$detected" "an unrecognized override was not ignored in favor of host detection"
  pass "the mechanism override changes nothing for callers that do not set it"
}

test_an_override_for_a_missing_tool_falls_back_instead_of_breaking() {
  local mechanism detected available
  available=$(available_mechanisms)
  assert_contains "$available" bash "the dependency-free bash mechanism should always be reachable"
  for mechanism in $ALL_MECHANISMS; do
    case "$available" in
      *"$mechanism"*) continue ;;
    esac
    detected=$(resolve_mechanism "$mechanism")
    assert_not_equals "$mechanism" "$detected" \
      "forcing the absent $mechanism mechanism claimed to select it"
    assert_not_equals "" "$detected" \
      "forcing the absent $mechanism mechanism resolved to nothing at all"
  done
  pass "forcing a mechanism this host lacks falls back to a usable one instead of failing"
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

report_unavailable_mechanisms
test_the_override_never_shifts_what_callers_get_by_default
test_an_override_for_a_missing_tool_falls_back_instead_of_breaking
test_ordinary_exit_statuses_survive_the_runner
test_signal_killed_command_is_not_reported_as_success
test_a_terminating_signal_other_than_kill_is_also_nonzero
test_the_bound_still_reports_124

echo "# all fm-timeout-lib tests passed"
