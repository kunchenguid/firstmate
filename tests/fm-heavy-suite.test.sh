#!/usr/bin/env bash
# Behavior tests for bin/fm-heavy-suite.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-heavy-suite)
WRAPPER="$ROOT/bin/fm-heavy-suite.sh"
LOCK_TMP="$TMP_ROOT/lock-tmp"
REAL_ROOT="$TMP_ROOT/real-root"
ALIAS_ROOT="$TMP_ROOT/alias-root"
TMP_A="$TMP_ROOT/env-a"
TMP_B="$TMP_ROOT/env-b"
mkdir -p "$LOCK_TMP" "$REAL_ROOT" "$TMP_A" "$TMP_B"
ln -s "$REAL_ROOT" "$ALIAS_ROOT"

cleanup() {
  [ -z "${holder_pid:-}" ] || kill "$holder_pid" 2>/dev/null || true
  [ -z "${contender_pid:-}" ] || kill "$contender_pid" 2>/dev/null || true
}
trap cleanup EXIT

# assert_serialized <desc> <holder env...> -- <contender env...>
#
# Starts a holder that touches a start marker and spins until RELEASE_HOLDER
# exists, then a contender that prints suite-ran once it actually runs.
# Serialization is proven by observable ordering: the contender must report
# its wait, must not have run its suite while the holder is active, and must
# run successfully after the holder exits. The contender never asserts on the
# lock path, only on the order of observable events.
assert_serialized() {
  local desc=$1
  shift
  local holder_env=() contender_env=()
  while [ "$1" != "--" ]; do
    holder_env+=("$1")
    shift
  done
  shift
  while [ "$#" -gt 0 ]; do
    contender_env+=("$1")
    shift
  done

  local holder_started="$TMP_ROOT/holder-started" release_holder="$TMP_ROOT/release-holder"
  local holder_out="$TMP_ROOT/holder.out" contender_out="$TMP_ROOT/contender.out"
  rm -f "$holder_started" "$release_holder" "$holder_out" "$contender_out"

  # shellcheck disable=SC2016 # The child shell receives positional paths.
  env "${holder_env[@]}" "$WRAPPER" -- sh -c '
    touch "$1"
    while [ ! -f "$2" ]; do sleep 0.02; done
  ' sh "$holder_started" "$release_holder" >"$holder_out" 2>&1 &
  holder_pid=$!
  for _ in $(seq 1 100); do
    [ -f "$holder_started" ] && break
    sleep 0.02
  done
  [ -f "$holder_started" ] || fail "$desc: heavy-suite lock holder did not start"

  env "${contender_env[@]}" "$WRAPPER" -- sh -c 'printf "suite-ran\n"' >"$contender_out" 2>&1 &
  contender_pid=$!
  for _ in $(seq 1 100); do
    grep -q "another heavy frontend suite is running; waiting" "$contender_out" 2>/dev/null && break
    sleep 0.02
  done
  assert_grep "another heavy frontend suite is running; waiting for it to finish (this is not a test failure)" "$contender_out" \
    "$desc: contending heavy suite did not explain that it was waiting rather than failing"
  if grep -q "suite-ran" "$contender_out" 2>/dev/null; then
    fail "$desc: contender ran its suite while the holder was still active"
  fi

  touch "$release_holder"
  wait "$holder_pid" || {
    holder_pid=
    fail "$desc: heavy-suite lock holder failed"
  }
  holder_pid=
  wait "$contender_pid" || {
    contender_pid=
    fail "$desc: waiting heavy suite did not run successfully after lock release"
  }
  contender_pid=
  assert_grep "lock acquired; starting the waiting suite" "$contender_out" \
    "$desc: waiting heavy suite did not report acquiring the lock"
  assert_grep "suite-ran" "$contender_out" "$desc: waiting heavy suite never ran after lock release"
  pass "$desc"
}

# Every caller runs under FM_HEAVY_SUITE_LOCK_ROOT so the suite never touches
# the machine-wide production lock, whatever TMPDIR says.
assert_serialized \
  "callers with different TMPDIR values contend on one lock" \
  TMPDIR="$TMP_A" FM_HEAVY_SUITE_LOCK_ROOT="$LOCK_TMP" -- \
  TMPDIR="$TMP_B" FM_HEAVY_SUITE_LOCK_ROOT="$LOCK_TMP"

assert_serialized \
  "a caller with TMPDIR unset contends with a caller with TMPDIR set" \
  -u TMPDIR FM_HEAVY_SUITE_LOCK_ROOT="$LOCK_TMP" -- \
  TMPDIR="$TMP_B" FM_HEAVY_SUITE_LOCK_ROOT="$LOCK_TMP"

assert_serialized \
  "two spellings of one lock directory contend on one lock" \
  TMPDIR="$TMP_A" FM_HEAVY_SUITE_LOCK_ROOT="$ALIAS_ROOT" -- \
  TMPDIR="$TMP_B" FM_HEAVY_SUITE_LOCK_ROOT="$REAL_ROOT"
