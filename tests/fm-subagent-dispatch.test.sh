#!/usr/bin/env bash
# Behavioral coverage for live Pi subagent config source selection, exact schema
# validation, and public workload resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-subagent-dispatch)
DISPATCH="$ROOT/bin/fm-subagent-dispatch.sh"

write_valid_config() {
  local path=$1 cheap_model=${2:-vendor/cheap} cheap_thinking=${3:-minimal}
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<JSON
{
  "maxConcurrency": 3,
  "modelTiers": {
    "cheap": {
      "workloads": [
        {"key":"w1","description":"Quick routing","model":"$cheap_model","thinkingLevel":"$cheap_thinking"},
        {"key":"w2","description":"Second quick route","model":"vendor/cheap-two","thinkingLevel":"low"}
      ]
    },
    "balanced": {
      "workloads": [
        {"key":"w1","description":"Normal implementation","model":"vendor/balanced","thinkingLevel":"medium"}
      ]
    },
    "strong": {
      "workloads": [
        {"key":"w9","description":"Hard investigation","model":"vendor/strong","thinkingLevel":"xhigh"}
      ]
    }
  }
}
JSON
}

run_override() {
  local config=$1
  shift
  PI_CODING_AGENT_DIR= FM_SUBAGENTS_CONFIG="$config" HOME="$TMP_ROOT/no-home" \
    "$DISPATCH" "$@"
}

