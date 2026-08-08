#!/usr/bin/env bash
# Public-interface tests for the private fleet sentinel: it consumes the
# shared capacity object and owns only cadence, candidate query, logging, and
# notification policy; it never counts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-refill-sentinel)
export FM_REFILL_SENTINEL_LOG="$TMP_ROOT/sentinel.log"
# Hermetic candidate query: the sentinel must never touch the real
# decision-os clone (its br reads must not auto-flush the tracked export).
export FM_REFILL_PROJECT="$TMP_ROOT/project"
mkdir -p "$FM_REFILL_PROJECT"

# Real fm-fleet-capacity.v1 fixtures consumed by the sentinel tests. safe.json
# is a complete observation at the refill target (six working ships, no
# reconciliation, no timeout), so the sentinel stays silent; alert.json
# carries a legacy meta row that requires reconciliation, so the projection is
# not refill-safe and the sentinel must notify.
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

export FM_CAPACITY_READ_TIMEOUT_SECS=2
export FM_CAPACITY_TOTAL_TIMEOUT_SECS=10
export FM_CREW_STATE_BIN="$TMP_ROOT/fm-crew-state.sh"
SAFE_STATE="$TMP_ROOT/safe-state"
ALERT_STATE="$TMP_ROOT/alert-state"
mkdir -p "$SAFE_STATE" "$ALERT_STATE" "$TMP_ROOT/safe-data" "$TMP_ROOT/alert-data"

cat > "$TMP_ROOT/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-crew-state.v1","id":"fixture","state":"working","source":"run-step","detail":"busy"}'
SH
chmod +x "$TMP_ROOT/fm-crew-state.sh"

build_safe_projection() {
  local i aid
  for i in 1 2 3 4 5 6; do
    aid=$(FM_STATE_OVERRIDE="$SAFE_STATE" FM_DATA_OVERRIDE="$TMP_ROOT/safe-data" \
      fm_attempt_alloc pi "safe-$i" holu) || fail "safe fixture alloc $i"
    FM_STATE_OVERRIDE="$SAFE_STATE" FM_DATA_OVERRIDE="$TMP_ROOT/safe-data" \
      fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-x"}' \
      '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' \
      || fail "safe fixture freeze $i"
    FM_STATE_OVERRIDE="$SAFE_STATE" FM_DATA_OVERRIDE="$TMP_ROOT/safe-data" \
      fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w1"}' || fail "safe fixture launch $i"
    printf 'kind=ship\nmode=direct-PR\nattempt=%s\n' "$aid" > "$SAFE_STATE/safe-$i.meta"
  done
  FM_STATE_OVERRIDE="$SAFE_STATE" FM_DATA_OVERRIDE="$TMP_ROOT/safe-data" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json > "$TMP_ROOT/safe.json" 2>/dev/null \
    || fail "safe projection generation"
}

build_alert_projection() {
  printf 'kind=ship\nmode=direct-PR\n' > "$ALERT_STATE/legacy-1.meta"
  FM_STATE_OVERRIDE="$ALERT_STATE" FM_DATA_OVERRIDE="$TMP_ROOT/alert-data" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json > "$TMP_ROOT/alert.json" 2>/dev/null \
    || fail "alert projection generation"
}

build_safe_projection
build_alert_projection
jq -e '.aggregate.refill_safe == true' "$TMP_ROOT/safe.json" >/dev/null \
  || fail "safe fixture is not refill-safe"
jq -e '.aggregate.refill_safe == false and .aggregate.reconciliation_required == true' \
  "$TMP_ROOT/alert.json" >/dev/null \
  || fail "alert fixture does not require reconciliation"

test_sentinel_is_silent_when_refill_is_safe() {
  local out rc
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "safe sentinel should exit 0"
  [ -z "$out" ] || fail "safe sentinel printed: $out"
  pass "sentinel stays silent when the projection is refill-safe"
}

test_sentinel_notifies_on_reconciliation_or_alert() {
  local out rc
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/alert.json" \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "alerting sentinel should exit 1"
  assert_contains "$out" "REFILL-ALERT" "alert line missing"
  pass "sentinel emits one alert line when reconciliation or alert-only applies"
}

