#!/usr/bin/env bash
# Behavior tests for fm-model-tier.sh and dynamic tier resolution.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

MODEL_TIER="$ROOT/bin/fm-model-tier.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-tier)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/codex-home"
  cat > "$home/codex-home/models_cache.json" <<'JSON'
{
  "models": [
    {
      "slug": "gpt-6-astra",
      "priority": 1,
      "description": "Frontier flagship model",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "max"}]
    },
    {
      "slug": "gpt-5.5",
      "priority": 2,
      "description": "Workhorse model",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}]
    }
  ]
}
JSON
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r _case_dir HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_ship_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" CODEX_HOME="$home/codex-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

# 1. Tier resolves to newest ID across harnesses
test_tier_resolves_to_newest_model_codex() {
  local codex_home="$TMP_ROOT/codex-test-1"
  mkdir -p "$codex_home"
  cat > "$codex_home/models_cache.json" <<'JSON'
{
  "models": [
    {
      "slug": "gpt-6-astra",
      "priority": 1,
      "description": "Frontier flagship model",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "max"}]
    },
    {
      "slug": "gpt-5-frontier",
      "priority": 2,
      "description": "Previous frontier model",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}]
    },
    {
      "slug": "gpt-6.1-sol",
      "priority": 1,
      "description": "Newest workhorse model",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}]
    },
    {
      "slug": "gpt-6-sol",
      "priority": 2,
      "description": "Previous workhorse model",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}]
    },
    {
      "slug": "gpt-6-luna",
      "priority": 1,
      "description": "Newest fast model",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "max"}]
    }
  ]
}
JSON

  local strong standard fast
  strong=$(CODEX_HOME="$codex_home" "$MODEL_TIER" resolve codex strong)
  assert_equals "gpt-6-astra" "$strong" "codex strong tier should resolve to gpt-6-astra"

  standard=$(CODEX_HOME="$codex_home" "$MODEL_TIER" resolve codex standard)
  assert_equals "gpt-6.1-sol" "$standard" "codex standard tier should resolve to gpt-6.1-sol"

  fast=$(CODEX_HOME="$codex_home" "$MODEL_TIER" resolve codex fast)
  assert_equals "gpt-6-luna" "$fast" "codex fast tier should resolve to gpt-6-luna"

  pass "tier resolves to newest id in codex catalog"
}

test_codex_generation_beats_catalog_order() {
  local home="$TMP_ROOT/codex-generation" tier family resolved
  mkdir -p "$home"
  for tier in strong standard fast; do
    case "$tier" in
    strong) family=astra ;;
    standard) family=sol ;;
    fast) family=luna ;;
    esac
    jq -n --arg family "$family" '
      {models: [
        {slug: ("gpt-9-" + $family), priority: 0},
        {slug: ("gpt-10-" + $family), priority: 1},
        {slug: ("gpt-10.1-" + $family), priority: 99}
      ]}
    ' > "$home/models_cache.json"
    resolved=$(CODEX_HOME="$home" "$MODEL_TIER" resolve codex "$tier")
    assert_equals "gpt-10.1-$family" "$resolved" "codex $tier ranks numeric generation before order or priority"
  done
  pass "codex generations outrank catalog order"
}

test_new_top_model_picked_up_with_no_config_edit() {
  local codex_home="$TMP_ROOT/codex-test-2"
  mkdir -p "$codex_home"
  cat > "$codex_home/models_cache.json" <<'JSON'
{
  "models": [
    {
      "slug": "gpt-6-astra",
      "priority": 1,
      "description": "Frontier flagship model"
    }
  ]
}
JSON

  local initial
  initial=$(CODEX_HOME="$codex_home" "$MODEL_TIER" resolve codex strong)
  assert_equals "gpt-6-astra" "$initial" "initial strong tier is gpt-6-astra"

  # Now a new model arrives in the catalog with priority 0 (higher than 1)
  cat > "$codex_home/models_cache.json" <<'JSON'
{
  "models": [
    {
      "slug": "gpt-7-astra",
      "priority": 0,
      "description": "Next generation frontier flagship model"
    },
    {
      "slug": "gpt-6-astra",
      "priority": 1,
      "description": "Frontier flagship model"
    }
  ]
}
JSON

  local updated
  updated=$(CODEX_HOME="$codex_home" "$MODEL_TIER" resolve codex strong)
  assert_equals "gpt-7-astra" "$updated" "new top model is picked up with no config edit"

  pass "new top model is picked up with no config edit"
}

