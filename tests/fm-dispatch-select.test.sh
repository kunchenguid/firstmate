#!/usr/bin/env bash
# Behavior tests for quota-aware crew-dispatch profile selection.
#
# End-user reproduction before the fix:
# - Initiating input: a non-empty profile array in rule use or top-level default.
# - Expected: startup accepts both locations and dispatch consults quota-axi.
# - Observed: startup rejected a default array, while a rule array without
#   select silently chose its first element without calling quota-axi.
# - Masking condition: a single profile object worked, and an explicit
#   quota-balanced rule array took the quota path.
# - Visible symptom: an actionable-looking startup invalid-config line for a
#   valid default array, or first-profile dispatch despite better usable quota.
# - Earliest divergence: bootstrap restricted default to object while use had an
#   array normalizer; selector gated quota lookup on explicit select rather than
#   the already-normalized input being an array.
# - History: 7a42707 added rule arrays and explicit quota-balanced selection;
#   8cd90fe moved the contract owner without changing that asymmetric behavior.
# - Smallest counterfactual: adding select changed a rule array to quota-aware
#   selection but could not make the same array valid under default.
# - Disconfirming evidence: object defaults, object rule uses, and explicit
#   quota-balanced rule arrays all followed their proven paths successfully.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-dispatch-select-tests)
mkdir -p "$TMP_ROOT"
RANDOM_ZERO="$TMP_ROOT/random-zero"
RANDOM_ONE="$TMP_ROOT/random-one"
printf '\000\000\000\000' > "$RANDOM_ZERO"
printf '\001\001\001\001' > "$RANDOM_ONE"

write_quota() {
  local file=$1 claude_status=$2 claude_five=$3 claude_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "$claude_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_five },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": $claude_week },
        { "id": "model:fable", "label": "Fable week", "kind": "model", "percentRemaining": 100 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week },
        { "id": "model:codex_bengalfox:5h", "label": "GPT-5.3-Codex-Spark session", "kind": "model", "percentRemaining": 100 }
      ]
    }
  ]
}
JSON
}

profiles='[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'

assert_profile() {
  local actual=$1 expected=$2 message=$3
  [ "$actual" = "$expected" ] || fail "$message, got: $actual"
}

test_implicit_array_picks_higher_min_provider() {
  local quota out err
  quota="$TMP_ROOT/higher.json"
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/higher.err")
  err=$(cat "$TMP_ROOT/higher.err")
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "higher-min provider should win"
  assert_contains "$err" "selection basis: quota-selected" "quota selection basis was not exposed"
  pass "every profile array implicitly picks the least constrained scorable provider"
}

test_rule_array_without_select_invokes_quota_axi() {
  local fakebin marker out rule
  fakebin=$(fm_fakebin "$TMP_ROOT/implicit-command")
  marker="$TMP_ROOT/implicit-command/called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$marker'
cat <<'JSON'
{"schemaVersion":2,"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":10}]},{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90}]}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  rule='{"when":"big work","use":[{"harness":"claude"},{"harness":"codex"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" "$rule" 2>/dev/null)
  assert_profile "$out" '{"harness":"codex"}' "implicit rule array should use quota data"
  assert_contains "$(cat "$marker")" "--json" "implicit array did not invoke quota-axi --json"
  pass "rule arrays need no select property to invoke installed quota-axi"
}

test_legacy_explicit_selector_stays_compatible() {
  local quota out
  quota="$TMP_ROOT/legacy.json"
  write_quota "$quota" fresh 90 80 fresh 70 60
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' "legacy explicit selector changed behavior"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '{"when":"big work","use":[{"harness":"claude"},{"harness":"codex"}],"select":"quota-balanced"}' 2>/dev/null)
  assert_profile "$out" '{"harness":"claude"}' "legacy rule selector changed behavior"
  pass "legacy select quota-balanced forms remain compatible"
}

test_equal_winners_use_os_random_tie_break() {
  local quota first second
  quota="$TMP_ROOT/tie.json"
  write_quota "$quota" fresh 90 50 fresh 60 50
  first=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  second=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$first" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' "zero random fixture should choose first tie winner"
  assert_profile "$second" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "nonzero random fixture should choose second tie winner"
  pass "equal quota winners use the OS-backed random tie-break"
}

