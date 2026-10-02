#!/usr/bin/env bash
# tests/fm-lock.test.sh - behavior tests for bin/fm-lock.sh's acquire-failure
# classification. fm-lock.sh walks process ancestry with `ps` to identify this
# session's harness; an acquire failure can mean three very different things,
# and a caller (fm-session-start.sh) must be able to tell them apart:
#
#   lock-held              another live session genuinely holds the lock
#   ps-unavailable         a `ps` invocation failed or was denied (a Codex
#                          sandbox), so this session cannot identify its harness
#   harness-detect-failed  `ps` worked but the ancestry walk found no verified
#                          harness (a sandboxed PID namespace or a plain shell)
#
# Every acquire failure still exits 1, and each class carries its own
# human-readable error beside the stable FM_LOCK_REASON=<reason> stderr line.
# fm-lock.sh status must stay honest instead: free is free, a dead recorded pid
# with a working `ps` is stale, and a pid a denied `ps` cannot classify is
# unknown, never held or stale.
# This regression-guards issue #306, where a sandboxed process-inspection
# failure was conflated with another live session holding the lock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-lock-tests)

# new_home <name>: a fresh FM_HOME with an empty state/ and a fakebin. Echoes
# "<home>|<fakebin>".
new_home() {
  local name=$1 w home fakebin
  w="$TMP_ROOT/$name"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$fakebin"
  printf '%s|%s\n' "$home" "$fakebin"
}

# make_fake_ps_claude <fakebin>: report every queried pid as a live `claude`
# harness and stop the walk at the invoking process, so the session identifies
# itself deterministically without depending on the host's real ancestry.
make_fake_ps_claude() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_fake_ps_no_harness <fakebin>: `ps` works but never reports a harness -
# every process is bash, and the ancestry climbs to a non-harness pid 1 whose
# parent is 0, so a complete walk ends without a match.
make_fake_ps_no_harness() {
  local fakebin=$1
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
case "$field" in
  comm=|args=) printf '/bin/bash\n' ;;
  ppid=) [ "$pid" = 1 ] && printf '0\n' || printf '1\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

# make_fake_ps_climb_fails <fakebin>: `ps` inspects the invoking process but
# fails every parent lookup, so the walk is cut short above a working
# inspection of the live current process itself.
make_fake_ps_climb_fails() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '/bin/bash\n'; exit 0 ;;
  *"args="*) printf 'bash\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_fake_ps_denied <fakebin>: every `ps` invocation fails, mimicking a Codex
# sandbox that denies process inspection entirely.
make_fake_ps_denied() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"
}

run_lock() {  # <home> <fakebin> [args...]
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" "$@"
}

