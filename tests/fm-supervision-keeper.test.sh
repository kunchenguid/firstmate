#!/usr/bin/env bash
# Regression coverage for the durable Firstmate supervision keeper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

KEEPER="$ROOT/bin/fm-supervision-keeper.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-keeper)
trap 'rm -rf "$TMP_ROOT"' EXIT

test_restart_predicate_requires_identity_and_freshness() {
  local state="$TMP_ROOT/state"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$TMP_ROOT" > "$state/.watch.lock/fm-home"
  # A missing identity is never treated as healthy, even if the pid is live.
  if FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_keeper_watcher_healthy' _ "$KEEPER"; then
    fail "keeper accepted a watcher lock without a process identity"
  fi
  pass "keeper requires watcher identity before treating it as healthy"
}

test_backoff_is_bounded() {
  local out
  out=$(FM_KEEPER_MAX_BACKOFF=7 bash -c '. "$1"; fm_keeper_backoff 1; fm_keeper_backoff 4; fm_keeper_backoff 6' _ "$KEEPER")
  expect_code $'2\n7\n7' "$out" "keeper backoff is exponential and capped"
}

test_keeper_restarts_a_crashing_child() {
  local state="$TMP_ROOT/restart-state" fake="$TMP_ROOT/fake-watch.sh" log="$TMP_ROOT/keeper.log" out
  mkdir -p "$state"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
echo child-started >> "$FM_KEEPER_TEST_LOG"
exit 42
SH
  chmod +x "$fake"
  FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" \
    FM_KEEPER_WATCH_COMMAND="$fake" FM_KEEPER_TEST_LOG="$log" \
    FM_KEEPER_MAX_RESTARTS=2 FM_KEEPER_POLL=0 FM_KEEPER_TEST_MODE=1 \
    "$KEEPER" --once >/dev/null 2>&1
  out=$(cat "$state/.supervision-keeper.log")
  assert_contains "$out" "restarting watcher" "keeper reports the crashed child and restart decision"
  expect_code "3" "$(wc -l < "$log" | tr -d ' ')" "keeper performs the configured bounded restart attempts"
}

test_keeper_restarts_a_live_but_unhealthy_watcher() {
  local state="$TMP_ROOT/unhealthy-state" fake="$TMP_ROOT/stuck-watch.sh" log="$TMP_ROOT/unhealthy.log" out rc
  mkdir -p "$state"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
echo child-started >> "$FM_KEEPER_TEST_LOG"
trap 'echo child-stopped >> "$FM_KEEPER_TEST_LOG"; exit 0' TERM INT
while :; do sleep 1; done
SH
  chmod +x "$fake"

  set +e
  out=$(timeout 15 env \
    FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" \
    FM_KEEPER_WATCH_COMMAND="$fake" FM_KEEPER_TEST_LOG="$log" \
    FM_KEEPER_MAX_RESTARTS=1 FM_KEEPER_POLL=0 \
    FM_KEEPER_STARTUP_GRACE=0 FM_KEEPER_TEST_MODE=1 \
    "$KEEPER" --once 2>&1)
  rc=$?
  set -e
  expect_code "0" "$rc" "keeper terminates and reaps a live watcher that never becomes healthy"
  assert_grep "child-stopped" "$log" "keeper stops the unhealthy child it owns"
  out=$(cat "$state/.supervision-keeper.log")
  assert_contains "$out" "watcher unhealthy; restarting owned child" "keeper records the unhealthy-child restart decision"
  pass "keeper restarts a live watcher whose lock/beacon never becomes healthy"
}

test_keeper_circuits_on_heartbeat_write_failure() {
  local state="$TMP_ROOT/heartbeat-failure-state" fake="$TMP_ROOT/heartbeat-failure-watch.sh" out rc
  mkdir -p "$state"
  # A directory at the heartbeat path makes the real heartbeat write fail with
  # the same filesystem boundary that produced the incident's ENOSPC/EMFILE.
  mkdir -p "$state/.supervision-keeper-beat"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake"

  set +e
  out=$(FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" \
    FM_KEEPER_WATCH_COMMAND="$fake" FM_KEEPER_MAX_RESTARTS=1 \
    FM_KEEPER_MAX_RESOURCE_FAILURES=2 FM_KEEPER_RESOURCE_COOLDOWN=0 \
    FM_KEEPER_POLL=0 FM_KEEPER_TEST_MODE=1 \
    "$KEEPER" --once 2>&1)
  rc=$?
  set -e
  expect_code "75" "$rc" "keeper exits with a resource-specific status after repeated heartbeat failures"
  assert_contains "$(cat "$state/.supervision-keeper.log")" \
    "heartbeat write failed" "keeper records the heartbeat resource failure"
  pass "keeper circuits instead of retrying forever when its heartbeat cannot be written"
}

test_keeper_circuits_on_watcher_allocation_failure() {
  local state="$TMP_ROOT/allocation-failure-state" rc
  mkdir -p "$state"

  set +e
  FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" \
    FM_KEEPER_TEST_FAIL_WATCHER_ALLOCATION=1 FM_KEEPER_MAX_RESOURCE_FAILURES=2 \
    FM_KEEPER_RESOURCE_COOLDOWN=0 FM_KEEPER_POLL=0 FM_KEEPER_TEST_MODE=1 \
    "$KEEPER" --once >/dev/null 2>&1
  rc=$?
  set -e
  expect_code "75" "$rc" "keeper exits with a resource-specific status after watcher allocation failures"
  assert_contains "$(cat "$state/.supervision-keeper.log")" \
    "watcher allocation failed" "keeper records watcher allocation pressure"
  pass "keeper circuits instead of retrying forever when watcher allocation fails"
}

test_restart_predicate_requires_identity_and_freshness
test_backoff_is_bounded
test_keeper_restarts_a_crashing_child
test_keeper_restarts_a_live_but_unhealthy_watcher
test_keeper_circuits_on_heartbeat_write_failure
test_keeper_circuits_on_watcher_allocation_failure

echo "all supervision keeper tests passed"
