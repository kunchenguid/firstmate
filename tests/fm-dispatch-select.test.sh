#!/usr/bin/env bash
# Behavior tests for deterministic crew-dispatch profile selection.
set -u
export FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_test_tmproot_into TMP_ROOT fm-dispatch-select-tests
mkdir -p "$TMP_ROOT"

write_quota() {
  local file=$1 claude_status=$2 claude_five=$3 claude_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "$claude_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_five },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": $claude_week },
        { "id": "model:fable", "kind": "model", "percentRemaining": 100 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week },
        { "id": "model:codex_bengalfox:5h", "kind": "model", "percentRemaining": 100 }
      ]
    }
  ]
}
JSON
}

profiles='[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'

test_higher_min_vendor_wins() {
  local quota out
  quota="$TMP_ROOT/higher.json"
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "higher-min vendor should win, got: $out"
  pass "quota-balanced picks the candidate with the higher general-window minimum"
}

test_exact_tie_uses_first_profile() {
  local quota out
  quota="$TMP_ROOT/tie.json"
  write_quota "$quota" fresh 90 50 fresh 60 50
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "exact tie should pick first profile, got: $out"
  pass "quota-balanced exact tie uses the first ordered profile"
}

test_quota_missing_falls_back_to_first() {
  local fakebin out err status
  fakebin=$(fm_fakebin "$TMP_ROOT/missing")
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/missing.err")
  status=$?
  err=$(cat "$TMP_ROOT/missing.err")
  expect_code 0 "$status" "missing quota-axi should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "missing quota-axi should fall back to first, got: $out"
  assert_contains "$err" "quota-axi missing" "missing quota-axi fallback should be logged"
  pass "quota-axi missing falls back to the first profile and logs"
}

test_quota_error_falls_back_to_first() {
  local fakebin out err status
  fakebin=$(fm_fakebin "$TMP_ROOT/error")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/error.err")
  status=$?
  err=$(cat "$TMP_ROOT/error.err")
  expect_code 0 "$status" "quota-axi error should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "quota-axi error should fall back to first, got: $out"
  assert_contains "$err" "quota-axi exited 42" "quota-axi error fallback should be logged"
  pass "quota-axi non-zero exit falls back to the first profile and logs"
}

test_bad_quota_json_falls_back_to_first() {
  local quota out err
  quota="$TMP_ROOT/bad.json"
  printf '%s\n' 'not-json' > "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/bad.err")
  err=$(cat "$TMP_ROOT/bad.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "bad quota JSON should fall back to first, got: $out"
  assert_contains "$err" "unparseable JSON" "bad quota JSON fallback should be logged"
  pass "unparseable quota JSON falls back to the first profile and logs"
}

test_stale_with_cache_needs_clear_margin_to_beat_fresh() {
  local quota out
  quota="$TMP_ROOT/stale-margin.json"
  write_quota "$quota" stale 85 70 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "fresh vendor should win when stale lead is below margin, got: $out"

  write_quota "$quota" stale 90 85 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "stale vendor should win when lead clears margin, got: $out"
  pass "stale cached quota is usable only when it clears the documented margin over fresh"
}

test_vendor_absent_or_unusable_falls_back_conservatively() {
  local quota out err
  quota="$TMP_ROOT/absent.json"
  cat > "$quota" <<'JSON'
{
  "providers": [
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 40 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 50 }
      ]
    }
  ]
}
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "available candidate should win over absent vendor, got: $out"

  cat > "$quota" <<'JSON'
{ "providers": [] }
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/none.err")
  err=$(cat "$TMP_ROOT/none.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "no usable vendors should fall back to first, got: $out"
  assert_contains "$err" "no usable quota windows" "no usable vendor fallback should be logged"
  pass "absent or unusable vendors resolve to an available candidate or the first fallback"
}

test_backward_compatible_first_selection() {
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
  pass "single-object use and no-select arrays preserve first-profile selection"
}