test_provider_and_product_mapping_through_wrappers() {
  local quota out
  quota="$TMP_ROOT/routes.json"
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":45},{"id":"seven_day","kind":"weekly","percentRemaining":40}]},
    {"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":55},{"id":"weekly","kind":"weekly","percentRemaining":50}]},
    {"provider":"grok","state":{"status":"fresh"},"windows":[
      {"id":"credits","kind":"credits","percentRemaining":1},
      {"id":"product:api","kind":"credits","percentRemaining":75},
      {"id":"product:grok_build","kind":"credits","percentRemaining":25}
    ]}
  ]
}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"claude"},{"harness":"pi","model":"openai-codex/gpt-5.5"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"pi","model":"openai-codex/gpt-5.5"}' "Pi OpenAI Codex route was not scored as Codex"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"pi","model":"anthropic/claude-sonnet-5"},{"harness":"codex"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"codex"}' "Pi Anthropic route was not scored as Claude"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"pi","model":"xai/grok-4.5"},{"harness":"grok","model":"grok-4.5"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"pi","model":"xai/grok-4.5"}' "Pi xAI API should use product:api rather than Grok Build or aggregate credits"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"grok"},{"harness":"claude"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"claude"}' "direct Grok should use product:grok_build"
  pass "direct and Pi-wrapped candidates map to consumed Claude, Codex, xAI API, and Grok Build quota"
}

test_most_constrained_relevant_window_scores_candidate() {
  local quota out
  quota="$TMP_ROOT/scoped.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":90},
    {"id":"seven_day","kind":"weekly","percentRemaining":80},
    {"id":"model:fable","label":"Fable week","kind":"model","percentRemaining":5}
  ]},
  {"provider":"codex","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":30},
    {"id":"weekly","kind":"weekly","percentRemaining":30},
    {"id":"code_review_five_hour","label":"code review session","kind":"session","percentRemaining":1},
    {"id":"code_review_weekly","label":"code review week","kind":"weekly","percentRemaining":1},
    {"id":"model:other:5h","label":"Unrelated preview session","kind":"model","percentRemaining":1}
  ]}
]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"claude","model":"claude-fable-5"},{"harness":"codex","model":"gpt-5.5"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5"}' "matching model window was not included or unrelated model window was included"
  pass "candidate score uses its most constrained general or matching model quota window"
}

test_grok_aggregate_fallback_requires_no_product_windows() {
  local quota out
  quota="$TMP_ROOT/grok-partial-products.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[
  {"provider":"grok","state":{"status":"fresh"},"windows":[
    {"id":"credits","kind":"credits","percentRemaining":100},
    {"id":"product:grok_build","kind":"credits","percentRemaining":90}
  ]},
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":5},
    {"id":"seven_day","kind":"weekly","percentRemaining":5}
  ]}
]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"pi","model":"xai/grok-4.5"},{"harness":"claude"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"claude"}' "xAI API route used aggregate credits despite exposed product windows"
  pass "Grok aggregate credits are used only when product windows are absent"
}

test_stale_cache_needs_clear_margin_to_beat_fresh() {
  local quota out
  quota="$TMP_ROOT/stale-margin.json"
  write_quota "$quota" stale 85 70 fresh 65 60
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "fresh provider should win below stale margin"

  write_quota "$quota" stale 90 85 fresh 65 60
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' "stale provider should win after clearing margin"
  pass "stale cached quota retains the documented freshness margin"
}

test_partial_quota_data_prefers_scorable_candidate() {
  local quota out
  quota="$TMP_ROOT/partial.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":4}]}]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "unscorable first candidate beat usable Codex data"
  pass "partial quota data picks the best scorable candidate instead of an unscorable candidate"
}

assert_random_fallback_chooses_second() {
  local out_file=$1 err_file=$2
  shift 2
  FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" "$@" >"$out_file" 2>"$err_file"
  assert_profile "$(cat "$out_file")" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "random fallback fixture should choose the second candidate"
  assert_contains "$(cat "$err_file")" "selection basis: random fallback" "random fallback basis was not exposed"
}

