#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-account.sh pick: choosing which declared
# line of a config/claude-account pool a Claude spawn launches on.
#
# A stub quota-axi on PATH answers with fixture JSON shaped like quota-axi's
# schema-6 `--provider claude --full --json` output (per-account lanes, each
# with an accountLocator) and records the environment and arguments it was
# called with, so every case asserts on the helper's public output, exit
# status, and the one quota-axi call it makes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PICK="$ROOT/bin/fm-claude-account.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-account)
FAKEBIN="$TMP_ROOT/fakebin"
CFG="$TMP_ROOT/config"
FAKE_HOME="$TMP_ROOT/home"
WORK="$TMP_ROOT/claude-work"
MON="$TMP_ROOT/claude-monivio"
SNAPSHOT="$TMP_ROOT/snapshot.json"
CALLS="$TMP_ROOT/quota-calls"
mkdir -p "$FAKEBIN" "$CFG" "$FAKE_HOME/.claude" "$WORK" "$MON"

cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf 'CLAUDE_CONFIG_DIR=%s PROFILES=%s ARGS=%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_CLAUDE_PROFILES-unset}" "\$*" >> '$CALLS'
[ -f '$SNAPSHOT' ] || exit 1
cat '$SNAPSHOT'
SH
chmod +x "$FAKEBIN/quota-axi"

DEFAULT_STORE='Claude Code-credentials'

# lane <accountKey> <path> <keychainService> <all_models epr> <spendPriority> <runway> <resetsAt> [<model> <epr> <spendPriority> <runway>]
# Prints one schema-6 claude lane. An empty spendPriority publishes an
# unknown selection; `-` as the path omits the accountLocator entirely.
lane() {
  jq -n --arg key "$1" --arg path "$2" --arg kc "$3" --argjson epr "$4" --arg sp "$5" \
    --arg runway "$6" --arg reset "$7" --arg model "${8:-}" --arg mepr "${9:-0}" \
    --arg msp "${10:-}" --arg mrunway "${11:-}" '
    def sel($s): if $s == "" then {status: "unknown"} else {status: "known", spendPriority: ($s | tonumber)} end;
    {provider: "claude", accountKey: $key,
     state: {status: "fresh", stale: false},
     windows: [{id: "five_hour", resetsAt: $reset}, {id: "model:x", resetsAt: "2026-12-31T00:00:00Z"}],
     quotaSemantics: {status: "known", effectiveAvailability: (
       [{scope: "all_models", status: "known", effectivePercentRemaining: $epr, boundedBy: ["five_hour"],
         limitingWindowIds: ["five_hour"], runway: {status: $runway}, selection: sel($sp)}] +
       (if $model == "" then [] else
         [{scope: ("model:" + $model), status: "known", effectivePercentRemaining: ($mepr | tonumber),
           boundedBy: ["five_hour", "model:x"], limitingWindowIds: ["model:x"],
           runway: {status: $mrunway}, selection: sel($msp)}] end))}}
    + (if $path == "-" then {} else
        {accountLocator: ({kind: "config-dir", path: $path} + (if $kc == "" then {} else {keychainService: $kc} end))} end)'
}

# snapshot <schemaVersion> <lane-json>...
snapshot() {
  local schema=$1
  shift
  printf '%s\n' "$@" | jq -s --argjson schema "$schema" '{schemaVersion: $schema, providers: .}' > "$SNAPSHOT"
}

pool() {
  printf '%s\n' "$@" > "$CFG/claude-account"
}

# pick [args...]: run the helper from a caller whose own CLAUDE_CONFIG_DIR
# names another account, which quota-axi must never inherit.
pick() {
  : > "$CALLS"
  env HOME="$FAKE_HOME" PATH="$FAKEBIN:$PATH" FM_CONFIG_OVERRIDE="$CFG" \
    CLAUDE_CONFIG_DIR="$TMP_ROOT/ambient" "$PICK" pick "$@" 2>&1
}