# A definitely-dead pid: a reaped child, so a working `ps` genuinely cannot
# find it.
dead_pid() {
  local pid
  sleep 0.2 & pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

# --- success: a clean acquire still works ------------------------------------

test_acquire_success() {
  local rec home fakebin out status
  rec=$(new_home acquire-success)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_claude "$fakebin"

  status=0
  out=$(run_lock "$home" "$fakebin" 2>&1) || status=$?
  expect_code 0 "$status" "a clean acquire must exit 0"
  assert_contains "$out" "lock acquired: harness pid" "success path did not report the acquired lock"
  assert_not_contains "$out" "FM_LOCK_REASON=" "success path must not emit a failure reason"
  [ -f "$home/state/.lock" ] || fail "acquire did not write the lock file"

  pass "a clean acquire writes the lock and exits 0 with no failure reason"
}

# --- lock-held: a real live lock-holder --------------------------------------

test_lock_held() {
  local rec home fakebin holder_pid out status
  rec=$(new_home lock-held)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_claude "$fakebin"

  # A live process this session can identify as a harness, but one that is not
  # this session's own anchor, is a genuine foreign live holder.
  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"

  status=0
  out=$(run_lock "$home" "$fakebin" 2>&1) || status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  expect_code 1 "$status" "a live-held lock must exit 1"
  assert_contains "$out" "FM_LOCK_REASON=lock-held" "live-held lock did not emit the lock-held reason token"
  assert_contains "$out" "another live firstmate session holds the lock" "live-held lock dropped its readable message"
  assert_not_contains "$out" "ps-unavailable" "live-held lock was misclassified as an inspection failure"
  assert_not_contains "$out" "harness-detect-failed" "live-held lock was misclassified as a walk without a harness"
  [ "$(cat "$home/state/.lock")" = "$holder_pid" ] || fail "a live-held lock was rewritten by a refusing session"

  pass "a live lock-holder is classified lock-held and exits 1"
}

# --- harness-detect-failed: ps works but no harness in the ancestry ----------

test_harness_detect_failed() {
  local rec home fakebin out status
  rec=$(new_home harness-detect-failed)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_no_harness "$fakebin"

  status=0
  out=$(run_lock "$home" "$fakebin" 2>&1) || status=$?
  expect_code 1 "$status" "a failed harness detection must still exit 1"
  assert_contains "$out" "FM_LOCK_REASON=harness-detect-failed" "harness-not-found did not emit the harness-detect-failed reason token"
  assert_contains "$out" "cannot locate harness process in ancestry" "harness-detect-failed dropped the existing readable message"
  assert_not_contains "$out" "another live firstmate session holds the lock" "harness-detect-failed falsely claimed another session"
  assert_not_contains "$out" "FM_LOCK_REASON=ps-unavailable" "a working ps was misclassified as ps-unavailable"
  [ ! -e "$home/state/.lock" ] || fail "harness-detect-failed wrote a lock it could not verify"

  pass "a complete ancestry walk with no harness is classified harness-detect-failed"
}

# --- ps-unavailable: ps failed or was denied (the Codex-sandbox shape) -------

test_ps_unavailable() {
  local rec home fakebin out status
  rec=$(new_home ps-unavailable)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_denied "$fakebin"

  status=0
  out=$(run_lock "$home" "$fakebin" 2>&1) || status=$?
  expect_code 1 "$status" "a denied ps must still exit 1"
  assert_contains "$out" "FM_LOCK_REASON=ps-unavailable" "denied ps did not emit the ps-unavailable reason token"
  assert_contains "$out" "ps failed or was denied" "ps-unavailable dropped its readable message"
  assert_not_contains "$out" "another live firstmate session holds the lock" "ps-unavailable falsely claimed another session"
  assert_not_contains "$out" "FM_LOCK_REASON=harness-detect-failed" "a denied ps was misclassified as a completed walk"
  [ ! -e "$home/state/.lock" ] || fail "ps-unavailable wrote a lock it could not verify"

  pass "a denied ps is classified ps-unavailable, not another session holding the lock"
}

# --- boundary: a working self-inspection whose climb fails ------------------

test_climb_failure_is_not_ps_unavailable() {
  local rec home fakebin out status
  rec=$(new_home climb-fails)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_climb_fails "$fakebin"

  status=0
  out=$(run_lock "$home" "$fakebin" 2>&1) || status=$?
  expect_code 1 "$status" "a cut-short walk must still exit 1"
  assert_contains "$out" "FM_LOCK_REASON=harness-detect-failed" "a ps that inspects the live invoking shell was misclassified as unavailable"
  assert_not_contains "$out" "FM_LOCK_REASON=ps-unavailable" "ps-unavailable must stay reserved for a ps that cannot inspect the live invoking shell"

  pass "a walk cut short above a working self-inspection stays harness-detect-failed"
}

# --- status stays honest -----------------------------------------------------

test_status_free_under_denied_ps() {
  local rec home fakebin out status
  rec=$(new_home status-free-denied)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_denied "$fakebin"

  # No lock file exists, so the status is unambiguously free no matter what
  # process inspection is allowed to see - the exact shape issue #306 reported.
  status=0
  out=$(run_lock "$home" "$fakebin" status 2>&1) || status=$?
  expect_code 0 "$status" "status must always exit 0"
  assert_contains "$out" "lock: free" "status did not report a free lock under denied process inspection"
  assert_not_contains "$out" "FM_LOCK_REASON=" "status must not emit a failure reason"

  pass "status reports lock: free and exits 0 even when process inspection is denied"
}

test_status_stale_with_working_ps() {
  local rec home fakebin gone out status
  rec=$(new_home status-stale)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  # No fake ps: the real one decides, so a genuinely dead recorded pid is
  # reported from a working process inspection exactly as on a live host.
  gone=$(dead_pid)
  printf '%s\n' "$gone" > "$home/state/.lock"

  status=0
  out=$(run_lock "$home" "$fakebin" status 2>&1) || status=$?
  expect_code 0 "$status" "status must always exit 0"
  assert_contains "$out" "lock: stale" "a dead recorded pid under a working ps was not reported stale"
  assert_not_contains "$out" "lock: unknown" "a working ps proved the recorded pid dead, so unknown is dishonest"

  pass "status reports a dead recorded pid as stale when ps works"
}

test_status_unknown_under_denied_ps() {
  local rec home fakebin gone out status
  rec=$(new_home status-unknown-denied)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_denied "$fakebin"
  gone=$(dead_pid)
  printf '%s\n' "$gone" > "$home/state/.lock"

  status=0
  out=$(run_lock "$home" "$fakebin" status 2>&1) || status=$?
  expect_code 0 "$status" "status must always exit 0"
  assert_contains "$out" "lock: unknown" "a pid a denied ps cannot classify was not reported unknown"
  assert_not_contains "$out" "lock: stale" "a denied ps cannot prove a recorded pid dead, so stale is dishonest"
  assert_not_contains "$out" "lock: held" "a denied ps cannot prove a recorded pid a live harness, so held is dishonest"

  pass "status reports a pid a denied ps cannot classify as unknown, never stale or held"
}

test_acquire_success
test_lock_held
test_harness_detect_failed
test_ps_unavailable
test_climb_failure_is_not_ps_unavailable
test_status_free_under_denied_ps
test_status_stale_with_working_ps
test_status_unknown_under_denied_ps
