#!/usr/bin/env bash
# Behavior tests for optional host-pressure alerting/backpressure substrate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRESSURE="$ROOT/bin/fm-host-pressure.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-pressure)

write_pressure_config() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

test_absent_config_is_feature_off() {
  local home state out status
  home="$TMP_ROOT/off/home"
  state="$home/state"
  mkdir -p "$state"

  out=$("$PRESSURE" check --config "$home/config/capacity-failover" --home "$home" --state "$state")
  status=$?

  expect_code 0 "$status" "absent capacity-failover config should be off"
  assert_contains "$out" "state=off" "absent config should report feature off"
  assert_contains "$out" "reason=host_pressure_not_enabled" "off state should explain why"
  pass "host-pressure check is feature-off when config/capacity-failover is absent"
}

test_warning_reports_but_allows_spawn() {
  local home state cfg out status
  home="$TMP_ROOT/warn/home"
  state="$home/state"
  cfg="$home/config/capacity-failover"
  mkdir -p "$state"
  write_pressure_config "$cfg" \
    "host-pressure=on" \
    "min_memory_available_mb=1000" \
    "warn_memory_available_mb=2000" \
    "min_disk_available_mb=1000" \
    "warn_disk_available_mb=2000" \
    "max_running_tasks=10"

  out=$(FM_PRESSURE_MEMORY_AVAILABLE_MB=1500 FM_PRESSURE_DISK_AVAILABLE_MB=2500 FM_PRESSURE_RUNNING_TASKS=1 \
    "$PRESSURE" check --config "$cfg" --home "$home" --state "$state")
  status=$?

  expect_code 0 "$status" "warning pressure should allow the caller to continue"
  assert_contains "$out" "state=warn" "memory below warn threshold should warn"
  assert_contains "$out" "reason=memory_available_below_warn" "warning reason should cite memory"
  pass "host-pressure warning reports pressure without applying backpressure"
}

test_critical_pressure_returns_nonzero_and_reports_cleanup_candidates() {
  local home state cfg out status
  home="$TMP_ROOT/critical/home"
  state="$home/state"
  cfg="$home/config/capacity-failover"
  mkdir -p "$state"
  write_pressure_config "$cfg" \
    "host-pressure=on" \
    "min_memory_available_mb=1000" \
    "warn_memory_available_mb=2000" \
    "disk_floor_mb=1000" \
    "disk_clear_mb=2000" \
    "max_running_tasks=2"

  out=$(FM_PRESSURE_MEMORY_AVAILABLE_MB=500 FM_PRESSURE_DISK_AVAILABLE_MB=700 FM_PRESSURE_RUNNING_TASKS=2 \
    "$PRESSURE" check --config "$cfg" --home "$home" --state "$state" 2>&1)
  status=$?

  expect_code 1 "$status" "critical pressure should return non-zero"
  assert_contains "$out" "state=critical" "critical pressure should report critical state"
  assert_contains "$out" "memory_available_below_min" "critical reason should include memory"
  assert_contains "$out" "disk_floor_below_min" "critical reason should include disk floor"
  assert_contains "$out" "running_tasks_at_or_above_max" "critical reason should include concurrency"
  assert_contains "$out" "transient_candidate=" "critical disk pressure should report cleanup candidates"
  pass "host-pressure critical state applies bounded backpressure evidence"
}

test_active_task_count_reads_meta_records() {
  local home state cfg out status
  home="$TMP_ROOT/count/home"
  state="$home/state"
  cfg="$home/config/capacity-failover"
  mkdir -p "$state"
  write_pressure_config "$cfg" \
    "host-pressure=on" \
    "min_memory_available_mb=1000" \
    "warn_memory_available_mb=2000" \
    "min_disk_available_mb=1000" \
    "warn_disk_available_mb=2000" \
    "max_running_tasks=3"
  fm_write_meta "$state/a.meta" "window=firstmate:fm-a" "kind=ship"
  fm_write_meta "$state/b.meta" "window=firstmate:fm-b" "kind=scout"
  fm_write_meta "$state/c.meta" "kind=ship"

  out=$(FM_PRESSURE_MEMORY_AVAILABLE_MB=5000 FM_PRESSURE_DISK_AVAILABLE_MB=5000 \
    "$PRESSURE" check --config "$cfg" --home "$home" --state "$state")
  status=$?

  expect_code 0 "$status" "active count below max should pass"
  assert_contains "$out" "running_tasks=2" "running task count should use meta records with window="
  pass "host-pressure concurrency count is derived from firstmate task ownership meta"
}

test_disk_floor_gate_blocks_heavy_test_launch() {
  local home state cfg out status
  home="$TMP_ROOT/disk-gate/home"
  state="$home/state"
  cfg="$home/config/capacity-failover"
  mkdir -p "$state"
  write_pressure_config "$cfg" \
    "host-pressure=on" \
    "disk_floor_mb=9000" \
    "disk_clear_mb=12000" \
    "max_running_tasks=99"

  out=$(FM_PRESSURE_MEMORY_AVAILABLE_MB=5000 FM_PRESSURE_DISK_AVAILABLE_MB=8200 FM_PRESSURE_RUNNING_TASKS=0 \
    "$PRESSURE" gate --kind test --config "$cfg" --home "$home" --state "$state" 2>&1)
  status=$?

  expect_code 1 "$status" "disk below hard floor should block heavy test launches"
  assert_contains "$out" "gate_kind=test" "gate output should record the gated launch kind"
  assert_contains "$out" "disk_floor_below_min" "disk floor should be the blocking reason"
  assert_contains "$out" "disk_available_mb=8200" "gate should include exact available disk evidence"
  pass "hard disk floor blocks heavy test launches below threshold"
}

