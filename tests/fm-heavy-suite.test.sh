#!/usr/bin/env bash
# Behavior tests for bin/fm-heavy-suite.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-heavy-suite)
WRAPPER="$ROOT/bin/fm-heavy-suite.sh"
LOCK_TMP="$TMP_ROOT/lock-tmp"
HOLDER_STARTED="$TMP_ROOT/holder-started"
RELEASE_HOLDER="$TMP_ROOT/release-holder"
HOLDER_OUT="$TMP_ROOT/holder.out"
CONTENDER_OUT="$TMP_ROOT/contender.out"
mkdir -p "$LOCK_TMP"

cleanup() {
  [ -z "${holder_pid:-}" ] || kill "$holder_pid" 2>/dev/null || true
  [ -z "${contender_pid:-}" ] || kill "$contender_pid" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck disable=SC2016 # The child shell receives positional paths.
TMPDIR="$LOCK_TMP" "$WRAPPER" -- sh -c '
  touch "$1"
  while [ ! -f "$2" ]; do sleep 0.02; done
' sh "$HOLDER_STARTED" "$RELEASE_HOLDER" >"$HOLDER_OUT" 2>&1 &
holder_pid=$!

for _ in $(seq 1 100); do
  [ -f "$HOLDER_STARTED" ] && break
  sleep 0.02
done
[ -f "$HOLDER_STARTED" ] || fail "heavy-suite lock holder did not start"

TMPDIR="$LOCK_TMP" "$WRAPPER" -- sh -c 'printf "suite-ran\n"' >"$CONTENDER_OUT" 2>&1 &
contender_pid=$!
for _ in $(seq 1 100); do
  grep -q "another heavy frontend suite is running; waiting" "$CONTENDER_OUT" 2>/dev/null && break
  sleep 0.02
done
assert_grep "another heavy frontend suite is running; waiting" "$CONTENDER_OUT" \
  "contending heavy suite did not explain that it was waiting rather than failing"

touch "$RELEASE_HOLDER"
wait "$holder_pid" || fail "heavy-suite lock holder failed"
holder_pid=
wait "$contender_pid" || fail "waiting heavy suite did not run successfully after lock release"
contender_pid=
assert_grep "suite-ran" "$CONTENDER_OUT" "waiting heavy suite never ran after lock release"
pass "heavy frontend suites serialize across worktrees and contention is a non-failure wait"