test_sentinel_never_counts() {
  local out
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" FM_REFILL_SENTINEL_VERBOSE=1 \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_not_contains "$out" "productive_count" "sentinel recomputed capacity"
  pass "sentinel never classifies or recounts; it only consumes the object"
}

# --- config/refill-sentinel cadence schema (Task 14) ------------------------
# A gitignored home-local file (one per home) whose first non-comment,
# non-empty line is a positive integer giving the sentinel cadence in seconds
# (comments start with '#'; default 600 when absent or invalid). The sentinel
# reports the active cadence in its log line and verbose output so the wiring
# is verifiable; it never schedules itself.
CADENCE_CONFIG="$TMP_ROOT/cadence-config"
mkdir -p "$CADENCE_CONFIG"

test_sentinel_honors_cadence_config() {
  local out
  printf '# home cadence override\n120\n' > "$CADENCE_CONFIG/refill-sentinel"
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" FM_CONFIG_OVERRIDE="$CADENCE_CONFIG" \
    FM_REFILL_SENTINEL_VERBOSE=1 "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_contains "$out" "cadence=120" "sentinel did not report the config-file cadence"
  pass "config/refill-sentinel cadence is honored and reported"
}

test_sentinel_invalid_cadence_falls_back_to_default() {
  local out
  printf '# only a comment, no value\n' > "$CADENCE_CONFIG/refill-sentinel"
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" FM_CONFIG_OVERRIDE="$CADENCE_CONFIG" \
    FM_REFILL_SENTINEL_VERBOSE=1 "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_contains "$out" "cadence=600" "a comment-only cadence file did not fall back to 600"
  printf 'not-a-number\n' > "$CADENCE_CONFIG/refill-sentinel"
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" FM_CONFIG_OVERRIDE="$CADENCE_CONFIG" \
    FM_REFILL_SENTINEL_VERBOSE=1 "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_contains "$out" "cadence=600" "an invalid cadence value did not fall back to 600"
  pass "an absent, comment-only, or invalid cadence value falls back to the 600 default"
}

test_sentinel_env_cadence_overrides_config() {
  local out
  printf '120\n' > "$CADENCE_CONFIG/refill-sentinel"
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" FM_CONFIG_OVERRIDE="$CADENCE_CONFIG" \
    FM_REFILL_SENTINEL_CADENCE_SECS=300 FM_REFILL_SENTINEL_VERBOSE=1 "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_contains "$out" "cadence=300" "FM_REFILL_SENTINEL_CADENCE_SECS did not override the config file"
  pass "FM_REFILL_SENTINEL_CADENCE_SECS still overrides the config file"
}

# --- Task 15: alert-only rollback mode -------------------------------------
# Without the automatic gate (config/refill-auto or FM_REFILL_AUTO=1) the
# sentinel reports alert-only mode in its log and verbose output; with the
# gate on it reports automatic. It never dispatches regardless.
NOAUTO_CONFIG="$TMP_ROOT/noauto-config"
mkdir -p "$NOAUTO_CONFIG"

test_sentinel_reports_alert_only_mode_without_the_automatic_gate() {
  local out
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" FM_REFILL_SENTINEL_VERBOSE=1 \
    FM_CONFIG_OVERRIDE="$NOAUTO_CONFIG" FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_contains "$out" "mode=alert-only" "sentinel did not report the alert-only rollback mode"
  assert_contains "$out" "mode=alert-only" "sentinel log line lacks the alert-only mode"
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" FM_REFILL_SENTINEL_VERBOSE=1 \
    FM_CONFIG_OVERRIDE="$NOAUTO_CONFIG" FM_REFILL_AUTO=1 \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_contains "$out" "mode=automatic" "sentinel did not report automatic mode with the gate on"
  pass "sentinel reports alert-only mode unless the automatic gate is on"
}

test_sentinel_is_silent_when_refill_is_safe
test_sentinel_notifies_on_reconciliation_or_alert
test_sentinel_never_counts
test_sentinel_honors_cadence_config
test_sentinel_invalid_cadence_falls_back_to_default
test_sentinel_env_cadence_overrides_config
test_sentinel_reports_alert_only_mode_without_the_automatic_gate
