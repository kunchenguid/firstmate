#!/usr/bin/env bash
# Regression for manual arm racing a Claude Stop-hook-owned arm cycle.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-ownership)
WATCH="$ROOT/bin/fm-watch.sh"
ARM="$ROOT/bin/fm-watch-arm.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

test_manual_arm_does_not_attach_to_autoarm_owned_cycle() {
  local dir state fakebin holder watcher arm out i
  dir=$(make_case owner-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 7
    sleep 20
  ' _ "$LIB" "$state/.claude-autoarm.lock" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$state/.claude-autoarm.lock/pid" ]; do sleep 0.05; i=$((i + 1)); done
  assert_present "$state/.claude-autoarm.lock/pid" "fixture autoarm owner lock was not published"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >/dev/null 2>&1 &
  watcher=$!
  i=0
  while [ "$i" -lt 80 ] && [ ! -e "$state/.watch.lock/pid" ]; do sleep 0.05; i=$((i + 1)); done
  assert_present "$state/.watch.lock/pid" "fixture watcher did not become live"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_CONFIRM_TIMEOUT=1 "$ARM" > "$out" 2>&1 &
  arm=$!
  if ! wait_for_exit "$arm" 30; then
    kill "$arm" 2>/dev/null || true
    wait "$arm" 2>/dev/null || true
    kill "$watcher" "$holder" 2>/dev/null || true
    wait "$watcher" "$holder" 2>/dev/null || true
    fail "manual arm attached to the Stop-hook-owned cycle instead of deferring: $(cat "$out")"
  fi
  grep -F 'watcher: delegated to Claude auto-arm owner' "$out" >/dev/null \
    || fail "manual arm did not identify delegated cycle ownership: $(cat "$out")"
  kill -0 "$watcher" 2>/dev/null || fail "ownership reconciliation stopped the live watcher"
  kill "$watcher" "$holder" 2>/dev/null || true
  wait "$watcher" "$holder" 2>/dev/null || true
  pass "manual arm never attaches to a Claude auto-arm-owned watcher cycle"
}

test_manual_arm_does_not_attach_to_autoarm_owned_cycle