test_tier_resolves_claude_floating_aliases() {
  local fakebin="$TMP_ROOT/fake-claude"
  mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/claude"

  local strong standard fast
  strong=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve claude strong)
  assert_equals "opus" "$strong" "claude strong resolves to opus"

  standard=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve claude standard)
  assert_equals "sonnet" "$standard" "claude standard resolves to sonnet"

  fast=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve claude fast)
  assert_equals "haiku" "$fast" "claude fast resolves to haiku"

  pass "claude resolves to floating aliases opus/sonnet/haiku"
}

test_tier_resolves_agy_live_listing() {
  local fakebin="$TMP_ROOT/fake-agy"
  mkdir -p "$fakebin"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then
  cat <<'EOF'
gemini-3.9-pro-high
gemini-3.9-pro-medium
gemini-3.9-flash-high
gemini-3.9-flash-low
gemini-3.9-flash-lite-high
gemini-3.10-pro-high
gemini-3.10-pro-medium
gemini-3.10-flash-high
gemini-3.10-flash-low
gemini-3.10-flash-lite-high
EOF
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/agy"

  local strong standard fast
  strong=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve agy strong high)
  assert_equals "gemini-3.10-pro-high" "$strong" "agy strong selects the newer generation listed last"

  standard=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve agy standard high)
  assert_equals "gemini-3.10-flash-high" "$standard" "agy standard selects the newer generation listed last"

  standard=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve agy standard low)
  assert_equals "gemini-3.10-flash-low" "$standard" "standard preserves requested low effort"

  fast=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve agy fast high)
  assert_equals "gemini-3.10-flash-lite-high" "$fast" "agy fast selects the newer generation listed last"

  pass "agy tier resolves from live models listing"
}

test_tier_resolves_kimi_live_catalog() {
  local fakebin="$TMP_ROOT/fake-kimi"
  mkdir -p "$fakebin"
  cat > "$fakebin/kimi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "provider" ] && [ "${2:-}" = "list" ]; then
  cat <<'JSON'
{
  "models": {
    "kimi-code/k3": {
      "maxContextSize": 1048576
    },
    "kimi-code/k3-256k": {
      "maxContextSize": 262144
    },
    "kimi-code/kimi-for-coding": {
      "maxContextSize": 262144
    }
  }
}
JSON
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/kimi"

  local strong standard
  strong=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve kimi strong)
  assert_equals "kimi-code/k3" "$strong" "kimi strong resolves to the unqualified k3 model"

  standard=$(PATH="$fakebin:$PATH" "$MODEL_TIER" resolve kimi standard)
  assert_equals "kimi-code/kimi-for-coding" "$standard" "kimi standard resolves to kimi-for-coding"

  pass "kimi tier resolves from live provider catalog"
}

test_kimi_tiers_prefer_newer_generation() {
  local fakebin="$TMP_ROOT/fake-kimi-generation"
  mkdir -p "$fakebin"
  cat > "$fakebin/kimi" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "provider list --json" ]; then
  cat "$KIMI_TEST_CATALOG"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/kimi"

  local tier suffix generation context resolved catalog="$fakebin/catalog.json"
  for tier in strong standard fast; do
    case "$tier" in
    strong) suffix= ;;
    standard) suffix=-standard ;;
    fast) suffix=-fast ;;
    esac
    for generation in 4 10; do
      for context in 1048576 262144; do
        jq -n --arg older "kimi-code/k3$suffix" --arg newer "kimi-code/k$generation$suffix" --argjson context "$context" '
        {models: {
          ($older): {maxContextSize: 1048576},
          ($newer): {maxContextSize: $context}
        }}
        ' > "$catalog"
        resolved=$(KIMI_BIN="$fakebin/kimi" KIMI_TEST_CATALOG="$catalog" "$MODEL_TIER" resolve kimi "$tier")
        assert_equals "kimi-code/k$generation$suffix" "$resolved" "$tier generation $generation wins with context $context"
      done
    done
  done

  pass "kimi tiers prefer newer generations over context size"
}

