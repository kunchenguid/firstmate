#!/usr/bin/env bash
# Behavior tests for deterministic, run-rate-aware crew dispatch selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-dispatch-select-tests)
mkdir -p "$TMP_ROOT"

NOW=1784419200 # 2026-07-19T00:00:00Z
JUL24=1784851200
profiles='[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'

run_fixture() {
  local quota=$1 err=$2
  shift 2
  "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" \
    --now-epoch "$NOW" "$@" "$profiles" 2> "$err"
}

test_low_remaining_slow_burn_beats_high_remaining_burst() {
  local quota state out err
  quota="$TMP_ROOT/run-rate.json"
  state="$TMP_ROOT/run-rate-state.json"
  err="$TMP_ROOT/run-rate.err"
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "kind": "session", "percentUsed": 80, "percentRemaining": 20, "resetsAt": "2026-07-19T00:10:00Z"},
        {"id": "seven_day", "kind": "weekly", "percentUsed": 80, "percentRemaining": 20, "resetsAt": "2026-07-20T00:00:00Z"},
        {"id": "model:fable", "kind": "model", "percentUsed": 99, "percentRemaining": 1, "resetsAt": "2026-07-20T00:00:00Z"}
      ]
    },
    {
      "provider": "codex",
      "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "label": "session", "kind": "session", "windowSeconds": 604800, "percentUsed": 20, "percentRemaining": 80, "resetsAt": "2026-07-24T00:00:00Z"}
      ]
    }
  ]
}
JSON
  cat > "$state" <<JSON
{"schemaVersion":1,"samples":[{"provider":"codex","id":"five_hour","kind":"session","durationSeconds":604800,"resetsAtEpoch":$JUL24,"sampledAtEpoch":$((NOW - 3600)),"percentUsed":5}]}
JSON

  out=$(run_fixture "$quota" "$err" --state-file "$state")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "slow sustainable burn should beat high remaining with a burst, got: $out"
  assert_contains "$(cat "$err")" "candidate codex" "run-rate diagnostics should include Codex"
  assert_contains "$(cat "$err")" "rate-source=recent" "recent burst should drive the Codex estimate"
  pass "low remaining with slow burn beats high remaining with unsustainable recent burn"
}

test_claude_session_and_weekly_bottlenecks() {
  local quota out err diagnostics
  quota="$TMP_ROOT/claude-windows.json"
  err="$TMP_ROOT/claude-windows.err"
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "kind": "session", "percentUsed": 10, "percentRemaining": 90, "resetsAt": "2026-07-19T01:00:00Z"},
        {"id": "seven_day", "kind": "weekly", "percentUsed": 70, "percentRemaining": 30, "resetsAt": "2026-07-24T00:00:00Z"}
      ]
    },
    {
      "provider": "codex",
      "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "kind": "session", "windowSeconds": 604800, "percentUsed": 50, "percentRemaining": 50, "resetsAt": "2026-07-19T00:00:00Z"}
      ]
    }
  ]
}
JSON

  out=$(run_fixture "$quota" "$err")
  diagnostics=$(cat "$err")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "Claude weekly bottleneck should constrain an ample session window, got: $out"
  assert_contains "$diagnostics" "candidate claude trust=fresh window=session/18000s" \
    "Claude session should use its canonical five-hour duration"
  assert_contains "$diagnostics" "candidate claude trust=fresh window=weekly/604800s" \
    "Claude weekly window should be scored independently"
  pass "Claude selection uses the lower sustainable headroom across session and weekly windows"
}

test_codex_mislabeled_window_uses_actual_duration() {
  local quota out err diagnostics
  quota="$TMP_ROOT/codex-duration.json"
  err="$TMP_ROOT/codex-duration.err"
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {"provider": "claude", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "kind": "session", "percentUsed": 60, "percentRemaining": 40, "resetsAt": "2026-07-19T00:00:00Z"}
    ]},
    {"provider": "codex", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "label": "session", "kind": "session", "windowSeconds": 604800, "percentUsed": 20, "percentRemaining": 80, "resetsAt": "2026-07-24T00:00:00Z"},
      {"id": "model:codex_bengalfox:5h", "kind": "model", "windowSeconds": 604800, "percentUsed": 99, "percentRemaining": 1, "resetsAt": "2026-07-24T00:00:00Z"}
    ]}
  ]
}
JSON

  out=$(run_fixture "$quota" "$err")
  diagnostics=$(cat "$err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "Codex seven-day burn should lose despite its five_hour id, got: $out"
  assert_contains "$diagnostics" "candidate codex trust=fresh window=weekly/604800s source-kind=session" \
    "Codex diagnostics should expose the actual seven-day weekly scope"
  assert_not_contains "$diagnostics" "codex_bengalfox" "model windows must remain excluded"
  pass "Codex's misleading five_hour id cannot override its actual seven-day duration"
}

