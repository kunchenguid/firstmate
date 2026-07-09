#!/usr/bin/env bash
# tests/fm-lock.test.sh - behavior tests for bin/fm-lock.sh's acquire-failure
# classification. fm-lock.sh walks process ancestry with `ps` to find the
# harness PID; an acquire failure can mean three very different things, and a
# caller (fm-session-start.sh) must be able to tell them apart:
#
#   lock-held             another live session genuinely holds the lock
#   ps-unavailable        a `ps` invocation failed/was denied (Codex sandbox,
#                         detached background job) so identity is unknowable
#   harness-detect-failed `ps` worked but no harness was found in the ancestry
#
# Every acquire failure must still exit 1 (the caller's LOCK_RC contract), and
# emit a stable FM_LOCK_REASON=<reason> line to stderr alongside the readable
# message. This regression-guards issue #306, where a sandboxed ps failure was
# mislabeled as another session holding the lock.
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

# make_fake_ps_claude <fakebin>: report EVERY queried pid as a live `claude`
# harness, so the first ancestry check (this process's own pid) matches and
# harness detection succeeds deterministically.
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
# every process looks like bash, and every parent resolves to init (pid 1), so
# the ancestry walk exhausts without a match.
make_fake_ps_no_harness() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '/bin/bash\n'; exit 0 ;;
  *"args="*) printf 'bash\n'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_fake_ps_denied <fakebin>: every `ps` invocation fails, mimicking a Codex
# sandbox that denies process inspection.
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

# --- case (i): a real live lock-holder ---------------------------------------

test_lock_held() {
  local rec home fakebin holder_pid out status
  rec=$(new_home lock-held)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_claude "$fakebin"

  # A live process (not this one) already holds the lock; the fake ps reports it
  # as a live claude, so holder_alive() confirms a genuine live holder.
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

  pass "a live lock-holder is classified lock-held and exits 1"
}

# --- case (ii): harness not found in the ancestry (ps works) -----------------

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
  [ ! -f "$home/state/.lock" ] || fail "harness-detect-failed wrote a lock it could not verify"

  pass "a clean ancestry walk with no harness is classified harness-detect-failed"
}

# --- case (iii): ps failed or was denied (Codex sandbox) ---------------------

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
  [ ! -f "$home/state/.lock" ] || fail "ps-unavailable wrote a lock it could not verify"

  pass "a denied ps is classified ps-unavailable, not another session holding the lock"
}

# --- case (iv): status reports lock: free ------------------------------------

test_status_free() {
  local rec home fakebin out status
  rec=$(new_home status-free)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_ps_denied "$fakebin"

  # No lock file present -> status is unambiguously free, regardless of whether
  # process inspection is available. status must never exit non-zero.
  status=0
  out=$(run_lock "$home" "$fakebin" status 2>&1) || status=$?
  expect_code 0 "$status" "status must always exit 0"
  assert_contains "$out" "lock: free" "status did not report a free lock"
  assert_not_contains "$out" "FM_LOCK_REASON=" "status must not emit a failure reason"

  pass "status reports lock: free and exits 0 even when process inspection is denied"
}

test_acquire_success
test_lock_held
test_harness_detect_failed
test_ps_unavailable
test_status_free