test_operational_quota_failures_use_uniform_random_fallback() {
  local fakebin quota
  fakebin=$(fm_fakebin "$TMP_ROOT/missing")
  assert_random_fallback_chooses_second "$TMP_ROOT/missing.out" "$TMP_ROOT/missing.err" \
    env PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$profiles"
  assert_contains "$(cat "$TMP_ROOT/missing.err")" "quota-axi missing" "missing quota-axi reason was not logged"

  fakebin=$(fm_fakebin "$TMP_ROOT/error")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "$fakebin/quota-axi"
  assert_random_fallback_chooses_second "$TMP_ROOT/error.out" "$TMP_ROOT/error.err" \
    env PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$profiles"
  assert_contains "$(cat "$TMP_ROOT/error.err")" "quota-axi exited 42" "quota-axi error reason was not logged"

  quota="$TMP_ROOT/bad.json"
  printf '%s\n' not-json > "$quota"
  assert_random_fallback_chooses_second "$TMP_ROOT/bad.out" "$TMP_ROOT/bad.err" \
    "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles"
  assert_contains "$(cat "$TMP_ROOT/bad.err")" "unparseable JSON" "bad quota JSON reason was not logged"

  printf '%s\n' '{"schemaVersion":2,"providers":[]}' > "$quota"
  assert_random_fallback_chooses_second "$TMP_ROOT/empty.out" "$TMP_ROOT/empty.err" \
    "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles"
  assert_contains "$(cat "$TMP_ROOT/empty.err")" "no usable quota windows" "wholly unusable quota reason was not logged"
  pass "missing, failed, malformed, and wholly unusable quota data use OS-backed random fallback"
}

test_single_profile_and_one_element_array() {
  local fakebin marker out err
  fakebin=$(fm_fakebin "$TMP_ROOT/single")
  marker="$TMP_ROOT/single/called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" '{"harness":"grok","model":"grok-4.5","effort":"high"}' 2>/dev/null)
  assert_profile "$out" '{"harness":"grok","model":"grok-4.5","effort":"high"}' "single profile object should resolve to itself"
  [ ! -e "$marker" ] || fail "single profile object should not invoke quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" "$ROOT/bin/fm-dispatch-select.sh" \
    '[{"harness":"grok","model":"grok-4.5","effort":"high"}]' 2>"$TMP_ROOT/one.err")
  err=$(cat "$TMP_ROOT/one.err")
  assert_profile "$out" '{"harness":"grok","model":"grok-4.5","effort":"high"}' "one-element array should remain selectable"
  [ -e "$marker" ] || fail "one-element array should invoke quota-axi"
  assert_contains "$err" "selection basis: random fallback" "one-element operational fallback basis was not logged"
  pass "single objects remain backward compatible and one-element arrays remain quota-aware"
}

test_malformed_profile_arrays_are_validation_errors() {
  local body expect out status n
  n=0
  while IFS='^' read -r body expect; do
    n=$((n + 1))
    out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" "$ROOT/bin/fm-dispatch-select.sh" "$body" 2>&1)
    status=$?
    expect_code 2 "$status" "malformed profile array should exit 2"
    assert_contains "$out" "$expect" "malformed profile array did not explain validation error"
    assert_not_contains "$out" "random fallback" "malformed profile array incorrectly used operational fallback"
  done <<'ROWS'
[]^must not be empty
["claude"]^must be an object
[{"model":"claude-sonnet-5"}]^needs a non-empty harness
[{"harness":"claude","model":3}]^model must be a non-empty string
[{"harness":"spaceship"}]^contains an unverified harness
[{"harness":"codex","effort":"max"}]^contains an unsupported harness/effort pair
ROWS
  pass "malformed arrays stay actionable validation errors and never enter random fallback"
}

test_implicit_array_picks_higher_min_provider
test_rule_array_without_select_invokes_quota_axi
test_legacy_explicit_selector_stays_compatible
test_equal_winners_use_os_random_tie_break
test_provider_and_product_mapping_through_wrappers
test_most_constrained_relevant_window_scores_candidate
test_grok_aggregate_fallback_requires_no_product_windows
test_stale_cache_needs_clear_margin_to_beat_fresh
test_partial_quota_data_prefers_scorable_candidate
test_operational_quota_failures_use_uniform_random_fallback
test_single_profile_and_one_element_array
test_malformed_profile_arrays_are_validation_errors

echo "# all fm-dispatch-select tests passed"