test_configured_codex_extra_resets_add_capacity() {
  local quota config out err diagnostics
  quota="$TMP_ROOT/extra-resets.json"
  config="$TMP_ROOT/extra-resets-config.json"
  err="$TMP_ROOT/extra-resets.err"
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {"provider": "claude", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "kind": "session", "percentUsed": 60, "percentRemaining": 40, "resetsAt": "2026-07-19T00:00:00Z"}
    ]},
    {"provider": "codex", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "kind": "session", "windowSeconds": 604800, "percentUsed": 100, "percentRemaining": 0, "resetsAt": "2026-07-24T00:00:00Z"},
      {"id": "independent_five_hour", "kind": "session", "windowSeconds": 18000, "percentUsed": 0, "percentRemaining": 100, "resetsAt": "2026-07-19T00:00:00Z"}
    ]}
  ]
}
JSON
  cat > "$config" <<'JSON'
{
  "quotaBalanced": {
    "providers": {
      "codex": {
        "windows": [
          {"scope": "weekly", "durationSeconds": 604800, "extraResets": 3}
        ]
      }
    }
  }
}
JSON

  out=$(run_fixture "$quota" "$err" --config "$config")
  diagnostics=$(cat "$err")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "three manual Codex resets should add three windows of capacity, got: $out"
  assert_contains "$(printf '%s\n' "$diagnostics" | grep 'candidate codex.*window=weekly')" \
    "extra-resets=3" "weekly diagnostics should disclose configured reset capacity"
  assert_contains "$(printf '%s\n' "$diagnostics" | grep 'candidate codex.*window=session')" \
    "extra-resets=0" "independent five-hour capacity must not receive weekly reset credits"
  pass "three Codex weekly resets add weekly capacity while the independent five-hour window gets zero"
}

test_stale_candidate_keeps_existing_clear_margin_policy() {
  local quota out err
  quota="$TMP_ROOT/stale.json"
  err="$TMP_ROOT/stale.err"
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {"provider": "claude", "state": {"status": "stale"}, "windows": [
      {"id": "five_hour", "kind": "session", "percentUsed": 70, "percentRemaining": 30, "resetsAt": "2026-07-19T00:00:00Z"}
    ]},
    {"provider": "codex", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "kind": "session", "windowSeconds": 604800, "percentUsed": 80, "percentRemaining": 20, "resetsAt": "2026-07-19T00:00:00Z"}
    ]}
  ]
}
JSON
  out=$(run_fixture "$quota" "$err")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "fresh candidate should win when stale lead is under 20, got: $out"

  jq '(.providers[] | select(.provider == "claude").windows[0]) |= (.percentUsed = 50 | .percentRemaining = 50)' \
    "$quota" > "$TMP_ROOT/stale-clear.json"
  out=$(run_fixture "$TMP_ROOT/stale-clear.json" "$err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "stale candidate should win when sustainable score clears 20, got: $out"
  pass "stale cached data remains usable only when its score clears the existing margin"
}

test_rollover_discards_incompatible_recent_sample() {
  local quota state out err new_reset
  quota="$TMP_ROOT/rollover.json"
  state="$TMP_ROOT/rollover-state.json"
  err="$TMP_ROOT/rollover.err"
  new_reset=$(jq -nr '"2026-07-26T00:00:00Z" | fromdateiso8601')
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {"provider": "claude", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "kind": "session", "percentUsed": 5, "percentRemaining": 95, "resetsAt": "2026-07-19T01:00:00Z"}
    ]},
    {"provider": "codex", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "kind": "session", "windowSeconds": 604800, "percentUsed": 5, "percentRemaining": 95, "resetsAt": "2026-07-26T00:00:00Z"}
    ]}
  ]
}
JSON
  cat > "$state" <<JSON
{"schemaVersion":1,"samples":[{"provider":"codex","id":"five_hour","kind":"session","durationSeconds":604800,"resetsAtEpoch":$JUL24,"sampledAtEpoch":$((NOW - 3600)),"percentUsed":95}]}
JSON

  out=$(run_fixture "$quota" "$err" --state-file "$state")
  [ -n "$out" ] || fail "rollover selection returned no profile"
  assert_contains "$(cat "$err")" "candidate codex" "rollover diagnostics should include Codex"
  assert_contains "$(cat "$err")" "rate-source=cycle" "rollover should discard the old recent sample"
  [ "$(jq -r '.samples[] | select(.provider == "codex").resetsAtEpoch' "$state")" = "$new_reset" ] \
    || fail "rollover should atomically replace the prior reset sample"
  pass "window rollover discards incompatible history and records the new cycle"
}

