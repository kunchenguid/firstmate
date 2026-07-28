#!/usr/bin/env bash
# Unit tests for bin/fm-parlay-lib.sh - the best-effort Parlay chat-panel
# enrollment/deregistration helpers wired into fm-spawn.sh/fm-teardown.sh.
#
# `parlay listen --agent <id>` never returns (it execs into a poll loop), so
# fm_parlay_listen must background it rather than block the caller; these
# tests assert that instead of a hang, the call returns immediately, records
# the backgrounded pid, and a fake `parlay` observes the expected invocation.
# Every function must be a no-op (never fail, never hang) when `parlay` is not
# on PATH, since Parlay enrollment is an enhancement, never a dependency.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-parlay-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-parlay-lib)

# make_fake_parlay <dir>: a fake `parlay` that logs every invocation to
# <dir>/calls.log, sleeps briefly on `listen` to stand in for the real
# never-returning poll loop, and exits 1 whenever <dir>/fail-marker exists.
make_fake_parlay() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/parlay" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/calls.log"
[ ! -e "$dir/fail-marker" ] || exit 1
case "\$1" in
  listen) sleep 30 ;;
esac
exit 0
SH
  chmod +x "$fakebin/parlay"
  printf '%s\n' "$fakebin"
}

# wait_for_line <pattern> <file>: poll up to ~15s for a backgrounded process to
# flush its log line (fm_parlay_listen/agent_down return before their child
# process, or the caller's own background job above, has necessarily written).
# A loaded box can leave a freshly-forked background process unscheduled for
# several seconds, so this is deliberately generous rather than tight.
wait_for_line() {
  local pattern=$1 file=$2 i=0
  while [ "$i" -lt 150 ]; do
    grep -F -- "$pattern" "$file" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

test_listen_backgrounds_and_records_pid() {
  local case_dir fakebin state pidfile pid
  case_dir="$TMP_ROOT/listen-ok"
  mkdir -p "$case_dir/state"
  fakebin=$(make_fake_parlay "$case_dir")
  state="$case_dir/state"

  # shellcheck disable=SC2123,SC2030
  # shellcheck source=/dev/null
  ( PATH="$fakebin:$PATH"; . "$LIB"; fm_parlay_listen listen-ok-z1 "$state" )
  status=$?
  expect_code 0 "$status" "fm_parlay_listen should return immediately, not hang on the poll loop"

  pidfile="$state/listen-ok-z1.parlay-listen.pid"
  [ -f "$pidfile" ] || fail "fm_parlay_listen did not record a pid file"
  pid=$(cat "$pidfile")
  [ -n "$pid" ] || fail "recorded pid file was empty"
  kill -0 "$pid" 2>/dev/null || fail "recorded pid is not a running process"

  wait_for_line "listen --agent listen-ok-z1" "$case_dir/calls.log" \
    || fail "parlay was not invoked as 'listen --agent <id>'"
  kill "$pid" 2>/dev/null || true
  pass "fm_parlay_listen backgrounds 'parlay listen --agent <id>' and records its pid"
}

test_listen_noop_without_parlay_on_path() {
  local case_dir state status
  case_dir="$TMP_ROOT/listen-absent"
  mkdir -p "$case_dir/state" "$case_dir/emptybin"
  state="$case_dir/state"

  # shellcheck disable=SC2123,SC2030
  # shellcheck source=/dev/null
  ( PATH="$case_dir/emptybin"; . "$LIB"; fm_parlay_listen listen-absent-z2 "$state" )
  status=$?
  expect_code 0 "$status" "fm_parlay_listen must not fail when parlay is missing"
  assert_absent "$state/listen-absent-z2.parlay-listen.pid" \
    "fm_parlay_listen wrote a pid file despite parlay being absent"
  pass "fm_parlay_listen is a silent no-op when parlay is not on PATH"
}

test_agent_down_kills_pid_and_deregisters() {
  local case_dir fakebin state pidfile status
  case_dir="$TMP_ROOT/down-ok"
  mkdir -p "$case_dir/state"
  fakebin=$(make_fake_parlay "$case_dir")
  state="$case_dir/state"
  pidfile="$state/down-ok-z3.parlay-listen.pid"

  # Stand in for a still-running listen poller with a real long-lived process.
  sh -c 'sleep 30' &
  printf '%s\n' "$!" > "$pidfile"

  # shellcheck disable=SC2030,SC2031
  # shellcheck source=/dev/null
  ( PATH="$fakebin:$PATH"; . "$LIB"; fm_parlay_agent_down down-ok-z3 "$state" )
  status=$?
  expect_code 0 "$status" "fm_parlay_agent_down should succeed"

  assert_absent "$pidfile" "fm_parlay_agent_down did not remove the pid file"
  assert_grep "agent-down down-ok-z3" "$case_dir/calls.log" \
    "parlay was not invoked as 'agent-down <id>'"
  pass "fm_parlay_agent_down stops the recorded poller and calls 'agent-down <id>'"
}

test_agent_down_failure_is_best_effort() {
  local case_dir fakebin state status out
  case_dir="$TMP_ROOT/down-fail"
  mkdir -p "$case_dir/state"
  fakebin=$(make_fake_parlay "$case_dir")
  touch "$case_dir/fail-marker"
  state="$case_dir/state"

  # shellcheck disable=SC2030,SC2031
  # shellcheck source=/dev/null
  out=$( ( PATH="$fakebin:$PATH"; . "$LIB"; fm_parlay_agent_down down-fail-z4 "$state" ) 2>&1 )
  status=$?
  expect_code 0 "$status" "a failing parlay agent-down must not fail teardown's best-effort call"
  assert_contains "$out" "warning:" "a failed agent-down should warn, not stay silent"
  pass "fm_parlay_agent_down is best-effort: a failing parlay call warns but never fails"
}

test_agent_down_noop_without_parlay_on_path() {
  local case_dir state status
  case_dir="$TMP_ROOT/down-absent"
  mkdir -p "$case_dir/state" "$case_dir/emptybin"
  state="$case_dir/state"
  printf '99999999\n' > "$state/down-absent-z5.parlay-listen.pid"

  # shellcheck disable=SC2123
  # shellcheck source=/dev/null
  ( PATH="$case_dir/emptybin"; . "$LIB"; fm_parlay_agent_down down-absent-z5 "$state" )
  status=$?
  expect_code 0 "$status" "fm_parlay_agent_down must not fail when parlay is missing"
  assert_grep 99999999 "$state/down-absent-z5.parlay-listen.pid" \
    "fm_parlay_agent_down should not touch the pid file when parlay is absent"
  pass "fm_parlay_agent_down is a silent no-op when parlay is not on PATH"
}

test_listen_backgrounds_and_records_pid
test_listen_noop_without_parlay_on_path
test_agent_down_kills_pid_and_deregisters
test_agent_down_failure_is_best_effort
test_agent_down_noop_without_parlay_on_path

echo "# all fm-parlay-lib tests passed"