make_fake_agent_fleet() {
  local fakebin=$1
  cat > "$fakebin/agent-fleet" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_AF_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_AF_LOG"
[ "$*" != "--format json contract" ] || { printf '{"contract_version":2}\n'; exit 0; }
pool=
provider=
prev=
for arg in "$@"; do
  case "$prev" in --pool) pool=$arg ;; --provider) provider=$arg ;; esac
  prev=$arg
done
sleep_seconds=${FM_FAKE_AF_SLEEP:-}
case "$provider" in
  claude) sleep_seconds=${FM_FAKE_CLAUDE_SLEEP:-$sleep_seconds} ;;
  codex) sleep_seconds=${FM_FAKE_CODEX_SLEEP:-$sleep_seconds} ;;
esac
[ -z "$sleep_seconds" ] || sleep "$sleep_seconds"
case "$pool" in
  claude-crew) available=true; mode=quota; headroom=${FM_FAKE_CLAUDE_HEADROOM:-25} ;;
  codex-crew) available=true; mode=quota; headroom=${FM_FAKE_CODEX_HEADROOM:-70} ;;
  stale-crew) available=true; mode=least-active-fallback; headroom=null ;;
  *) available=false; mode=unavailable; headroom=null ;;
esac
if [ "$available" = true ]; then eligible=true; eligible_profiles=1; else eligible=false; eligible_profiles=0; fi
printf '{"schema":1,"pool":"%s","providers":[{"provider":"%s","available":%s,"selection_mode":"%s","degraded":false,"best_adjusted_headroom_percent":%s,"eligible_profiles":%s,"active_leases":0,"profiles":[{"profile":"%s-1","eligible":%s,"quota_fresh":true,"identity_binding_conflict":null,"live_identity_failure":null}]}]}\n' \
  "$pool" "$provider" "$available" "$mode" "$headroom" "$eligible_profiles" "$pool" "$eligible"
SH
  chmod +x "$fakebin/agent-fleet"
}

