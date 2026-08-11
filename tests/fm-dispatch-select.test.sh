#!/usr/bin/env bash
# Behavior tests for subscription-aware crew dispatch selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR="$ROOT/bin/fm-dispatch-select.mjs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-dispatch-select.XXXXXX")
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
NOW=1000
STAMP=1970-01-01T00:16:40.000Z

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

make_fakebin() {
  local name=$1 dir
  dir="$TMP_ROOT/$name/fakebin"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

write_quota() { # <file> <claude-status> <claude-remaining> <codex-status> <codex-remaining> [stamp]
  local file=$1 cst=$2 crem=$3 ost=$4 orem=$5 stamp=${6:-$STAMP}
  cat > "$file" <<JSON
{"schemaVersion":3,"generatedAt":"$stamp","providers":[
  {"provider":"claude","state":{"status":"$cst","stale":false},"windows":[{"id":"all","percentRemaining":$crem}]},
  {"provider":"codex","state":{"status":"$ost","stale":false},"windows":[{"id":"all","percentRemaining":$orem}]}
]}
JSON
}

run_select() { # <home> <fakebin> <quota> <state-file-name> <json> [now]
  local home=$1 fakebin=$2 quota=$3 state_name=$4 body=$5 now=${6:-$NOW}
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISPATCH_STATE_FILE="$home/state/$state_name" \
    PATH="$fakebin:$BASE_PATH" \
    "$SELECTOR" select --quota-json "$quota" --now "$now" "$body"
}

test_distribution_is_deterministic_balanced_and_array_order_independent() {
  local home fakebin quota profiles reversed first reversed_first selected seen count
  home=$(make_home distribution)
  fakebin=$(make_fakebin distribution)
  quota="$home/quota.json"
  write_quota "$quota" fresh 80 fresh 80
  profiles='[{"harness":"claude","model":"sonnet"},{"harness":"codex","model":"gpt"}]'
  reversed='[{"harness":"codex","model":"gpt"},{"harness":"claude","model":"sonnet"}]'

  first=$(run_select "$home" "$fakebin" "$quota" a.json "$profiles" 2>/dev/null | jq -r .harness)
  reversed_first=$(run_select "$home" "$fakebin" "$quota" b.json "$reversed" 2>/dev/null | jq -r .harness)
  [ "$first" = "$reversed_first" ] || fail "initial deterministic choice changed with array order: $first vs $reversed_first"

  seen=$first
  selected=$(run_select "$home" "$fakebin" "$quota" a.json "$profiles" 2>/dev/null | jq -r .harness)
  seen="$seen $selected"
  for selected in claude codex; do
    count=$(printf '%s\n' "$seen" | tr ' ' '\n' | grep -cx "$selected")
    [ "$count" -eq 1 ] || fail "two healthy subscriptions did not rotate once each: $seen"
  done
  pass "dispatch selection is array-order independent and rotates healthy subscriptions exactly"
}

test_stale_unavailable_and_reserve_thresholds_fail_closed() {
  local home fakebin quota out rc profiles old_stamp
  home=$(make_home fail-closed)
  fakebin=$(make_fakebin fail-closed)
  quota="$home/quota.json"
  profiles='[{"harness":"claude"},{"harness":"codex"}]'
  old_stamp=1970-01-01T00:00:00.000Z

  write_quota "$quota" fresh 90 fresh 90 "$old_stamp"
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" stale.json "$profiles" 2>&1) || rc=$?
  expect_code 3 "$rc" "stale telemetry must stop all metered dispatch"
  assert_contains "$out" "stale or undated" "stale telemetry refusal was not inspectable"

  write_quota "$quota" fresh 20 fresh 21
  out=$(run_select "$home" "$fakebin" "$quota" reserve.json "$profiles" 2>"$home/reserve.err")
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = codex ] || fail "candidate above reserve did not beat candidate at reserve: $out"
  assert_contains "$(cat "$home/reserve.err")" "at or below 20% reserve" "reserve refusal omitted its threshold"

  write_quota "$quota" auth_required 99 fresh 75
  out=$(run_select "$home" "$fakebin" "$quota" unavailable.json "$profiles" 2>/dev/null)
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = codex ] || fail "fresh provider did not fail over around unavailable telemetry: $out"

  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"claude","state":{"status":"fresh","stale":false},"quotaSemantics":{"effectiveAvailability":[{"status":"known","effectivePercentRemaining":90}]}},
  {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"percentRemaining":80}]}
]}
JSON
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" windowless.json '[{"harness":"claude"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "windowless telemetry must stop metered dispatch despite aggregate availability"
  assert_contains "$out" "no usable live window percentage" "windowless telemetry refusal was unclear"
  pass "dispatch excludes stale, unavailable, and reserve-tight metered providers"
}