test_disk_floor_hysteresis_holds_until_clear_threshold() {
  local home state cfg out status
  home="$TMP_ROOT/hysteresis/home"
  state="$home/state"
  cfg="$home/config/capacity-failover"
  mkdir -p "$state"
  write_pressure_config "$cfg" \
    "host-pressure=on" \
    "disk_floor_mb=9000" \
    "disk_clear_mb=12000" \
    "max_running_tasks=99"

  out=$(FM_PRESSURE_MEMORY_AVAILABLE_MB=5000 FM_PRESSURE_DISK_AVAILABLE_MB=8500 FM_PRESSURE_RUNNING_TASKS=0 \
    "$PRESSURE" check --config "$cfg" --home "$home" --state "$state" 2>&1)
  status=$?
  expect_code 1 "$status" "below floor should enter pressure"
  assert_contains "$out" "disk_hysteresis=entered" "first below-floor check should enter hysteresis"

  out=$(FM_PRESSURE_MEMORY_AVAILABLE_MB=5000 FM_PRESSURE_DISK_AVAILABLE_MB=10000 FM_PRESSURE_RUNNING_TASKS=0 \
    "$PRESSURE" check --config "$cfg" --home "$home" --state "$state" 2>&1)
  status=$?
  expect_code 1 "$status" "between floor and clear should stay blocked"
  assert_contains "$out" "disk_hysteresis=held" "disk floor should not flap clear below disk_clear_mb"

  out=$(FM_PRESSURE_MEMORY_AVAILABLE_MB=5000 FM_PRESSURE_DISK_AVAILABLE_MB=13000 FM_PRESSURE_RUNNING_TASKS=0 \
    "$PRESSURE" check --config "$cfg" --home "$home" --state "$state")
  status=$?
  expect_code 0 "$status" "above clear threshold should release pressure"
  assert_contains "$out" "disk_hysteresis=inactive" "disk floor should clear only above disk_clear_mb"
  pass "disk floor hysteresis prevents repeated enter/exit flapping"
}

test_periodic_disk_alert_is_bounded_by_cooldown() {
  local home state cfg out status
  home="$TMP_ROOT/alert/home"
  state="$home/state"
  cfg="$home/config/capacity-failover"
  mkdir -p "$state"
  write_pressure_config "$cfg" \
    "host-pressure=on" \
    "disk_floor_mb=9000" \
    "disk_clear_mb=12000" \
    "disk_alert_cooldown_secs=300" \
    "max_running_tasks=99"

  out=$(FM_PRESSURE_NOW_EPOCH=1000 FM_PRESSURE_MEMORY_AVAILABLE_MB=5000 FM_PRESSURE_DISK_AVAILABLE_MB=8200 FM_PRESSURE_RUNNING_TASKS=0 \
    "$PRESSURE" periodic-alert --config "$cfg" --home "$home" --state "$state")
  status=$?
  expect_code 0 "$status" "first disk alert should return zero after emitting"
  assert_contains "$out" "alert=disk_pressure" "periodic alert should emit bounded alert signal"
  assert_contains "$out" "disk_available_mb=8200" "periodic alert should include exact disk evidence"

  out=$(FM_PRESSURE_NOW_EPOCH=1100 FM_PRESSURE_MEMORY_AVAILABLE_MB=5000 FM_PRESSURE_DISK_AVAILABLE_MB=8100 FM_PRESSURE_RUNNING_TASKS=0 \
    "$PRESSURE" periodic-alert --config "$cfg" --home "$home" --state "$state")
  status=$?
  expect_code 0 "$status" "cooldown-suppressed disk alert should still return zero"
  [ -z "$out" ] || fail "disk alert should be suppressed during cooldown: $out"
  pass "periodic disk-pressure alert emits bounded signals with cooldown"
}

test_shed_classifier_allows_only_restartable_compute() {
  local out
  out=$("$PRESSURE" classify-shed --command "bash tests/fm-capacity.test.sh")
  assert_contains "$out" "eligible=restartable_compute" "test process should be eligible for safe shedding"
  assert_contains "$out" "reason=validation_or_test_process" "restartable compute should name its class"

  out=$("$PRESSURE" classify-shed --command "codex --dangerously-bypass-approvals-and-sandbox")
  assert_contains "$out" "eligible=no" "agent pane processes must not be shed by pressure helper"
  assert_contains "$out" "not_known_restartable_compute" "non-restartable refusal should be explicit"
  pass "pressure shedding only classifies restartable validation compute as eligible"
}

test_absent_config_is_feature_off
test_warning_reports_but_allows_spawn
test_critical_pressure_returns_nonzero_and_reports_cleanup_candidates
test_active_task_count_reads_meta_records
test_disk_floor_gate_blocks_heavy_test_launch
test_disk_floor_hysteresis_holds_until_clear_threshold
test_periodic_disk_alert_is_bounded_by_cooldown
test_shed_classifier_allows_only_restartable_compute

echo "# all fm-host-pressure tests passed"
