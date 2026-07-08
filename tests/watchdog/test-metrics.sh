#!/usr/bin/env bash
# Behavior tests for observe-only watchdog metric collection.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-metrics-tests)
FIXTURE_DIR="$ROOT/tests/watchdog/fixtures"
CLAUDE_FIXTURE="$FIXTURE_DIR/token-optimizer-checkpoint.json"

test_claude_checkpoint_metrics() {
  local out context expected
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/state" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$FIXTURE_DIR" \
    bash -c '. "$1"; fm_watchdog_collect_metrics claude fixture-session' _ "$ROOT/bin/fm-watchdog-lib.sh")
  jq -e '
    has("harness")
    and has("context_pct")
    and has("five_hr_pct")
    and has("seven_day_pct")
    and has("tool_calls")
    and has("collected_at")
    and has("parser_version")
  ' "$out" >/dev/null || fail "metrics JSON should include every watchdog data key"
  context=$(jq -r '.context_pct' "$out")
  expected=$(jq -r '.fill_pct' "$CLAUDE_FIXTURE")
  [ "$context" = "$expected" ] || fail "context_pct should match fixture fill_pct, got: $context"
  [ "$(jq -r '.harness' "$out")" = claude ] || fail "harness should be claude"
  [ "$(jq -r '.parser_version' "$out")" = 1 ] || fail "parser_version should be 1"
  pass "claude checkpoint metrics are written from a real token-optimizer fixture"
}

test_corrupt_claude_checkpoint_is_loud() {
  local corrupt out err status
  corrupt="$TMP_ROOT/corrupt"
  mkdir -p "$corrupt"
  jq 'del(.fill_pct)' "$CLAUDE_FIXTURE" > "$corrupt/corrupt.json"
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/bad-state" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$corrupt" \
    bash -c '. "$1"; fm_watchdog_collect_metrics claude corrupt-session' _ "$ROOT/bin/fm-watchdog-lib.sh" 2>"$TMP_ROOT/corrupt.err")
  status=$?
  err=$(cat "$TMP_ROOT/corrupt.err")
  expect_code 3 "$status" "corrupt checkpoint should exit with parser mismatch code"
  [ -z "$out" ] || fail "corrupt checkpoint should not print a metrics path"
  assert_contains "$err" "WATCHDOG_PARSER_MISMATCH" "corrupt checkpoint should fail loudly"
  pass "corrupt checkpoint cannot silently produce metrics"
}

test_unknown_harness_is_observe_only_tolerant() {
  local out
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/unknown-state" \
    bash -c '. "$1"; fm_watchdog_collect_metrics mystery unknown-session' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(jq -r '.context_pct' "$out")" = null ] || fail "unknown harness should write null context_pct"
  [ "$(jq -r '.harness' "$out")" = mystery ] || fail "unknown harness name should be preserved"
  pass "unknown harness writes tolerant null metrics"
}

test_threshold_defaults() {
  local out
  out=$(FM_HOME="$TMP_ROOT/no-config-home" bash -c '. "$1"; fm_watchdog_thresholds' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(printf '%s' "$out" | jq -r '.thresholds.compact_at_context_pct')" = 85 ] \
    || fail "default compact threshold should be 85"
  [ "$(printf '%s' "$out" | jq -r '.rotate_to | join(",")')" = "codex,opencode" ] \
    || fail "default rotation should match shipped example"
  pass "watchdog thresholds fall back to shipped defaults"
}

test_threshold_config_override() {
  local config out
  config="$TMP_ROOT/config-override"
  mkdir -p "$config"
  jq '.thresholds.compact_at_context_pct = 81' "$ROOT/docs/examples/watchdog.json" > "$config/watchdog.json"
  out=$(FM_HOME="$TMP_ROOT/ignored-home" FM_CONFIG_OVERRIDE="$config" \
    bash -c '. "$1"; fm_watchdog_thresholds' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(printf '%s' "$out" | jq -r '.thresholds.compact_at_context_pct')" = 81 ] \
    || fail "FM_CONFIG_OVERRIDE watchdog config should be read before FM_HOME/config"
  pass "watchdog thresholds honor FM_CONFIG_OVERRIDE"
}

test_claude_checkpoint_metrics
test_corrupt_claude_checkpoint_is_loud
test_unknown_harness_is_observe_only_tolerant
test_threshold_defaults
test_threshold_config_override

echo "# all watchdog metrics tests passed"