test_two_measured_lanes_pick_the_highest_spend_priority() {
  local out rc
  pool ordinary "$WORK" "$MON"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 60 0.2 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 40 0.6 through_reset 2026-10-11T16:00:00Z)" \
    "$(lane profile:mon "$MON" "$DEFAULT_STORE-5e6f7a8b" 90 0.4 through_reset 2026-10-11T14:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a measured pool should yield a choice: $out"
  assert_contains "$out" "lane: ordinary accountKey=profile:home scope=all_models effectivePercentRemaining=60 spendPriority=0.2 runway=through_reset" \
    "the ordinary entry should carry its own lane's evidence"
  assert_contains "$out" "lane: $MON accountKey=profile:mon" "every declared entry should have an evidence line"
  assert_contains "$out" "basis: highest spendPriority 0.6" "the basis should name the ranking scalar"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the last line should name the highest spendPriority account"
  assert_equals 1 "$(wc -l < "$CALLS" | tr -d ' ')" "quota-axi should run exactly once"
  assert_equals "CLAUDE_CONFIG_DIR=unset PROFILES=$WORK:$MON ARGS=--provider claude --full --json" "$(cat "$CALLS")" \
    "quota-axi should run without the caller's CLAUDE_CONFIG_DIR and with every path entry as a profile"
  pass "pick ranks measured lanes by spendPriority and runs quota-axi once with the pool's paths"
}

test_model_scope_row_is_used_when_reported() {
  local out rc
  pool ordinary "$WORK"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 60 0.2 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 80 0.7 through_reset 2026-10-11T16:00:00Z \
      claude-opus-5 0 -1 exhausted_now)"
  out=$(pick --model claude-opus-5); rc=$?
  expect_code 0 "$rc" "a model-scoped pick should still choose: $out"
  assert_contains "$out" "lane: $WORK accountKey=profile:work scope=model:claude-opus-5 effectivePercentRemaining=0" \
    "the model's own scope should apply to the lane that reports it"
  assert_contains "$out" "lane: ordinary accountKey=profile:home scope=all_models" \
    "a lane without that model's scope should fall back to all_models"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "the model-exhausted lane must not be chosen"
  out=$(pick --model claude-sonnet-5); rc=$?
  expect_code 0 "$rc" "a pick for an unscoped model should choose: $out"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "an unscoped model should rank by all_models"
  pass "pick applies a lane's model scope when quota-axi reports one, else all_models"
}

test_exhausted_lane_is_skipped() {
  local out rc
  pool ordinary "$WORK"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 30 -0.4 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 0 0.9 exhausted_now 2026-10-11T16:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "one eligible lane should be chosen: $out"
  assert_contains "$out" "verdict=exhausted" "the exhausted lane should be reported as exhausted"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "an exhausted lane must never win on spendPriority"
  pass "pick skips an exhausted lane even when its spendPriority is higher"
}

test_all_exhausted_exits_distinctly() {
  local out rc
  pool ordinary "$WORK"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 0 -1 exhausted_now 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 0 -1 exhausted_now 2026-10-11T16:00:00Z)"
  out=$(pick); rc=$?
  expect_code 3 "$rc" "an all-exhausted pool should exit with the distinct exhausted status"
  assert_contains "$out" "every declared Claude account is measured and exhausted" "the exhaustion should be stated"
  assert_not_contains "$out" "account:" "no account may be named when every lane is exhausted"
  pool ordinary "$WORK" "$MON"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "an unmeasured account should remain choosable beside exhausted ones: $out"
  assert_contains "$out" "basis: UNMEASURED DEFAULT" "choosing an unmeasured account must be disclosed"
  assert_equals "account: $MON" "$(printf '%s\n' "$out" | tail -1)" "the first unmeasured line should be chosen over exhausted ones"
  pass "pick exits 3 when every declared account is exhausted, and otherwise discloses an unmeasured fallback"
}

test_unmeasured_pool_discloses_the_first_line_default() {
  local out rc
  pool "$WORK" ordinary
  snapshot 5 "$(lane x - "" 50 0.5 through_reset 2026-10-11T15:00:00Z | jq 'del(.accountKey)')"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "an old quota-axi should still yield the default: $out"
  assert_contains "$out" "accountKey=unmeasured" "an unmatched entry should be reported as unmeasured"
  assert_contains "$out" "no account lanes (schema 5)" "the old schema should be named as the reason"
  assert_contains "$out" "basis: UNMEASURED DEFAULT" "the default should be marked as unmeasured"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the unmeasured default is the first line"

  snapshot 6 "$(lane profile:a - "" 50 0.5 through_reset 2026-10-11T15:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "lanes without locators should still yield the default: $out"
  assert_contains "$out" "no quota-axi lane carries a locator for this account" "a missing locator should be named"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "a locator-less snapshot falls back to the first line"

  rm -f "$SNAPSHOT"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a failing quota-axi should still yield the default: $out"
  assert_contains "$out" "quota-axi printed no valid quota snapshot" "the failed read should be named"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "a failed read falls back to the first line"
  pass "pick discloses an unmeasured first-line default for old, locator-less, or failed quota-axi output"
}

