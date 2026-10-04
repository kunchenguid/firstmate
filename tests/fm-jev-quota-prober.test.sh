#!/usr/bin/env bash
# tests/fm-jev-quota-prober.test.sh - quota-axi is the Jev quota prober's only
# verdict source: inverted local verdicts lose, an exhausted divert target
# is never selected, and an unmeasurable lane launches as requested, loudly,
# and never diverts.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBER="$ROOT/bin/fm-jev-quota-prober.sh"
TMP=$(fm_test_tmproot fm-jev-quota-prober)

# row <provider> <percent|stale:<pct>|unset> [credits]: one quota-axi --json provider row.
row() {
  local provider=$1 spec=$2 credits=${3:-1}
  case "$spec" in
    stale:*)
      jq -n --arg p "$provider" --argjson pct "${spec#stale:}" --argjson c "$credits" '{
        provider: $p, windows: [{id: "weekly", percentRemaining: $pct}],
        state: {status: "stale", stale: true, error: "Codex quota unavailable"},
        credits: {remaining: $c},
        quotaSemantics: {status: "unknown", effectiveAvailability: [
          {scope: "all_models", status: "unknown", runway: {status: "unknown"}}]}}' ;;
    unset)
      jq -n --arg p "$provider" '{provider: $p, windows: [], notSetUp: true,
        state: {status: "auth_required", stale: false, error: "credential_unavailable"},
        quotaSemantics: {status: "unknown", effectiveAvailability: []}}' ;;
    *)
      jq -n --arg p "$provider" --argjson pct "$spec" --argjson c "$credits" '{
        provider: $p, windows: [{id: "monthly", percentRemaining: $pct}],
        state: {status: "fresh", stale: false}, credits: {remaining: $c},
        quotaSemantics: {status: "known", effectiveAvailability: [
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
           runway: {status: (if $pct == 0 then "exhausted_now" else "through_reset" end)}}]}}' ;;
  esac
}

# snapshot <file> <row-json>...: a quota-axi schema 5 --json document.
snapshot() {
  local file=$1
  shift
  printf '%s\n' "$@" | jq -s '{schemaVersion: 5, providers: .}' > "$file"
}