test_verified_failure_creates_cooldown_and_failover() {
  local home fakebin quota profiles out rc
  home=$(make_home cooldown)
  fakebin=$(make_fakebin cooldown)
  quota="$home/quota.json"
  write_quota "$quota" fresh 80 fresh 80
  profiles='[{"harness":"claude"},{"harness":"codex"}]'
  printf 'harness=codex\n' > "$home/state/rate-task.meta"
  printf 'failed: provider rate limit reached\n' > "$home/state/rate-task.status"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider codex --task rate-task --now 1000 \
    >/dev/null 2>&1 || fail "verified rate-limit evidence did not create cooldown"
  out=$(run_select "$home" "$fakebin" "$quota" .dispatch-routing.json "$profiles" 1001 2>"$home/select.err")
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = claude ] || fail "cooldown did not fail over to Claude: $out"
  assert_contains "$(cat "$home/select.err")" "cooldown until epoch 2800" "cooldown diagnostic omitted its bound"

  printf 'harness=codex\n' > "$home/state/no-evidence.meta"
  printf 'working: ordinary task\n' > "$home/state/no-evidence.status"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SELECTOR" record-failure --provider codex --task no-evidence --now 1000 2>&1) || rc=$?
  expect_code 2 "$rc" "cooldown without evidence must be rejected"
  assert_contains "$out" "contains no rate-limit or quota-exhaustion evidence" "evidence refusal was unclear"

  printf 'harness=pi\nprovider=claude\n' > "$home/state/pi-rate-task.meta"
  printf 'failed: provider quota exhausted\n' > "$home/state/pi-rate-task.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider claude --task pi-rate-task --now 1000 \
    >/dev/null 2>&1 || fail "recorded non-native routing provider did not create cooldown"
  pass "verified provider failure creates cooldown and deterministic failover"
}

test_invalid_profiles_and_settings_are_actionable() {
  local home fakebin quota out rc
  home=$(make_home invalid)
  fakebin=$(make_fakebin invalid)
  quota="$home/quota.json"
  write_quota "$quota" fresh 80 fresh 80

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" mismatch.json \
    '[{"harness":"kimi","model":"kimi-code/k3"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "Kimi must remain outside subscription dispatch"
  assert_contains "$out" "Kimi is unsupported for subscription dispatch" "Kimi exclusion was unclear"

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" native-mismatch.json \
    '[{"harness":"codex","provider":"claude"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "native harness/provider mismatch must be rejected"
  assert_contains "$out" "native harness codex requires provider codex" "native provider mismatch was unclear"

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" kimi-provider.json \
    '[{"harness":"kimi","provider":"claude"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "Kimi must remain unavailable even with another provider"
  assert_contains "$out" "Kimi is unsupported for subscription dispatch" "Kimi provider override was unclear"

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" raw-kimi.json \
    '[{"harness":"env X=1 kimi --auto","provider":"claude"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "raw commands must remain outside subscription dispatch"
  assert_contains "$out" "subscription dispatch requires a verified harness" "raw command exclusion was unclear"

  printf '%s\n' '{"subscriptionRouting":{"reservePercent":100}}' > "$home/config/crew-dispatch.json"
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" settings.json '[{"harness":"codex"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "out-of-range reserve must be rejected"
  assert_contains "$out" "reservePercent must be an integer from 0 to 99" "settings error omitted its range"

  printf '%s\n' '[]' > "$home/config/crew-dispatch.json"
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" root-array.json '[{"harness":"codex"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "non-object dispatch config roots must be rejected"
  assert_contains "$out" "config/crew-dispatch.json must be an object" "root schema refusal was unclear"
  pass "subscription route mismatches and malformed settings fail as configuration errors"
}

test_existing_wrapper_and_grok_routes_remain_selectable() {
  local home fakebin quota out
  home=$(make_home compatible-routes)
  fakebin=$(make_fakebin compatible-routes)
  quota="$home/quota.json"
  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"percentRemaining":70}]},
  {"provider":"grok","state":{"status":"fresh","stale":false},"windows":[{"percentRemaining":70}]}
]}
JSON
  out=$(run_select "$home" "$fakebin" "$quota" state.json \
    '[{"harness":"pi","provider":"claude","model":"anthropic/example"},{"harness":"grok"}]' 2>/dev/null)
  run_select "$home" "$fakebin" "$quota" state.json \
    '[{"harness":"pi","provider":"claude","model":"anthropic/example"},{"harness":"grok"}]' 2>/dev/null \
    | jq -e --arg first "$(printf '%s\n' "$out" | jq -r .harness)" '.harness != $first' >/dev/null \
    || fail "existing explicit wrapper and native Grok routes did not rotate"
  pass "existing explicit wrapper-provider and native Grok routes remain selectable"
}

test_new_verified_adapters_with_providers_are_selectable() {
  local home fakebin quota out harness provider
  home=$(make_home new-adapters)
  fakebin=$(make_fakebin new-adapters)
  quota="$home/quota.json"
  write_quota "$quota" fresh 80 fresh 80

  out=$(run_select "$home" "$fakebin" "$quota" state.json \
    '[{"harness":"cline","provider":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"cursor-agent","provider":"codex","model":"claude-opus-4-8"},{"harness":"copilot","provider":"claude","model":"gpt-5.6","effort":"max"}]' 2>/dev/null)
  harness=$(printf '%s\n' "$out" | jq -r .harness)
  provider=$(printf '%s\n' "$out" | jq -r .provider)
  case "$harness:$provider" in
    cline:claude|cursor-agent:codex|copilot:claude) ;;
    *) fail "new verified adapter profile selected an unexpected concrete route: $out" ;;
  esac
  pass "new verified adapters remain selectable with explicit provider identity"
}

test_distribution_is_deterministic_balanced_and_array_order_independent
test_stale_unavailable_and_reserve_thresholds_fail_closed
test_verified_failure_creates_cooldown_and_failover
test_invalid_profiles_and_settings_are_actionable
test_existing_wrapper_and_grok_routes_remain_selectable
test_new_verified_adapters_with_providers_are_selectable

echo "# all fm-dispatch-select tests passed"