test_ordinary_binds_only_the_unsuffixed_default_store() {
  local out rc
  pool ordinary "$WORK"
  # The decoy is ~/.claude selected explicitly through CLAUDE_CONFIG_DIR, which
  # Claude keys to a suffixed store: a different login than `ordinary`.
  snapshot 6 \
    "$(lane profile:decoy "$FAKE_HOME/.claude" "$DEFAULT_STORE-0f0f0f0f" 95 0.9 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 20 0.1 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T16:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "the pool should be measured: $out"
  assert_contains "$out" "lane: ordinary accountKey=profile:home" "ordinary should bind the unsuffixed default store"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the decoy's evidence must not be credited to ordinary"
  pass "pick binds ordinary to the unsuffixed Claude Code-credentials lane only"
}

test_ties_break_by_reset_then_pool_order() {
  local out rc
  pool ordinary "$WORK" "$MON"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 50 0.3 through_reset 2026-10-11T18:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:mon "$MON" "$DEFAULT_STORE-5e6f7a8b" 50 0.1 through_reset 2026-10-11T12:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a tied pool should still choose: $out"
  assert_contains "$out" "tied and broken by the earliest resetsAt" "the tie-break should be stated"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the earlier reset should win a spendPriority tie"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 50 0.3 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T15:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a fully tied pool should still choose: $out"
  assert_contains "$out" "tied and broken by the earlier line" "the pool-order tie-break should be stated"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "an exact tie should go to the earlier line"
  pass "pick breaks an exact spendPriority tie by the earliest reset, then by pool order"
}

test_single_line_or_absent_pin_skips_quota_axi() {
  local out rc
  pool "$WORK"
  out=$(pick --model claude-opus-5); rc=$?
  expect_code 0 "$rc" "a single-line pin should succeed: $out"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "a single line is the only choice"
  [ ! -s "$CALLS" ] || fail "a single-line pin must not run quota-axi: $(cat "$CALLS")"
  rm "$CFG/claude-account"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "an unpinned home should succeed: $out"
  assert_contains "$out" "spawn without --account" "an unpinned home should say to spawn without --account"
  assert_equals "account: none" "$(printf '%s\n' "$out" | tail -1)" "an unpinned home has no account to name"
  [ ! -s "$CALLS" ] || fail "an unpinned home must not run quota-axi: $(cat "$CALLS")"
  pass "pick skips quota-axi for a single-line or absent pin"
}

test_malformed_pool_and_usage_refuse() {
  local out rc
  printf 'ordinary\n%s\nordinary\n' "$WORK" > "$CFG/claude-account"
  out=$(pick); rc=$?
  expect_code 1 "$rc" "a duplicated pool line must refuse"
  assert_contains "$out" "config/claude-account must hold one account per line" "the refusal should name the file"
  [ ! -s "$CALLS" ] || fail "a malformed pool must refuse before quota-axi runs"
  out=$("$PICK" choose 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown subcommand is a usage error"
  out=$("$PICK" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help should succeed"
  assert_contains "$out" "fm-claude-account.sh pick [--model <claude-model>]" "--help should print the usage"
  pass "pick refuses a malformed pool and rejects bad usage"
}

test_two_measured_lanes_pick_the_highest_spend_priority
test_model_scope_row_is_used_when_reported
test_exhausted_lane_is_skipped
test_all_exhausted_exits_distinctly
test_unmeasured_pool_discloses_the_first_line_default
test_ordinary_binds_only_the_unsuffixed_default_store
test_ties_break_by_reset_then_pool_order
test_single_line_or_absent_pin_skips_quota_axi
test_malformed_pool_and_usage_refuse

echo "# all fm-claude-account tests passed"
