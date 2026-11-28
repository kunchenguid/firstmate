#!/usr/bin/env bash
# Behavior tests for bin/fm-codex-account-quota.sh: each account declared in
# config/codex-accounts is measured under its own CODEX_HOME and its quota
# facts and uncertainty are printed, never a choice.
#
# A fake quota-axi answers from <root>/quota.json, the way the real
# --profile-only read answers from that root's own credential file, and logs
# the root and arguments of every read. tests/fm-claude-account-quota.test.sh
# covers the shared row format in depth.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-account-quota)
TOOL="$ROOT/bin/fm-codex-account-quota.sh"

# new_case <name> -> sets CASE HOME_DIR FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/config" "$FAKEBIN" "$CASE/user-home"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s %s %s %s\n' "\${CODEX_HOME-unset}" "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\$*" >> '$CASE/reads'
[ -f "\$CODEX_HOME/quota.json" ] || exit 1
cat "\$CODEX_HOME/quota.json"
[ ! -f "\$CODEX_HOME/exit-1" ] || exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# account <dir> <all_models-percent> <all_models-spendPriority> [runway] [usableRunwaySeconds]
# A Codex home whose profile-only read reports these numbers.
account() {
  local dir=$1 pct=$2 sp=$3 runway=${4:-through_reset} seconds=${5:-}
  mkdir -p "$dir"
  jq -n --argjson pct "$pct" --argjson sp "$sp" --arg runway "$runway" --arg seconds "$seconds" '{
    schemaVersion: 5,
    providers: [{
      provider: "codex",
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
           runway: ({status: $runway} + (if $seconds == "" then {} else {usableRunwaySeconds: ($seconds | tonumber), projectionConfidence: "established"} end)),
           selection: {spendPriority: $sp}},
          {scope: "model:gpt-5.5", status: "known", effectivePercentRemaining: 40,
           runway: {status: "through_reset"}, selection: {spendPriority: 0.7}}
        ]
      }
    }]
  }' > "$dir/quota.json"
}

run_tool() {
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" CODEX_HOME="$CASE/ambient" "$TOOL" "$@" 2>&1
}

assert_no_choice() {
  assert_not_contains "$1" "--account" "the tool must not print a chosen account"
  assert_not_contains "$1" "eligible" "the tool must not judge eligibility"
}

test_each_codex_home_prints_its_own_rows() {
  local out rc
  new_case two
  account "$CASE/work" 70 0.2
  account "$CASE/personal" 30 0.9 projected_exhaustion 2700
  printf '%s\n%s\n' "$CASE/work" "$CASE/personal" > "$HOME_DIR/config/codex-accounts"
  out=$(run_tool); rc=$?
  expect_code 0 "$rc" "measuring two declared Codex accounts should succeed: $out"
  assert_contains "$out" "codex-account-quota:" "the block should name Codex"
  assert_contains "$out" "row: $CASE/work  root=$CASE/work  scope=all_models  status=known  remaining=70%  spendPriority=0.2  runway=through_reset" \
    "the first account's own row should be shown"
  assert_contains "$out" "row: $CASE/personal  root=$CASE/personal  scope=all_models  status=known  remaining=30%  spendPriority=0.9  runway=projected_exhaustion  usableRunwaySeconds=2700  confidence=established" \
    "the second account's own row and runway seconds should be shown"
  assert_not_contains "$out" "scope=model:gpt-5.5" "a model scope does not apply without --model"
  assert_no_choice "$out"
  assert_grep "$CASE/work unset unset --provider codex --profile-only --json" "$CASE/reads" \
    "the first account should be read in isolation under its own CODEX_HOME"
  assert_grep "$CASE/personal unset unset --provider codex --profile-only --json" "$CASE/reads" \
    "the second account should be read in isolation under its own CODEX_HOME"
  out=$(run_tool --model gpt-5.5)
  assert_contains "$out" "row: $CASE/work  root=$CASE/work  scope=model:gpt-5.5  status=known  remaining=40%  spendPriority=0.7" \
    "the model scope should be printed for that model"
  pass "each declared Codex home prints its own quota rows, read under its own CODEX_HOME"
}

test_ordinary_unreadable_and_rate_limited_codex_accounts() {
  local out
  new_case mixed
  account "$CASE/user-home/.codex" 50 0.3
  mkdir -p "$CASE/unread" "$CASE/limited"
  jq -n '{schemaVersion: 5, providers: [{provider: "codex",
    state: {status: "rate_limited", error: "Codex usage endpoint rate limited"},
    quotaSemantics: {status: "unknown", effectiveAvailability: []}}]}' > "$CASE/limited/quota.json"
  : > "$CASE/limited/exit-1"
  printf '%s\n' ordinary "$CASE/unread" "$CASE/limited" > "$HOME_DIR/config/codex-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.codex  scope=all_models  status=known  remaining=50%  spendPriority=0.3" \
    "ordinary should be measured from ~/.codex"
  assert_contains "$out" "row: $CASE/unread  root=$CASE/unread  uncertainty: quota-axi could not read this account" \
    "an unreadable account is disclosed uncertainty"
  assert_contains "$out" "row: $CASE/limited  root=$CASE/limited  uncertainty: quota unknown (rate_limited: Codex usage endpoint rate limited)" \
    "a rate-limited read keeps quota-axi's own reason"
  assert_no_choice "$out"
  pass "ordinary, unreadable, and rate-limited Codex accounts print facts and uncertainty"
}

test_absent_or_malformed_codex_lists_refuse() {
  local out rc
  new_case refuse
  printf '%s\n' "$CASE/a" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "an absent Codex list must refuse even beside a Claude list"
  assert_contains "$out" "declares no config/codex-accounts" "the refusal should name the missing list"
  printf 'relative\n' > "$HOME_DIR/config/codex-accounts"
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "a malformed list must refuse"
  assert_contains "$out" "config/codex-accounts must hold one account per line" "the refusal should name the format"
  assert_absent "$CASE/reads" "a refused list must not read any quota"
  pass "an absent or malformed Codex list refuses before any quota read"
}

test_each_codex_home_prints_its_own_rows
test_ordinary_unreadable_and_rate_limited_codex_accounts
test_absent_or_malformed_codex_lists_refuse

echo "# all fm-codex-account-quota tests passed"
