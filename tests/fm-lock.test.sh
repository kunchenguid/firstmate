#!/usr/bin/env bash
# tests/fm-lock.test.sh - session-lock acquisition publication failures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock)
LOCK="$ROOT/bin/fm-lock.sh"

make_fake_ps() {  # <case-dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=|args=) printf '%s\n' codex ;;
  ppid=) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_state_creation_failure_is_read_only() {
  local dir state out status
  dir="$TMP_ROOT/state-creation"
  mkdir -p "$dir"
  : > "$dir/not-a-directory"
  state="$dir/not-a-directory/state"

  status=0
  out=$(FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1) || status=$?

  [ "$status" -ne 0 ] || fail "state creation failure reported successful lock acquisition"
  assert_contains "$out" "cannot create session-lock state directory" \
    "state creation failure did not explain the read-only boundary"
  assert_not_contains "$out" "lock acquired" \
    "state creation failure printed a successful acquisition"
  [ ! -e "$state/.lock" ] || fail "state creation failure published a session lock"
  pass "fm-lock: state creation failure fails closed"
}

test_lock_write_failure_is_read_only() {
  local dir state fakebin out status
  dir="$TMP_ROOT/lock-write"
  state="$dir/state"
  mkdir -p "$state"
  fakebin=$(make_fake_ps "$dir")
  chmod 0500 "$state"

  status=0
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1) || status=$?
  chmod 0700 "$state"

  [ "$status" -ne 0 ] || fail "lock write failure reported successful acquisition"
  assert_contains "$out" "cannot write session lock" \
    "lock write failure did not explain the read-only boundary"
  assert_not_contains "$out" "lock acquired" \
    "lock write failure printed a successful acquisition"
  [ ! -e "$state/.lock" ] || fail "lock write failure left a published session lock"
  pass "fm-lock: lock write failure fails closed"
}

test_post_write_ownership_mismatch_is_read_only() {
  local dir state fakebin out status
  dir="$TMP_ROOT/ownership-mismatch"
  state="$dir/state"
  mkdir -p "$state"
  fakebin=$(make_fake_ps "$dir")
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "${FM_TEST_CORRUPT_LOCK:-}" ]; then
  printf '%s\n' 999999
  exit 0
fi
exec /bin/cat "$@"
SH
  chmod +x "$fakebin/cat"

  status=0
  out=$(PATH="$fakebin:$PATH" FM_TEST_CORRUPT_LOCK="$state/.lock" \
    FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1) || status=$?

  [ "$status" -ne 0 ] || fail "ownership mismatch reported successful lock acquisition"
  assert_contains "$out" "session lock ownership verification failed" \
    "ownership mismatch did not explain the read-only boundary"
  assert_not_contains "$out" "lock acquired" \
    "ownership mismatch printed a successful acquisition"
  pass "fm-lock: post-write ownership mismatch fails closed"
}

test_success_publishes_verified_owner() {
  local dir state fakebin out status owner
  dir="$TMP_ROOT/success"
  state="$dir/state"
  mkdir -p "$state"
  fakebin=$(make_fake_ps "$dir")

  status=0
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1) || status=$?

  expect_code 0 "$status" "successful acquisition must exit zero"
  assert_contains "$out" "lock acquired: harness pid " \
    "successful acquisition did not report its verified owner"
  owner=${out##*harness pid }
  [ "$(cat "$state/.lock")" = "$owner" ] \
    || fail "successful acquisition did not publish the reported owner"
  pass "fm-lock: successful acquisition preserves its verified-owner behavior"
}

test_live_holder_preserves_contention_behavior() {
  local dir state fakebin out status holder recorded
  dir="$TMP_ROOT/contention"
  state="$dir/state"
  mkdir -p "$state"
  fakebin=$(make_fake_ps "$dir")
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$state/.lock"

  status=0
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1) || status=$?
  recorded=$(cat "$state/.lock")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$status" -ne 0 ] || fail "contention with a live holder reported successful acquisition"
  assert_contains "$out" "another live firstmate session holds the lock (pid $holder)" \
    "contention did not identify the live holder"
  assert_not_contains "$out" "lock acquired" \
    "contention printed a successful acquisition"
  [ "$recorded" = "$holder" ] || fail "contention replaced the live holder's lock"
  pass "fm-lock: live-holder contention behavior is preserved"
}

test_state_creation_failure_is_read_only
test_lock_write_failure_is_read_only
test_post_write_ownership_mismatch_is_read_only
test_success_publishes_verified_owner
test_live_holder_preserves_contention_behavior
