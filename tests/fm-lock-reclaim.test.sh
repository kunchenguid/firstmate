#!/usr/bin/env bash
# tests/fm-lock-reclaim.test.sh - the symlink claim lock in bin/fm-wake-lib.sh
# acquires, is reclaimed from a dead holder, is refused while a live holder has
# it, and releases without leftovers, on whatever host runs the suite.
#
# On Git Bash a default `ln -s` deep-copies instead of linking, which left a
# lock that could never be reclaimed and nested a new .steal directory on every
# attempt, so this is the case that proves native symlinks are requested there.
# shellcheck disable=SC2016 # single quotes are deliberate: $STATE expands inside the child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-reclaim)

lock_eval() {  # <state> <expression>
  STATE=$1 FM_ROOT="$ROOT" bash -c ". \"\$0/bin/fm-wake-lib.sh\"; $2" "$ROOT"
}

test_dead_holder_is_reclaimed_and_live_holder_respected() {
  local state out
  state="$TMP_ROOT/state"
  mkdir -p "$state"

  lock_eval "$state" 'fm_lock_try_acquire "$STATE/x.lock"' \
    || fail "a free lock was not acquired"
  [ -L "$state/x.lock" ] || fail "the acquired lock is not a symlink to its owner"

  out=$(lock_eval "$state" '
    fm_lock_try_acquire "$STATE/x.lock" || exit 1
    [ -n "$FM_LOCK_RECOVERED_PID" ] || exit 2
    bash -c ". \"$0/bin/fm-wake-lib.sh\"; fm_lock_try_acquire \"\$STATE/x.lock\"" "$0" && exit 3
    fm_lock_release "$STATE/x.lock" || exit 4
  ') ; case $? in
    0) ;;
    1) fail "a lock whose holder exited was not reclaimed" ;;
    2) fail "the reclaim did not report the dead holder it recovered" ;;
    3) fail "a live holder's lock was taken by another process" ;;
    *) fail "the reclaimed lock was not released: $out" ;;
  esac
  out=$(find "$state" -mindepth 1 -maxdepth 1)
  [ -z "$out" ] || fail "lock artifacts were left behind: $out"
  pass "claim lock: a dead holder is reclaimed, a live holder is respected, and release leaves nothing"
}

test_dead_holder_is_reclaimed_and_live_holder_respected