expect_invalid() {
  local config=$1 expected=$2 out rc
  set +e
  out=$(run_override "$config" list 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "invalid subagent config"
  assert_contains "$out" "SUBAGENTS_CONFIG: invalid $config -" \
    "invalid config did not identify its selected source"
  assert_contains "$out" "$expected" "invalid config reason was not concrete"
}

test_fixture_resolution_and_list_json() {
  local config="$TMP_ROOT/fixture/config.json" out
  write_valid_config "$config"

  out=$(run_override "$config" resolve balanced w1)
  printf '%s' "$out" | jq -e --arg source "$config" '
    .source == $source and .tier == "balanced" and .workload == "w1" and
    .model == "vendor/balanced" and .effort == "medium" and
    .description == "Normal implementation"
  ' >/dev/null || fail "resolve did not return the selected validated routing entry"

  out=$(run_override "$config" list)
  printf '%s' "$out" | jq -e --arg source "$config" '
    .source == $source and .maxConcurrency == 3 and
    (.tiers | keys | sort) == ["balanced", "cheap", "strong"] and
    .tiers.cheap[1].workload == "w2" and .tiers.strong[0].description == "Hard investigation"
  ' >/dev/null || fail "list did not emit parseable validated routing JSON"
  [ "$(run_override "$config" path)" = "$config" ] || fail "path did not print the selected source"
  pass "fixture path, list, and resolve expose validated routing through the public command"
}

test_optional_concurrency_and_extension_model_shape() {
  local config="$TMP_ROOT/extension-shape/config.json" temp="$TMP_ROOT/extension-shape/temp.json" out
  write_valid_config "$config" 'vendor/model/with internal spaces/end' low
  jq 'del(.maxConcurrency)' "$config" >"$temp" && mv "$temp" "$config"

  out=$(run_override "$config" list)
  printf '%s' "$out" | jq -e '
    .maxConcurrency == 4 and
    .tiers.cheap[0].model == "vendor/model/with internal spaces/end"
  ' >/dev/null || fail "omitted maxConcurrency or additional-slash model did not match extension behavior"
  pass "omitted maxConcurrency defaults to 4 and extension-shaped model suffixes are accepted"
}

test_live_edit_is_seen_on_next_call() {
  local config="$TMP_ROOT/live/config.json" replacement="$TMP_ROOT/live/replacement.json" out
  write_valid_config "$config" vendor/before low
  out=$(run_override "$config" resolve cheap w1)
  [ "$(printf '%s' "$out" | jq -r .model)" = vendor/before ] || fail "initial live model was not read"

  jq '.modelTiers.cheap.workloads[0].model = "vendor/after" |
      .modelTiers.cheap.workloads[0].thinkingLevel = "high"' \
    "$config" >"$replacement"
  mv "$replacement" "$config"
  out=$(run_override "$config" resolve cheap w1)
  printf '%s' "$out" | jq -e '.model == "vendor/after" and .effort == "high"' >/dev/null \
    || fail "next invocation did not reread the edited live source"
  pass "each invocation sees the next live config edit"
}

test_source_precedence_and_fallbacks() {
  local pi_root="$TMP_ROOT/pi-root" pi_config override home="$TMP_ROOT/home" home_config out rc
  pi_config="$pi_root/extensions/subagents/config.json"
  override="$TMP_ROOT/override/config.json"
  home_config="$home/.pi/agent/extensions/subagents/config.json"
  write_valid_config "$pi_config" pi/model low
  write_valid_config "$override" override/model high
  write_valid_config "$home_config" home/model medium

  out=$(PI_CODING_AGENT_DIR="$pi_root" FM_SUBAGENTS_CONFIG="$override" HOME="$home" \
    "$DISPATCH" resolve cheap w1)
  printf '%s' "$out" | jq -e --arg source "$pi_config" \
    '.source == $source and .model == "pi/model"' >/dev/null \
    || fail "PI_CODING_AGENT_DIR regular candidate did not take precedence"

  out=$(PI_CODING_AGENT_DIR="$TMP_ROOT/pi-missing" FM_SUBAGENTS_CONFIG="$override" HOME="$home" \
    "$DISPATCH" resolve cheap w1)
  printf '%s' "$out" | jq -e --arg source "$override" \
    '.source == $source and .model == "override/model"' >/dev/null \
    || fail "FM_SUBAGENTS_CONFIG did not act as the temporary override"

  out=$(PI_CODING_AGENT_DIR= FM_SUBAGENTS_CONFIG= HOME="$home" "$DISPATCH" resolve cheap w1)
  printf '%s' "$out" | jq -e --arg source "$home_config" \
    '.source == $source and .model == "home/model"' >/dev/null \
    || fail "HOME config was not used as the final fallback"

  set +e
  out=$(PI_CODING_AGENT_DIR= FM_SUBAGENTS_CONFIG=relative/config.json HOME="$home" \
    "$DISPATCH" list 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "relative explicit override"
  assert_contains "$out" 'FM_SUBAGENTS_CONFIG must be an absolute path' \
    "relative explicit override did not fail actionably"

  set +e
  out=$(PI_CODING_AGENT_DIR= FM_SUBAGENTS_CONFIG="$TMP_ROOT/missing.json" HOME="$home" \
    "$DISPATCH" list 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "missing explicit override"
  assert_contains "$out" 'FM_SUBAGENTS_CONFIG is not a regular file' \
    "missing explicit override silently fell through to HOME"
  pass "Pi, explicit override, and HOME source precedence is deterministic and actionable"
}

test_secondmate_home_uses_pi_source_without_copying_config() {
  local secondmate="$TMP_ROOT/secondmate-home" pi_root="$TMP_ROOT/secondmate-pi-root"
  local pi_config="$TMP_ROOT/secondmate-pi-root/extensions/subagents/config.json"
  local override="$TMP_ROOT/secondmate-override.json" home="$TMP_ROOT/secondmate-user-home" out entries
  mkdir -p "$secondmate"
  printf '%s\n' secondmate > "$secondmate/.fm-secondmate-home"
  write_valid_config "$pi_config" pi/secondmate-source minimal
  write_valid_config "$override" override/secondmate-source high
  write_valid_config "$home/.pi/agent/extensions/subagents/config.json" home/secondmate-source medium

  out=$(FM_HOME="$secondmate" PI_CODING_AGENT_DIR="$pi_root" FM_SUBAGENTS_CONFIG="$override" HOME="$home" \
    "$DISPATCH" resolve cheap w1)
  printf '%s' "$out" | jq -e --arg source "$pi_config" \
    '.source == $source and .model == "pi/secondmate-source" and .effort == "minimal"' >/dev/null \
    || fail "fake secondmate home did not resolve the Pi source independently of FM_HOME"
  entries=$(ls -A "$secondmate")
  [ "$entries" = .fm-secondmate-home ] \
    || fail "public helper copied config or model data into the fake secondmate home: $entries"
  pass "fake secondmate homes resolve PI_CODING_AGENT_DIR without copied config or model data"
}

test_malformed_and_exact_schema_rejections() {
  local malformed="$TMP_ROOT/invalid/malformed.json" missing_tier="$TMP_ROOT/invalid/missing-tier.json"
  local duplicate="$TMP_ROOT/invalid/duplicate.json" empty="$TMP_ROOT/invalid/empty.json"
  local thinking="$TMP_ROOT/invalid/thinking.json" model="$TMP_ROOT/invalid/model.json"
  local line_model="$TMP_ROOT/invalid/line-model.json" nul="$TMP_ROOT/invalid/nul.json" temp
  mkdir -p "$TMP_ROOT/invalid"
  printf '{not json\n' >"$malformed"
  expect_invalid "$malformed" 'malformed JSON'

  printf '{"maxConcurrency":3,"modelTiers":\0{}}\n' >"$nul"
  expect_invalid "$nul" 'malformed JSON'

  write_valid_config "$missing_tier"
  temp="$TMP_ROOT/invalid/temp.json"
  jq 'del(.modelTiers.strong)' "$missing_tier" >"$temp" && mv "$temp" "$missing_tier"
  expect_invalid "$missing_tier" 'modelTiers must contain exactly cheap, balanced, strong'

  write_valid_config "$duplicate"
  jq '.modelTiers.cheap.workloads[1].key = "w1"' "$duplicate" >"$temp" && mv "$temp" "$duplicate"
  expect_invalid "$duplicate" 'workload keys must be unique within the tier'

  write_valid_config "$empty"
  jq '.modelTiers.balanced.workloads = []' "$empty" >"$temp" && mv "$temp" "$empty"
  expect_invalid "$empty" 'modelTiers.balanced.workloads must be nonempty'

  write_valid_config "$thinking" vendor/model impossible
  expect_invalid "$thinking" 'workload thinkingLevel is unsupported'

  write_valid_config "$model" 'vendor /model' low
  expect_invalid "$model" 'workload model must match'

  write_valid_config "$line_model"
  jq '.modelTiers.cheap.workloads[0].model = "vendor/a\rb"' "$line_model" >"$temp" && mv "$temp" "$line_model"
  expect_invalid "$line_model" 'workload model must match'
  pass "malformed JSON including NUL bytes and exact-schema violations are rejected with concrete diagnostics"
}

test_unknown_resolution_and_absent_source() {
  local config="$TMP_ROOT/resolution/config.json" out rc empty_home="$TMP_ROOT/empty-home"
  write_valid_config "$config"
  set +e
  out=$(run_override "$config" resolve cheap w404 2>&1)
  rc=$?
  set -e
  expect_code 5 "$rc" "unknown workload"
  assert_contains "$out" "unknown workload 'w404' in tier 'cheap'" \
    "unknown workload did not identify its tier and key"

  set +e
  out=$(run_override "$config" resolve impossible w1 2>&1)
  rc=$?
  set -e
  expect_code 5 "$rc" "unknown tier"
  assert_contains "$out" "unknown tier 'impossible'" "unknown tier was not actionable"

  mkdir -p "$empty_home"
  set +e
  out=$(PI_CODING_AGENT_DIR="$TMP_ROOT/no-pi" FM_SUBAGENTS_CONFIG= HOME="$empty_home" \
    "$DISPATCH" list 2>&1)
  rc=$?
  set -e
  expect_code 4 "$rc" "absent source"
  assert_contains "$out" 'SOURCE_ABSENT:' "absent source did not emit its observable diagnostic"
  pass "unknown routes and absent source use documented distinct failures"
}

test_fixture_resolution_and_list_json
test_optional_concurrency_and_extension_model_shape
test_live_edit_is_seen_on_next_call
test_source_precedence_and_fallbacks
test_secondmate_home_uses_pi_source_without_copying_config
test_malformed_and_exact_schema_rejections
test_unknown_resolution_and_absent_source

echo '# all fm-subagent-dispatch tests passed'
