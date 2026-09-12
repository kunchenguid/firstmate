#!/usr/bin/env bash
# tests/fm-lock.test.sh - argument handling of the session-lock entry point
# (bin/fm-lock.sh).
#
# The hazard this pins is that fm-lock.sh ACQUIRES the home's session lock when
# it is run with no argument, and the session lock is what decides which session
# may mutate the fleet at all. So every argument the script does not recognize -
# `--help` most of all, since that is what a person types to find out what the
# script does - must be refused without the lock being taken. The cases below
# drive the real script end to end and judge it by what is on disk afterwards:
# whether state/.lock exists and what it holds, never by reading the script's
# own source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock)

# A home whose ancestry resolves to a harness, so the bare acquire path can
# actually succeed and is not passing merely because identity failed first. The
# fake ps reports this suite's own process as a claude session and every other
# pid as its parent, exactly as the neighbouring session-lock suites do.
make_home() { # <name> -> echoes the home dir
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  *:comm=) printf '%s\n' claude ;;
  *:args=) printf '%s\n' claude ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$dir"
}

run_lock() { # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" PATH="$home/fakebin:$PATH" bash "$ROOT/bin/fm-lock.sh" "$@"
}

test_unrecognized_argument_refuses_and_leaves_the_lock_unclaimed() {
  local home out rc arg
  home=$(make_home unrecognized)
  for arg in --help-me -x status-please --lock; do
    out=$(run_lock "$home" "$arg" 2>&1)
    rc=$?
    expect_code 2 "$rc" "'$arg' must be refused as a usage error, not accepted or confused with a held lock"
    assert_contains "$out" "unrecognized argument" "'$arg' was refused without saying which argument was wrong"
    assert_contains "$out" "fm-lock.sh status" "'$arg' was refused without printing the usage that names the real forms"
    assert_absent "$home/state" "'$arg' created the home's session-lock state directory while being refused"
  done
  # The same must hold for an extra argument trailing either form that IS
  # recognized: it is still an argument the script does not recognize.
  for arg in status --help; do
    out=$(run_lock "$home" "$arg" extra 2>&1)
    rc=$?
    expect_code 2 "$rc" "a trailing extra argument after '$arg' must be refused as a usage error"
    assert_contains "$out" "unexpected extra argument" "the argument trailing '$arg' was refused without naming it"
    assert_absent "$home/state" "a trailing extra argument after '$arg' created the session-lock state directory"
  done
  pass "fm-lock: an unrecognized argument is refused with exit 2 and leaves the session lock unclaimed"
}

test_help_prints_usage_without_touching_the_lock() {
  local home out flag
  home=$(make_home help)
  for flag in --help -h; do
    out=$(run_lock "$home" "$flag" 2>&1)
    expect_code 0 "$?" "'$flag' must be answered with usage, not an error"
    assert_contains "$out" "fm-lock.sh status" "'$flag' did not print the documented status form"
    assert_contains "$out" "acquire the session lock" "'$flag' did not print the documented acquire form"
    assert_absent "$home/state" "'$flag' created the home's session-lock state directory"
  done
  pass "fm-lock: --help and -h print usage on exit 0 and never claim the lock"
}

test_status_still_reports_the_holder() {
  local home out
  home=$(make_home status)
  out=$(run_lock "$home" status)
  expect_code 0 "$?" "status on a free home must still exit 0"
  assert_contains "$out" "lock: free" "status did not report an unheld lock as free"
  assert_absent "$home/state/.lock" "status created the lock it was only asked to inspect"

  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(run_lock "$home" status)
  expect_code 0 "$?" "status on a held home must still exit 0"
  assert_contains "$out" "held by live harness pid $$" "status did not report the live holder it found"
  pass "fm-lock: status still prints the holder and exits 0"
}

test_bare_invocation_still_acquires() {
  local home out claimed written
  home=$(make_home acquire)
  out=$(run_lock "$home")
  expect_code 0 "$?" "the bare acquire path must still succeed"
  assert_contains "$out" "lock acquired: harness pid" "the bare invocation did not report the acquisition"
  assert_present "$home/state/.lock" "the bare invocation did not write the session lock"
  claimed=${out##*harness pid }
  written=$(tr -d '[:space:]' < "$home/state/.lock")
  [ -n "$written" ] && [ "$written" = "$claimed" ] \
    || fail "the reported holder and the recorded one disagree: reported '$claimed', recorded '$written'"
  pass "fm-lock: the bare invocation still acquires the session lock"
}

test_unrecognized_argument_refuses_and_leaves_the_lock_unclaimed
test_help_prints_usage_without_touching_the_lock
test_status_still_reports_the_holder
test_bare_invocation_still_acquires
