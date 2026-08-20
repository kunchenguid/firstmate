#!/usr/bin/env bash
# Characterization coverage for the shared git-lock staleness proof.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-lib-tests)
FAKEBIN="$TMP_ROOT/fakebin"
LOCK="$TMP_ROOT/index.lock"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/lsof" <<'SH'
#!/usr/bin/env bash
case "${FM_TEST_LSOF_MODE:-free}" in
  free) exit 1 ;;
  held) printf 'firstmate 1234 cwd DIR 0,1 0 %s\n' "${1:-target}"; exit 0 ;;
  error) printf 'lsof: permission denied\n' >&2; exit 3 ;;
esac
SH
chmod +x "$FAKEBIN/lsof"
PATH="$FAKEBIN:$PATH"
export PATH
FM_TEST_LSOF_MODE=free
export FM_TEST_LSOF_MODE

# shellcheck source=bin/fm-lock-lib.sh disable=SC1091
. "$ROOT/bin/fm-lock-lib.sh"

test_lsof_classification_is_fail_safe() {
  FM_TEST_LSOF_MODE=free
  if fm_lock_lsof_holder "$LOCK"; then
    fail "free lsof result was classified as held"
  else
    [ "$?" -eq 1 ] || fail "free lsof result did not return status 1"
  fi

  FM_TEST_LSOF_MODE=held
  fm_lock_lsof_holder "$LOCK" || fail "held lsof result was not classified as held"

  FM_TEST_LSOF_MODE=error
  if fm_lock_lsof_holder "$LOCK"; then
    fail "lsof error was classified as held"
  else
    [ "$?" -eq 2 ] || fail "lsof error did not return fail-safe status 2"
  fi
  pass "lock-lib: lsof classification distinguishes free, held, and uncertain"
}

test_stale_proof_requires_free_holder_check() {
  : > "$LOCK"
  FM_TEST_LSOF_MODE=free
  fm_lock_is_provably_stale "$LOCK" "$TMP_ROOT" 0 \
    || fail "free lock with age zero was not proven stale"

  FM_TEST_LSOF_MODE=held
  if fm_lock_is_provably_stale "$LOCK" "$TMP_ROOT" 0; then
    fail "live-held lock was incorrectly proven stale"
  fi
  pass "lock-lib: stale proof refuses a lock with a live holder"
}

test_lsof_classification_is_fail_safe
test_stale_proof_requires_free_holder_check