# probe <snapshot> <args...>: runs the prober; sets OUT, ERR, RC.
probe() {
  local snap=$1
  shift
  RC=0
  FM_TEST_SEAM=1 FM_TEST_QUOTA_SNAPSHOT="$snap" FM_HOME="$TMP/home" \
    "$PROBER" "$@" > "$TMP/out" 2> "$TMP/err" || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

test_inverted_codex_verdict_quota_axi_wins() {
  # The old prober's own signals called codex dead (stale credential, zero credits)
  # while quota-axi still reports 89% of the weekly window.
  snapshot "$TMP/inverted.json" "$(row codex stale:89 0)" "$(row opencode-go 0)"
  probe "$TMP/inverted.json" --harness codex --model gpt-5.6-luna --auto-divert
  expect_code 0 "$RC" "codex at 89% in quota-axi"
  assert_equals "healthy codex gpt-5.6-luna" "$OUT" "quota-axi's healthy verdict wins over the prober's dead signal"
  pass "inverted codex verdict: quota-axi 89% wins"
}

test_inverted_opencode_go_verdict_quota_axi_wins() {
  # The old prober had no opencode-go check and called it alive at 0%.
  snapshot "$TMP/og.json" "$(row opencode-go 0)"
  probe "$TMP/og.json" --harness pi --model opencode-go/glm-5.3-flash
  expect_code 1 "$RC" "opencode-go at 0% in quota-axi"
  assert_equals "exhausted pi opencode-go/glm-5.3-flash" "$OUT" "quota-axi's exhausted verdict wins"
  pass "inverted opencode-go verdict: quota-axi 0% is exhausted"
}

test_exhausted_divert_target_never_selected() {
  snapshot "$TMP/both-dry.json" "$(row codex 0)" "$(row opencode-go 0)"
  probe "$TMP/both-dry.json" --harness codex --model gpt-5.6-luna --auto-divert
  expect_code 1 "$RC" "exhausted lane with only an exhausted divert target"
  assert_equals "exhausted codex gpt-5.6-luna" "$OUT" "no divert line is printed"
  assert_not_contains "$OUT" "diverted" "the exhausted opencode-go lane is not selected"
  assert_contains "$ERR" "no divert lane is healthy in quota-axi" "the refusal is named"

  # Positive control: the same lane diverts once quota-axi reports it healthy.
  snapshot "$TMP/og-ok.json" "$(row codex 0)" "$(row opencode-go 40)"
  probe "$TMP/og-ok.json" --harness codex --model gpt-5.6-luna --auto-divert
  expect_code 0 "$RC" "healthy divert target"
  assert_equals "diverted pi opencode-go/glm-5.3-flash" "$OUT" "healthy divert target is selected"

  # Selection skips exhausted and stale lanes even when they are listed first.
  snapshot "$TMP/mixed.json" "$(row codex 0)" "$(row opencode-go 0)" "$(row zai stale:50)" "$(row kimi 30)"
  RC=0
  FM_TEST_SEAM=1 FM_TEST_QUOTA_SNAPSHOT="$TMP/mixed.json" python3 - "$ROOT/bin/fm-jev-quota-prober.py" <<'EOF' > "$TMP/out" 2>&1 || RC=$?
import importlib.util, sys
spec = importlib.util.spec_from_file_location("prober", sys.argv[1])
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
p.DIVERT_LANES = (("pi", "opencode-go/glm-5.3-flash"), ("pi", "zai/glm-5"), ("kimi", "k3"))
assert p.select_divert(("codex", "gpt-5.6-luna")) == ("kimi", "k3"), p.select_divert(("codex", "gpt-5.6-luna"))
p.DIVERT_LANES = (("pi", "opencode-go/glm-5.3-flash"), ("pi", "zai/glm-5"))
assert p.select_divert(("codex", "gpt-5.6-luna")) is None
EOF
  expect_code 0 "$RC" "divert selection check: $(cat "$TMP/out")"
  pass "exhausted or stale divert target is never selected"
}

test_unknown_is_permissive_and_loud() {
  snapshot "$TMP/unset.json" "$(row devin unset)" "$(row opencode-go 90)"
  probe "$TMP/unset.json" --harness devin --auto-divert
  expect_code 0 "$RC" "not-set-up provider"
  assert_equals "unknown devin" "$OUT" "unknown verdict, not a divert"
  assert_contains "$ERR" "jev-quota-prober: quota-axi verdict unavailable for devin:-: " "the unknown verdict is named"
  assert_contains "$ERR" "; launching as requested" "the permissive launch is named"

  probe "$TMP/unset.json" --harness claude --model opus --auto-divert
  expect_code 0 "$RC" "provider missing from quota-axi output"
  assert_equals "unknown claude opus" "$OUT" "missing row is unknown, not a divert"
  assert_contains "$ERR" "quota-axi has no claude row" "missing row is named"

  RC=0
  env -u FM_TEST_SEAM PATH="$(fm_test_base_path_sans "/usr/bin:/bin" quota-axi)" \
    "$PROBER" --harness codex --auto-divert > "$TMP/out" 2> "$TMP/err" || RC=$?
  expect_code 0 "$RC" "quota-axi absent"
  assert_equals "unknown codex" "$(cat "$TMP/out")" "absent quota-axi is unknown, not a divert"
  assert_contains "$(cat "$TMP/err")" "quota-axi is not installed" "absent quota-axi is named"
  pass "unmeasurable lanes launch as requested with a loud named diagnostic and never divert"
}

test_null_quota_fields_are_unknown() {
  jq -n '{schemaVersion: 5, providers: [{provider: "codex", windows: null, state: null,
    quotaSemantics: {status: "unknown", effectiveAvailability: null}}]}' > "$TMP/null-fields.json"
  probe "$TMP/null-fields.json" --harness codex --model gpt-5.6-luna --auto-divert
  expect_code 0 "$RC" "null windows and effectiveAvailability"
  assert_equals "unknown codex gpt-5.6-luna" "$OUT" "null fields are unknown"
  assert_contains "$ERR" "quota-axi verdict unavailable for codex:gpt-5.6-luna: " "the unknown verdict is named"
  assert_not_contains "$ERR" "Traceback" "null fields do not crash the prober"

  jq -n '{schemaVersion: 5, providers: null}' > "$TMP/null-providers.json"
  probe "$TMP/null-providers.json" --harness codex --model gpt-5.6-luna --auto-divert
  expect_code 0 "$RC" "null providers"
  assert_equals "unknown codex gpt-5.6-luna" "$OUT" "null providers is unknown"
  assert_contains "$ERR" "quota-axi has no codex row" "the missing row is named"
  assert_not_contains "$ERR" "Traceback" "null providers does not crash the prober"
  pass "null quota-axi fields resolve to unknown without a traceback"
}

test_unmetered_harness_launches_as_requested() {
  snapshot "$TMP/empty.json"
  probe "$TMP/empty.json" --harness rovo --auto-divert
  expect_code 0 "$RC" "harness with no quota-axi provider"
  assert_equals "unmetered rovo" "$OUT" "unmetered verdict"
  pass "a harness quota-axi does not measure launches as requested"
}

test_inverted_codex_verdict_quota_axi_wins
test_inverted_opencode_go_verdict_quota_axi_wins
test_exhausted_divert_target_never_selected
test_unknown_is_permissive_and_loud
test_null_quota_fields_are_unknown
test_unmetered_harness_launches_as_requested