test_unreachable_discovery_refuses() {
  local out status

  # Codex cache missing
  out=$(CODEX_HOME="$TMP_ROOT/nonexistent" "$MODEL_TIER" resolve codex strong 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "codex with missing cache should fail"
  assert_contains "$out" "codex model discovery is unreachable" "missing cache is named"

  # Agy failing
  local fakebin_fail="$TMP_ROOT/fake-fail"
  mkdir -p "$fakebin_fail"
  cat > "$fakebin_fail/agy" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin_fail/agy"

  out=$(PATH="$fakebin_fail:$PATH" "$MODEL_TIER" resolve agy strong 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "failing agy should fail"
  assert_contains "$out" "agy model discovery is unreachable" "failing agy is named"

  # Claude missing from PATH
  local no_claude_bin="$TMP_ROOT/no-claude-bin"
  mkdir -p "$no_claude_bin"
  for cmd in bash dirname jq grep awk sed cut tr head mktemp rm; do
    local p
    p=$(command -v "$cmd" || true)
    [ -n "$p" ] && ln -s "$p" "$no_claude_bin/$cmd"
  done
  out=$(PATH="$no_claude_bin" "$MODEL_TIER" resolve claude strong 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "missing claude on PATH should fail"
  assert_contains "$out" "claude model discovery is unreachable" "missing claude is named"

  pass "unreachable discovery refuses with concrete diagnostic"
}

test_legacy_model_profile_still_launches() {
  local rec id out status launch
  id='tier-legacy-z1'
  rec=$(make_spawn_case tier-legacy codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5.5 --effort high)
  status=$?
  expect_code 0 "$status" "legacy model profile launch should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5.5' -c 'model_reasoning_effort=\"high\"'" \
    "legacy launch did not preserve model and effort"
  assert_grep "model=gpt-5.5" "$HOME_DIR/state/$id.meta" "meta missing model=gpt-5.5"

  pass "legacy model profile still launches"
}

test_tier_profile_launches_resolved_model() {
  local rec id out status launch
  id='tier-spawn-z2'
  rec=$(make_spawn_case tier-spawn codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --tier strong --effort max)
  status=$?
  expect_code 0 "$status" "tier profile launch should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-6-astra' -c 'model_reasoning_effort=\"max\"'" \
    "tier launch did not resolve strong tier to gpt-6-astra with max effort"
  assert_grep "tier=strong" "$HOME_DIR/state/$id.meta" "meta missing tier=strong"
  assert_grep "model=gpt-6-astra" "$HOME_DIR/state/$id.meta" "meta missing model=gpt-6-astra"

  pass "tier profile resolves model and launches"
}

test_catalog_derived_effort_support() {
  local codex_home="$TMP_ROOT/codex-catalog"
  mkdir -p "$codex_home"
  cat > "$codex_home/models_cache.json" <<'JSON'
{
  "models": [
    {
      "slug": "gpt-6-astra",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "max"}]
    },
    {
      "slug": "gpt-5-frontier",
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}]
    }
  ]
}
JSON

  local max_models
  max_models=$(CODEX_HOME="$codex_home" "$MODEL_TIER" max-models codex)
  assert_contains "$max_models" "gpt-6-astra" "max-models includes gpt-6-astra"
  assert_not_contains "$max_models" "gpt-5-frontier" "max-models omits gpt-5-frontier"

  CODEX_HOME="$codex_home" "$MODEL_TIER" supports-effort codex gpt-6-astra max
  assert_equals 0 $? "gpt-6-astra supports max"

  CODEX_HOME="$codex_home" "$MODEL_TIER" supports-effort codex gpt-5-frontier max 2>/dev/null
  assert_equals 1 $? "gpt-5-frontier does not support max"

  pass "effort support is derived from catalog"
}

