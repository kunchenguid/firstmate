#!/usr/bin/env bash
# Watcher cold-start ordering: the arm must confirm a real singleton holder
# before a slow PR-check preflight can consume its default ten-second budget.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-startup-tests)

make_startup_fixture() {  # <name>
  local name=$1 dir
  dir=$(make_case "$name")
  mkdir -p "$dir/home/state"
  cp -R "$ROOT/bin" "$dir/bin"
  printf '%s\n' "$dir"
}

wait_for_started_arm() {  # <arm-pid> <arm-output>
  local arm_pid=$1 armout=$2 i=0
  while [ "$i" -lt 60 ]; do
    grep -q '^watcher: started pid=' "$armout" 2>/dev/null && return 0
    is_live_non_zombie "$arm_pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_slow_preflight_starts_after_confirmable_heartbeat() {
  local dir state fakebin arm armout migration watcher_pid arm_pid started_at elapsed expected_watch
  dir=$(make_startup_fixture startup-after-heartbeat)
  state="$dir/home/state"
  fakebin="$dir/fakebin"
  arm="$dir/bin/fm-watch-arm.sh"
  armout="$dir/arm.out"
  migration="$dir/bin/fm-pr-check-migrate.sh"
  expected_watch=$(cd "$dir/bin" && pwd)/fm-watch.sh
  cat > "$migration" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/state/migration-started"
sleep 12
SH
  chmod +x "$migration"

  started_at=$(date +%s)
  env -u FM_ARM_CONFIRM_TIMEOUT PATH="$fakebin:$PATH" FM_HOME="$dir/home" \
    FM_POLL=60 "$arm" > "$armout" &
  arm_pid=$!

  i=0
  while [ "$i" -lt 60 ] && [ ! -e "$state/migration-started" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/migration-started" ] || {
    wait "$arm_pid" 2>/dev/null || true
    fail "slow preflight did not start: $(cat "$armout")"
  }
  wait_for_started_arm "$arm_pid" "$armout" || {
    wait "$arm_pid" 2>/dev/null || true
    fail "default-budget arm did not confirm before slow preflight completed: $(cat "$armout")"
  }
  elapsed=$(( $(date +%s) - started_at ))
  [ "$elapsed" -lt 10 ] || fail "arm confirmation took ${elapsed}s despite a held lock and first heartbeat"

  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher_pid" ] || fail "confirmed watcher did not publish a lock pid"
  [ "$(cat "$state/.watch.lock/fm-home" 2>/dev/null || true)" = "$dir/home" ] \
    || fail "confirmed watcher did not bind its lock to the fixture home"
  [ "$(cat "$state/.watch.lock/watcher-path" 2>/dev/null || true)" = "$expected_watch" ] \
    || fail "confirmed watcher path was $(cat "$state/.watch.lock/watcher-path" 2>/dev/null || true), not $expected_watch"
  [ -e "$state/.last-watcher-beat" ] || fail "slow preflight started without the first watcher heartbeat"
  is_live_non_zombie "$watcher_pid" || fail "arm confirmed a non-live watcher pid $watcher_pid"

  # Finish this fixture's one watcher exactly by its lock-owned pid; no broad
  # process matching is acceptable in this test or production code.
  kill "$watcher_pid" 2>/dev/null || true
  wait_for_exit "$arm_pid" 120 >/dev/null 2>&1 || true
  pass "slow preflight follows a lock-held, loop-entered heartbeat under the default arm budget"
}

test_arm_rejects_a_live_lock_holder_without_a_heartbeat() {
  local dir state fakebin arm armout holder pid rc
  dir=$(make_startup_fixture no-fabricated-beat)
  state="$dir/home/state"
  fakebin="$dir/fakebin"
  arm="$dir/bin/fm-watch-arm.sh"
  armout="$dir/arm.out"
  cat > "$dir/bin/fm-pr-check-migrate.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/state/migration-ran"
SH
  chmod +x "$dir/bin/fm-pr-check-migrate.sh"

  # A live foreign pid in the lock is the exact reason a watcher cannot acquire
  # this home. It intentionally carries no watcher identity or beat.
  sleep 30 &
  holder=$!
  mkdir "$state/.watch.lock" || fail "negative-control lock directory could not be created"
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  touch "$state/foreign-lock-ready"
  pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  is_live_non_zombie "$pid" || fail "negative-control lock pid did not name a live holder"

  set +e
  env FM_ARM_CONFIRM_TIMEOUT=1 PATH="$fakebin:$PATH" FM_HOME="$dir/home" \
    FM_POLL=60 "$arm" > "$armout" 2>&1
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -ne 0 ] || fail "arm accepted a live foreign lock holder without a heartbeat"
  grep -q 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "negative control did not fail at the arm honesty gate: $(cat "$armout")"
  [ ! -e "$state/.last-watcher-beat" ] || fail "negative control fabricated a watcher heartbeat"
  [ ! -e "$state/migration-ran" ] || fail "negative control ran migration before acquiring the watcher lock"
  pass "arm rejects a live lock holder without a heartbeat instead of accepting fabricated liveness"
}

test_watcher_lock_held_mode_requires_the_parent_singleton() {
  local dir state out rc holder identity expected_watch
  dir=$(make_startup_fixture watcher-lock-held-guard)
  state="$dir/home/state"
  expected_watch=$(cd "$dir/bin" && pwd)/fm-watch.sh
  sleep 30 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_pid_identity "$2"
  ' _ "$ROOT" "$holder")
  mkdir "$state/.watch.lock" || fail "watcher-lock-held guard fixture could not create its lock"
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$dir/home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$expected_watch" > "$state/.watch.lock/watcher-path"
  set +e
  FM_HOME="$dir/home" "$dir/bin/fm-pr-check-migrate.sh" --checks-safe --watcher-lock-held="$holder" > "$dir/out" 2>&1
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(cat "$dir/out")
  [ "$rc" -ne 0 ] || fail "watcher-lock-held migration mode accepted a non-child of the singleton"
  [ "$out" = 'PR_CHECK_MIGRATION: watcher-lock-held requires the current watcher singleton; refusing to scan state checks' ] \
    || fail "watcher-lock-held guard fired for the wrong reason: $out"
  pass "watcher-lock-held migration mode refuses a caller that is not the watcher singleton"
}

test_slow_preflight_starts_after_confirmable_heartbeat
test_arm_rejects_a_live_lock_holder_without_a_heartbeat
test_watcher_lock_held_mode_requires_the_parent_singleton