test_account_pool_query_timeout_falls_back() {
  local fakebin pooled out started elapsed
  fakebin=$(fm_fakebin "$TMP_ROOT/agent-fleet-timeout")
  make_fake_agent_fleet "$fakebin"
  pooled='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  started=$(date +%s)
  out=$(FM_FAKE_AF_SLEEP=10 FM_DISPATCH_AGENT_FLEET_TIMEOUT=1 \
    FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" 2>"$TMP_ROOT/agent-fleet-timeout.err")
  elapsed=$(( $(date +%s) - started ))
  [ "$out" = '{"harness":"claude","account_pool":"claude-crew"}' ] || fail "timed-out pool query did not use the first profile"
  [ "$elapsed" -lt 5 ] || fail "pool query exceeded its command timeout (${elapsed}s)"
  assert_contains "$(cat "$TMP_ROOT/agent-fleet-timeout.err")" 'agent-fleet pool status failed' "pool timeout fallback was not logged"
  pass "quota-balanced dispatch bounds Agent Fleet pool queries"
}

test_slow_valid_pool_status_uses_selection_class_timeout() {
  local fakebin pooled out started elapsed err
  fakebin=$(fm_fakebin "$TMP_ROOT/agent-fleet-slow-valid")
  make_fake_agent_fleet "$fakebin"
  pooled='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  started=$(date +%s)
  out=$(FM_FAKE_CLAUDE_SLEEP=6 FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" \
    2>"$TMP_ROOT/agent-fleet-slow-valid.err")
  elapsed=$(( $(date +%s) - started ))
  err=$(cat "$TMP_ROOT/agent-fleet-slow-valid.err")
  [ "$elapsed" -ge 5 ] || fail "slow pool summary did not cross the former five-second bound"
  [ "$out" = '{"harness":"codex","account_pool":"codex-crew"}' ] \
    || fail "slow valid pool summary fell back instead of selecting fresh headroom: $out"
  assert_not_contains "$err" 'agent-fleet pool status failed' \
    "slow valid pool summary hit the former control-plane timeout"
  pass "live-proof pool summaries use the honest selection-class timeout"
}

test_invalid_pool_status_timeout_is_rejected() {
  local fakebin pooled out status err
  fakebin=$(fm_fakebin "$TMP_ROOT/agent-fleet-invalid-timeout")
  make_fake_agent_fleet "$fakebin"
  pooled='[{"harness":"claude","account_pool":"claude-crew"}]'
  if out=$(FM_DISPATCH_AGENT_FLEET_TIMEOUT=invalid \
    FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" \
    2>"$TMP_ROOT/agent-fleet-invalid-timeout.err"); then
    status=0
  else
    status=$?
  fi
  err=$(cat "$TMP_ROOT/agent-fleet-invalid-timeout.err")
  expect_code 2 "$status" "invalid pool-status timeout should fail configuration validation"
  [ -z "$out" ] || fail "invalid pool-status timeout unexpectedly emitted a profile: $out"
  assert_contains "$err" 'FM_DISPATCH_AGENT_FLEET_TIMEOUT must be a positive integer' \
    "invalid pool-status timeout diagnostic did not name its variable"
  pass "pool-status timeout validation fails closed"
}

test_dispatch_ignores_hostile_path_jq_and_dirname() {
  local fakebin jq_marker dirname_marker cat_marker awk_marker spec out stdin_out
  fakebin=$(fm_fakebin "$TMP_ROOT/hostile-path-tools")
  jq_marker="$TMP_ROOT/hostile-path-tools/jq-called"
  dirname_marker="$TMP_ROOT/hostile-path-tools/dirname-called"
  cat_marker="$TMP_ROOT/hostile-path-tools/cat-called"
  awk_marker="$TMP_ROOT/hostile-path-tools/awk-called"
  cat > "$fakebin/jq" <<SH
#!/bin/sh
printf called > '$jq_marker'
printf '%s\n' '{"harness":"forged"}'
SH
  cat > "$fakebin/dirname" <<SH
#!/bin/sh
printf called > '$dirname_marker'
printf '%s\n' /forged
SH
  cat > "$fakebin/cat" <<SH
#!/bin/sh
printf called > '$cat_marker'
printf '%s\n' '{"harness":"forged"}'
SH
  cat > "$fakebin/awk" <<SH
#!/bin/sh
printf called > '$awk_marker'
printf '%s\n' 'forged help'
SH
  chmod +x "$fakebin/jq" "$fakebin/dirname" "$fakebin/cat" "$fakebin/awk"
  spec='{"harness":"claude","model":"sonnet"}'

  out=$(CDPATH='' builtin cd -- "$ROOT/bin" && \
    PATH="$fakebin:$BASE_PATH" /bin/bash fm-dispatch-select.sh "$spec")
  stdin_out=$(printf '%s\n' "$spec" | (CDPATH='' builtin cd -- "$ROOT/bin" && \
    PATH="$fakebin:$BASE_PATH" /bin/bash fm-dispatch-select.sh))

  [ "$out" = '{"harness":"claude","model":"sonnet"}' ] \
    || fail "hostile PATH forged dispatch selection: $out"
  [ "$stdin_out" = "$out" ] || fail "hostile PATH forged stdin dispatch selection: $stdin_out"
  [ ! -e "$jq_marker" ] || fail "dispatch executed hostile PATH jq"
  [ ! -e "$dirname_marker" ] || fail "dispatch executed hostile PATH dirname"
  [ ! -e "$cat_marker" ] || fail "dispatch executed hostile PATH cat"
  [ ! -e "$awk_marker" ] || fail "dispatch executed hostile PATH awk"
  pass "dispatch pins its parser and input tools without ambient PATH resolution"
}

test_account_pool_defers_selection_to_direct_spawn() {
  local fakebin af_log quota_marker out pooled err
  fakebin=$(fm_fakebin "$TMP_ROOT/agent-fleet-pools")
  af_log="$TMP_ROOT/agent-fleet-pools/calls.log"
  quota_marker="$TMP_ROOT/agent-fleet-pools/quota-called"
  make_fake_agent_fleet "$fakebin"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
touch '$quota_marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  pooled='[{"harness":"claude","model":"sonnet","account_pool":"claude-crew"},{"harness":"codex","model":"gpt-5","account_pool":"codex-crew"}]'
  out=$(FM_FAKE_AF_LOG="$af_log" FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    FM_DISPATCH_QUOTA_AXI="$fakebin/quota-axi" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" \
    2>"$TMP_ROOT/agent-fleet-pools/error.log")
  err=$(cat "$TMP_ROOT/agent-fleet-pools/error.log")
  [ "$out" = '{"harness":"claude","model":"sonnet","account_pool":"claude-crew"}' ] \
    || fail "pooled dispatch did not preserve ordered direct-routing activation: $out"
  [ ! -e "$af_log" ] || fail "new pooled dispatch queried Agent Fleet: $(cat "$af_log")"
  [ ! -e "$quota_marker" ] || fail "account_pool selection consulted default-account quota-axi"
  assert_contains "$err" 'deferring account selection to spawn' "pooled dispatch did not explain direct selection ownership"
  pass "account_pool dispatch defers account choice to direct spawn selection"
}

test_degraded_pool_summary_is_diagnostic_only() {
  local fakebin out pooled err
  fakebin=$(fm_fakebin "$TMP_ROOT/agent-fleet-degraded-pool")
  make_fake_agent_fleet "$fakebin"
  pooled='[{"harness":"claude","account_pool":"stale-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled")
  [ "$out" = '{"harness":"codex","account_pool":"codex-crew"}' ] \
    || fail "degraded pool displaced a freshly routeable pool: $out"

  pooled='[{"harness":"claude","account_pool":"stale-crew"},{"harness":"codex","account_pool":"missing-crew"}]'
  out=$(FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" \
    2>"$TMP_ROOT/agent-fleet-degraded-pool/error.log")
  err=$(cat "$TMP_ROOT/agent-fleet-degraded-pool/error.log")
  [ "$out" = '{"harness":"claude","account_pool":"stale-crew"}' ] \
    || fail "advisory total-unavailable fallback changed the ordered first profile: $out"
  assert_contains "$err" 'no freshly routeable Agent Fleet account pools' \
    "degraded-only fallback was not logged as unavailable"
  pass "degraded Agent Fleet summaries remain diagnostic-only and never compete as available"
}

test_enforced_quota_balancing_rejects_poolless_candidates() {
  local fakebin quota_marker profiles out status
  fakebin=$(fm_fakebin "$TMP_ROOT/enforced-pool-only")
  quota_marker="$TMP_ROOT/enforced-pool-only/quota-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
touch '$quota_marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  profiles='[{"harness":"claude"},{"harness":"codex"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce FM_DISPATCH_QUOTA_AXI="$fakebin/quota-axi" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/enforced-pool-only/error.log")
  status=$?
  expect_code 2 "$status" "enforced poolless quota-balanced dispatch must be rejected"
  [ -z "$out" ] || fail "rejected enforced selection emitted a profile: $out"
  [ ! -e "$quota_marker" ] || fail "enforced poolless selection consulted ambient quota-axi"
  assert_contains "$(cat "$TMP_ROOT/enforced-pool-only/error.log")" 'requires a non-empty valid account_pool on every candidate' \
    "enforced pool-only error was unclear"

  profiles='[{"harness":"claude","account_pool":""},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" \
    2>"$TMP_ROOT/enforced-pool-only/empty-error.log")
  status=$?
  expect_code 2 "$status" "enforced empty account pool must be rejected"
  [ -z "$out" ] || fail "rejected empty pool selection emitted a profile: $out"

  profiles='[{"harness":"claude","account_pool":"-invalid"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" \
    2>"$TMP_ROOT/enforced-pool-only/invalid-error.log")
  status=$?
  expect_code 2 "$status" "enforced invalid account pool must be rejected"
  [ -z "$out" ] || fail "rejected invalid pool selection emitted a profile: $out"

  profiles='[{"harness":"claude","account_pool":"good\npool"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" \
    2>"$TMP_ROOT/enforced-pool-only/newline-error.log")
  status=$?
  expect_code 2 "$status" "enforced account pool with an embedded newline must be rejected"
  [ -z "$out" ] || fail "rejected embedded-newline pool selection emitted a profile: $out"

  profiles='[{"harness":"claude","account_pool":"good-pool\n"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" \
    2>"$TMP_ROOT/enforced-pool-only/trailing-newline-error.log")
  status=$?
  expect_code 2 "$status" "enforced account pool with a trailing newline must be rejected"
  [ -z "$out" ] || fail "rejected trailing-newline pool selection emitted a profile: $out"
  pass "enforced quota-balanced dispatch accepts only explicit pools"
}

test_fully_pooled_dispatch_ignores_overridden_ambient_mode() {
  local fakebin pooled mixed out status
  fakebin=$(fm_fakebin "$TMP_ROOT/pooled-precedence")
  make_fake_agent_fleet "$fakebin"
  pooled='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=malformed FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled") \
    || fail "fully pooled dispatch parsed overridden ambient routing policy"
  [ "$out" = '{"harness":"claude","account_pool":"claude-crew"}' ] \
    || fail "fully pooled dispatch returned the wrong selection: $out"

  mixed='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex"}]'
  out=$(FM_ACCOUNT_ROUTING=malformed FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$mixed" 2>/dev/null)
  status=$?
  expect_code 2 "$status" "mixed pooled dispatch must still fail closed on malformed routing mode"
  [ -z "$out" ] || fail "rejected mixed dispatch emitted a selection: $out"
  pass "fully pooled dispatch honors explicit pool precedence over ambient routing"
}

test_agent_fleet_binary_precedence_matches_routing() {
  local fakebin ambient good_log ambient_marker pooled out
  fakebin=$(fm_fakebin "$TMP_ROOT/agent-fleet-precedence")
  ambient=$(fm_fakebin "$TMP_ROOT/agent-fleet-precedence-ambient")
  good_log="$TMP_ROOT/agent-fleet-precedence/good.log"
  ambient_marker="$TMP_ROOT/agent-fleet-precedence/ambient-called"
  make_fake_agent_fleet "$fakebin"
  cat > "$ambient/agent-fleet" <<SH
#!/usr/bin/env bash
touch '$ambient_marker'
exit 1
SH
  chmod +x "$ambient/agent-fleet"
  pooled='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(PATH="$ambient:$PATH" FM_FAKE_AF_LOG="$good_log" FM_AGENT_FLEET_BIN="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled")
  [ "$out" = '{"harness":"codex","account_pool":"codex-crew"}' ] || fail "pinned Agent Fleet selection returned: $out"
  assert_grep 'pool status --pool claude-crew' "$good_log" "pinned Agent Fleet binary was not queried"
  [ ! -e "$ambient_marker" ] || fail "dispatch ignored FM_AGENT_FLEET_BIN and called the ambient binary"
  pass "dispatch and spawn honor the same pinned Agent Fleet binary"
}

test_production_dispatch_override_is_never_executed() {
  local fakebin marker pooled out status error
  fakebin=$(fm_fakebin "$TMP_ROOT/production-agent-fleet-override")
  marker="$TMP_ROOT/production-agent-fleet-override/override-ran"
  cat > "$fakebin/agent-fleet" <<SH
#!/usr/bin/env bash
touch '$marker'
exit 1
SH
  chmod +x "$fakebin/agent-fleet"
  pooled='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(env -u FM_ACCOUNT_ROUTING_TEST_LAB \
    FM_CONFIG_OVERRIDE="$TMP_ROOT/production-agent-fleet-override/config" \
    FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" \
    2>"$TMP_ROOT/production-agent-fleet-override/error.log")
  status=$?
  error=$(cat "$TMP_ROOT/production-agent-fleet-override/error.log")
  expect_code 0 "$status" "selector should safely degrade after refusing production override"
  [ "$out" = '{"harness":"claude","account_pool":"claude-crew"}' ] \
    || fail "forbidden override fallback changed the ordered first profile: $out"
  [ ! -e "$marker" ] || fail "production dispatch executed its forbidden Agent Fleet override"
  assert_contains "$error" 'test/lab opt-in' "production override refusal was not surfaced"
  pass "production dispatch never executes overrides and degrades only to the first routed profile"
}

test_account_fields_survive_direct_selection() {
  local fakebin marker out profile
  fakebin=$(fm_fakebin "$TMP_ROOT/account-direct")
  marker="$TMP_ROOT/account-direct/agent-fleet-called"
  cat > "$fakebin/agent-fleet" <<SH
#!/usr/bin/env bash
touch '$marker'
exit 1
SH
  chmod +x "$fakebin/agent-fleet"
  profile='{"harness":"claude","model":"sonnet","effort":"high","account_pool":"claude-crew","account_profile":"claude-3"}'
  out=$(FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" "$ROOT/bin/fm-dispatch-select.sh" "$profile")
  [ "$out" = "$profile" ] || fail "direct selection dropped account fields: $out"
  [ ! -e "$marker" ] || fail "direct selection should not query Agent Fleet"
  pass "direct dispatch selection preserves account_pool and account_profile"
}

test_pooled_failures_degrade_without_default_account_quota() {
  local fakebin quota_marker out err pooled pinned status
  fakebin=$(fm_fakebin "$TMP_ROOT/account-fallback")
  quota_marker="$TMP_ROOT/account-fallback/quota-called"
  cat > "$fakebin/agent-fleet" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
touch '$quota_marker'
exit 1
SH
  chmod +x "$fakebin/agent-fleet" "$fakebin/quota-axi"
  pooled='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" FM_DISPATCH_QUOTA_AXI="$fakebin/quota-axi" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" 2>"$TMP_ROOT/account-fallback/error.log")
  err=$(cat "$TMP_ROOT/account-fallback/error.log")
  [ "$out" = '{"harness":"claude","account_pool":"claude-crew"}' ] || fail "pool failure should use first profile"
  assert_contains "$err" 'agent-fleet contract mismatch' "contract failure fallback was not logged"
  [ ! -e "$quota_marker" ] || fail "pool failure fell through to default-account quota"

  pinned='[{"harness":"claude","account_pool":"claude-crew","account_profile":"claude-1"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pinned" 2>"$TMP_ROOT/account-fallback/pinned.err")
  status=$?
  expect_code 2 "$status" "quota-balanced pinned candidates must be rejected"
  [ -z "$out" ] || fail "rejected pinned selection emitted a profile: $out"
  assert_contains "$(cat "$TMP_ROOT/account-fallback/pinned.err")" 'cannot carry account_profile' "pinned candidate error was unclear"

  pinned='[{"harness":"claude","account_profile":"claude-1"},{"harness":"codex"}]'
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pinned" 2>"$TMP_ROOT/account-fallback/profile-only.err")
  status=$?
  expect_code 2 "$status" "profile-only quota-balanced candidates must be rejected"
  [ -z "$out" ] || fail "rejected profile-only selection emitted a profile: $out"
  pass "pool-summary failures degrade safely while every pinned quota-balanced candidate is rejected"
}

if [ "${FM_TEST_FOCUSED:-}" = account-directory-cutover ]; then
  test_account_pool_defers_selection_to_direct_spawn
  test_fully_pooled_dispatch_ignores_overridden_ambient_mode
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13 ]; then
  test_enforced_quota_balancing_rejects_poolless_candidates
  test_fully_pooled_dispatch_ignores_overridden_ambient_mode
  exit 0
fi

test_higher_min_vendor_wins
test_exact_tie_uses_first_profile
test_quota_missing_falls_back_to_first
test_quota_error_falls_back_to_first
test_bad_quota_json_falls_back_to_first
test_stale_with_cache_needs_clear_margin_to_beat_fresh
test_vendor_absent_or_unusable_falls_back_conservatively
test_backward_compatible_first_selection
test_account_pool_defers_selection_to_direct_spawn
test_dispatch_ignores_hostile_path_jq_and_dirname
test_enforced_quota_balancing_rejects_poolless_candidates
test_fully_pooled_dispatch_ignores_overridden_ambient_mode
test_account_fields_survive_direct_selection

echo "# all fm-dispatch-select tests passed"