test_max_capabilities_agree_for_legacy_model() {
  local codex_home="$TMP_ROOT/codex-legacy-max" scenario max_models rc expected
  mkdir -p "$codex_home"
  for scenario in missing malformed omitted unsupported supported; do
    expected=1
    case "$scenario" in
    missing) rm -f "$codex_home/models_cache.json" ;;
    malformed) printf '%s\n' '{' > "$codex_home/models_cache.json" ;;
    omitted) printf '%s\n' '{"models":[]}' > "$codex_home/models_cache.json" ;;
    unsupported) printf '%s\n' '{"models":[{"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"high"}]}]}' > "$codex_home/models_cache.json" ;;
    supported)
      printf '%s\n' '{"models":[{"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"max"}]}]}' > "$codex_home/models_cache.json"
      expected=0
      ;;
    esac
    max_models=$(CODEX_HOME="$codex_home" "$MODEL_TIER" max-models codex)
    rc=0
    jq -e 'index("gpt-5.6-luna") != null' <<<"$max_models" >/dev/null || rc=$?
    expect_code "$expected" "$rc" "$scenario catalog dispatch max eligibility"
    rc=0
    CODEX_HOME="$codex_home" "$MODEL_TIER" supports-effort codex gpt-5.6-luna max || rc=$?
    expect_code "$expected" "$rc" "$scenario catalog launch max capability"
  done
  pass "legacy max eligibility and launch capability agree"
}

test_tier_refuses_unsupported_resolved_effort() {
  local rec out rc
  rec=$(make_spawn_case unsupported-tier codex tier-effort)
  read_case_record "$rec"
  printf '%s\n' '{"models":[{"slug":"gpt-9-astra","description":"Frontier","supported_reasoning_levels":[{"effort":"high"}]}]}' > "$HOME_DIR/codex-home/models_cache.json"
  rc=0
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" tier-effort "$PROJ_DIR" --harness codex --tier strong --effort max) || rc=$?
  expect_code 1 "$rc" "unsupported resolved effort must refuse: $out"
  [ ! -s "$LAUNCH_LOG" ] || fail "unsupported tier effort reached launch"
  assert_absent "$HOME_DIR/state/tier-effort.meta" "unsupported tier effort published metadata"
  pass "tier effort validation follows discovery"
}

test_hidden_models_are_not_tier_candidates() {
  local home="$TMP_ROOT/hidden-models" tier out rc
  mkdir -p "$home"
  printf '%s\n' '{"models":[{"slug":"gpt-6-astra","visibility":"hide"},{"slug":"gpt-6-sol","visibility":"hide"},{"slug":"gpt-6-luna","visibility":"hide"}]}' > "$home/models_cache.json"
  for tier in strong standard fast; do
    rc=0
    out=$(CODEX_HOME="$home" "$MODEL_TIER" resolve codex "$tier" 2>&1) || rc=$?
    expect_code 1 "$rc" "hidden $tier model must be refused"
    assert_contains "$out" "no candidate for tier '$tier'" "missing candidate diagnostic"
  done
  pass "hidden models cannot satisfy any tier"
}

test_tier_resolves_to_newest_model_codex
test_codex_generation_beats_catalog_order
test_new_top_model_picked_up_with_no_config_edit
test_tier_resolves_claude_floating_aliases
test_tier_resolves_agy_live_listing
test_tier_resolves_kimi_live_catalog
test_kimi_tiers_prefer_newer_generation
test_unreachable_discovery_refuses
test_legacy_model_profile_still_launches
test_tier_profile_launches_resolved_model
test_catalog_derived_effort_support
test_max_capabilities_agree_for_legacy_model
test_hidden_models_are_not_tier_candidates
test_tier_refuses_unsupported_resolved_effort

echo "# all fm-model-tier tests passed"