test_missing_duration_and_clock_skew_are_contained() {
  local quota out err diagnostics
  quota="$TMP_ROOT/missing-duration.json"
  err="$TMP_ROOT/missing-duration.err"
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {"provider": "claude", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "kind": "session", "percentUsed": 0, "percentRemaining": 100, "resetsAt": "2026-07-19T06:00:00Z"}
    ]},
    {"provider": "codex", "state": {"status": "fresh"}, "windows": [
      {"id": "five_hour", "kind": "session", "percentUsed": 0, "percentRemaining": 100, "resetsAt": "2026-07-26T00:00:00Z"}
    ]}
  ]
}
JSON

  out=$(run_fixture "$quota" "$err")
  diagnostics=$(cat "$err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "Codex without authoritative duration should be unavailable, got: $out"
  assert_contains "$diagnostics" "clock-clamped=true" "future reset beyond duration should be clock-clamped"
  assert_not_contains "$diagnostics" "candidate codex" "missing Codex duration should not trust the five_hour id"
  pass "missing durations are skipped and reset clock skew is bounded by actual duration"
}

test_quota_failures_and_old_schema_fall_back_to_first() {
  local fakebin out err status quota
  fakebin=$(fm_fakebin "$TMP_ROOT/failure")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced \
    "$profiles" 2> "$TMP_ROOT/failure.err")
  status=$?
  err=$(cat "$TMP_ROOT/failure.err")
  expect_code 0 "$status" "quota-axi error should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "quota-axi failure should fall back to first, got: $out"
  assert_contains "$err" "quota-axi exited 42" "quota-axi failure should be diagnosed"

  quota="$TMP_ROOT/schema-one.json"
  printf '%s\n' '{"schemaVersion":1,"providers":[]}' > "$quota"
  out=$(run_fixture "$quota" "$TMP_ROOT/schema-one.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "unsupported schema should fall back to first, got: $out"
  assert_contains "$(cat "$TMP_ROOT/schema-one.err")" "unsupported schema" \
    "unsupported schema should be diagnosed"
  pass "quota-axi failure and unsupported schemas retain the first-profile fail-safe"
}

test_live_quota_uses_account_free_json_and_private_diagnostics() {
  local fakebin args out diagnostics
  fakebin=$(fm_fakebin "$TMP_ROOT/live-quota")
  args="$TMP_ROOT/live-quota.args"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$args'
cat <<'JSON'
{"schemaVersion":2,"account":{"email":"private@example.com"},"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-07-19T01:00:00Z"}
  ]}
]}
JSON
SH
  chmod +x "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced \
    --now-epoch "$NOW" "$profiles" 2> "$TMP_ROOT/live-quota.err")
  diagnostics=$(cat "$TMP_ROOT/live-quota.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "live quota JSON should select from schema-v2 windows, got: $out"
  [ "$(cat "$args")" = "--json" ] \
    || fail "live quota command should request only normal account-free JSON"
  assert_not_contains "$diagnostics" "private@example.com" \
    "quota diagnostics must not expose account identity"
  pass "live quota requests normal JSON and keeps account data out of diagnostics"
}

test_backward_compatible_non_selector_paths() {
  local fakebin marker out single array_rule
  fakebin=$(fm_fakebin "$TMP_ROOT/no-call")
  marker="$TMP_ROOT/quota-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"

  single='{"harness":"grok","model":"grok-4","effort":"high"}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$single")
  [ "$out" = '{"harness":"grok","model":"grok-4","effort":"high"}' ] \
    || fail "single-object use should resolve to itself, got: $out"

  array_rule='{"when":"big work","use":[{"harness":"claude","effort":"high"},{"harness":"codex","effort":"high"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$array_rule")
  [ "$out" = '{"harness":"claude","effort":"high"}' ] \
    || fail "array without select should resolve to first, got: $out"
  [ ! -e "$marker" ] || fail "quota-axi should not be called without quota-balanced select"
  pass "single-object and no-select arrays preserve first-profile selection"
}

test_low_remaining_slow_burn_beats_high_remaining_burst
test_claude_session_and_weekly_bottlenecks
test_codex_mislabeled_window_uses_actual_duration
test_configured_codex_extra_resets_add_capacity
test_stale_candidate_keeps_existing_clear_margin_policy
test_rollover_discards_incompatible_recent_sample
test_missing_duration_and_clock_skew_are_contained
test_quota_failures_and_old_schema_fall_back_to_first
test_live_quota_uses_account_free_json_and_private_diagnostics
test_backward_compatible_non_selector_paths

echo "# all fm-dispatch-select tests passed"
