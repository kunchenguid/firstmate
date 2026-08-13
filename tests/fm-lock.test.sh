#!/usr/bin/env bash
# tests/fm-lock.test.sh - session lock ownership and liveness fallbacks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-tests)

make_fake_ps_denied() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'ps: operation not permitted' >&2
exit 1
SH
  chmod +x "$fakebin/ps"
}

make_fake_ps_parent_missing() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/bin/zsh'; exit 0 ;;
  *"args="*) printf '%s\n' 'zsh'; exit 0 ;;
  *"ppid="*) exit 1 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_codex_thread_fallback_acquires_when_ps_is_denied() {
  local home fakebin out owner
  home="$TMP_ROOT/codex-thread"
  fakebin=$(fm_fakebin "$TMP_ROOT/codex-thread")
  mkdir -p "$home/state"
  make_fake_ps_denied "$fakebin"

  out=$(FM_HOME="$home" CODEX_THREAD_ID=test-thread CODEX_SANDBOX=seatbelt PATH="$fakebin:$PATH" "$LOCK") \
    || fail "fm-lock did not acquire using the hosted Codex thread fallback: $out"
  assert_contains "$out" "lock acquired: harness codex:test-thread" "acquire output did not report the Codex token"

  owner=$(cat "$home/state/.lock")
  [ "$owner" = "codex:test-thread" ] || fail "lock owner was '$owner', expected codex thread token"

  out=$(FM_HOME="$home" CODEX_THREAD_ID=test-thread CODEX_SANDBOX=seatbelt PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by hosted Codex session codex:test-thread" "status did not preserve the current Codex fallback lock"

  pass "fm-lock acquires with the hosted Codex thread fallback when ps is denied"
}

test_codex_thread_fallback_acquires_when_parent_lookup_fails() {
  local home fakebin out owner
  home="$TMP_ROOT/codex-parent-missing"
  fakebin=$(fm_fakebin "$TMP_ROOT/codex-parent-missing")
  mkdir -p "$home/state"
  make_fake_ps_parent_missing "$fakebin"

  out=$(FM_HOME="$home" CODEX_THREAD_ID=test-thread CODEX_SANDBOX=seatbelt PATH="$fakebin:$PATH" "$LOCK") \
    || fail "fm-lock did not acquire using the Codex thread fallback after parent lookup failed: $out"
  assert_contains "$out" "lock acquired: harness codex:test-thread" "acquire output did not report the Codex token"

  owner=$(cat "$home/state/.lock")
  [ "$owner" = "codex:test-thread" ] || fail "lock owner was '$owner', expected codex thread token"

  pass "fm-lock acquires with the hosted Codex thread fallback when parent lookup fails"
}

test_codex_thread_holder_cannot_be_stolen_while_fresh() {
  local home fakebin out owner status
  home="$TMP_ROOT/codex-other-thread-fresh"
  fakebin=$(fm_fakebin "$TMP_ROOT/codex-other-thread-fresh")
  mkdir -p "$home/state"
  make_fake_ps_denied "$fakebin"
  printf '%s\n' codex:other-thread > "$home/state/.lock"

  status=0
  out=$(FM_HOME="$home" CODEX_THREAD_ID=test-thread CODEX_SANDBOX=seatbelt PATH="$fakebin:$PATH" "$LOCK" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "fm-lock allowed a different fresh Codex thread to steal the lock: $out"
  assert_contains "$out" "another live firstmate session holds the lock" "acquire did not report a live lock owner"

  owner=$(cat "$home/state/.lock")
  [ "$owner" = "codex:other-thread" ] || fail "lock owner was overwritten with '$owner'"

  pass "fm-lock preserves a fresh Codex token lock owned by another thread"
}

test_codex_thread_holder_cannot_be_stolen_when_old() {
  local home fakebin out owner status
  home="$TMP_ROOT/codex-other-thread-old"
  fakebin=$(fm_fakebin "$TMP_ROOT/codex-other-thread-old")
  mkdir -p "$home/state"
  make_fake_ps_denied "$fakebin"
  printf '%s\n' codex:other-thread > "$home/state/.lock"

  touch -t 200001010000 "$home/state/.lock" 2>/dev/null || true

  status=0
  out=$(FM_HOME="$home" CODEX_THREAD_ID=test-thread CODEX_SANDBOX=seatbelt PATH="$fakebin:$PATH" "$LOCK" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "fm-lock allowed an old different Codex thread to steal the lock: $out"
  assert_contains "$out" "hosted Codex session codex:other-thread" "acquire did not identify the different Codex owner"

  owner=$(cat "$home/state/.lock")
  [ "$owner" = "codex:other-thread" ] || fail "lock owner was overwritten with '$owner'"

  pass "fm-lock preserves an old Codex token lock owned by another thread"
}

test_codex_ps_denied_preserves_live_holder() {
  local home fakebin out live
  home="$TMP_ROOT/live-holder"
  fakebin=$(fm_fakebin "$TMP_ROOT/live-holder")
  mkdir -p "$home/state"
  make_fake_ps_denied "$fakebin"

  sleep 30 &
  live=$!
  printf '%s\n' "$live" > "$home/state/.lock"

  out=$(FM_HOME="$home" CODEX_THREAD_ID=test-thread CODEX_SANDBOX=seatbelt PATH="$fakebin:$PATH" "$LOCK" status)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  assert_contains "$out" "lock: held by uninspectable live holder pid $live" "ps-denied live holder was misclassified"
  pass "fm-lock preserves a live holder when Codex seatbelt denies process inspection"
}

test_codex_ps_denied_still_reports_dead_holder_stale() {
  local home fakebin out
  home="$TMP_ROOT/dead-holder"
  fakebin=$(fm_fakebin "$TMP_ROOT/dead-holder")
  mkdir -p "$home/state"
  make_fake_ps_denied "$fakebin"
  printf '%s\n' 999999 > "$home/state/.lock"

  out=$(FM_HOME="$home" CODEX_THREAD_ID=test-thread CODEX_SANDBOX=seatbelt PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: stale" "dead holder was not reported stale"

  pass "fm-lock still reports a dead holder stale when ps is denied"
}

test_malformed_trailing_lock_fragment_is_not_an_owner() {
  local home fakebin out
  home="$TMP_ROOT/malformed-trailing-fragment"
  fakebin=$(fm_fakebin "$TMP_ROOT/malformed-trailing-fragment")
  mkdir -p "$home/state"
  make_fake_ps_denied "$fakebin"
  printf 'codex:other-thread\npartial-write' > "$home/state/.lock"

  out=$(FM_HOME="$home" CODEX_THREAD_ID=test-thread CODEX_SANDBOX=seatbelt PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: stale" \
    "a malformed trailing fragment was accepted as a hosted Codex lock owner"

  pass "fm-lock rejects a lock file with a malformed trailing fragment"
}

test_codex_thread_fallback_acquires_when_ps_is_denied
test_codex_thread_fallback_acquires_when_parent_lookup_fails
test_codex_thread_holder_cannot_be_stolen_while_fresh
test_codex_thread_holder_cannot_be_stolen_when_old
test_codex_ps_denied_preserves_live_holder
test_codex_ps_denied_still_reports_dead_holder_stale
test_malformed_trailing_lock_fragment_is_not_an_owner
