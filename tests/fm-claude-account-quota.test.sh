#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-account-quota.sh: each account declared in
# config/claude-accounts is measured under its own CLAUDE_CONFIG_DIR, and the
# highest known spendPriority among eligible accounts is the one shown.
#
# A fake quota-axi answers from <root>/quota.json, the way the real
# --profile-only read answers from that root's own credential file, and logs
# the root and arguments of every read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-account-quota)
TOOL="$ROOT/bin/fm-claude-account-quota.sh"

# new_case <name> -> sets CASE HOME_DIR FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/config" "$FAKEBIN" "$CASE/user-home"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s %s %s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\$*" >> '$CASE/reads'
[ -f "\$CLAUDE_CONFIG_DIR/quota.json" ] || exit 1
cat "\$CLAUDE_CONFIG_DIR/quota.json"
[ ! -f "\$CLAUDE_CONFIG_DIR/exit-1" ] || exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# account <dir> <all_models-percent> <all_models-spendPriority> [runway] [model-scope-spendPriority]
# A Claude root whose profile-only read reports these numbers.
account() {
  local dir=$1 pct=$2 sp=$3 runway=${4:-through_reset} model_sp=${5:-}
  mkdir -p "$dir"
  jq -n --argjson pct "$pct" --argjson sp "$sp" --arg runway "$runway" --arg model_sp "$model_sp" '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      quotaSemantics: {
        status: "known",
        effectiveAvailability: ([
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
           runway: {status: $runway}, selection: {spendPriority: $sp}}
        ] + (if $model_sp == "" then [] else [
          {scope: "model:opus", status: "known", effectivePercentRemaining: 50,
           runway: {status: "through_reset"}, selection: {spendPriority: ($model_sp | tonumber)}}
        ] end))
      }
    }]
  }' > "$dir/quota.json"
}

# rate_limited_account <dir>: a root whose read the vendor rate-limits, which
# quota-axi reports with exit 1 and a snapshot naming that state.
rate_limited_account() {
  mkdir -p "$1"
  jq -n '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      state: {status: "rate_limited", error: "Claude quota endpoint rate limited"},
      quotaSemantics: {status: "unknown", effectiveAvailability: []}
    }]
  }' > "$1/quota.json"
  : > "$1/exit-1"
}

run_tool() {
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" "$TOOL" "$@" 2>&1
}

test_the_higher_spend_priority_account_is_shown() {
  local out rc
  new_case two
  account "$CASE/a" 70 0.2
  account "$CASE/b" 60 0.5
  printf '%s\n%s\n' "$CASE/a" "$CASE/b" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool); rc=$?
  expect_code 0 "$rc" "measuring two declared accounts should succeed: $out"
  assert_contains "$out" "status: clear" "two ranked accounts should give a clear answer"
  assert_contains "$out" "candidate: $CASE/a  scope=all_models  remaining=70%  spendPriority=0.2" "account a's own row should be shown"
  assert_contains "$out" "candidate: $CASE/b  scope=all_models  remaining=60%  spendPriority=0.5" "account b's own row should be shown"
  assert_contains "$out" "account: --account '$CASE/b'" "the higher spendPriority should win over file order and remaining percent"
  assert_grep "$CASE/a unset --provider claude --profile-only --json" "$CASE/reads" "account a should be read in isolation under its own root"
  assert_grep "$CASE/b unset --provider claude --profile-only --json" "$CASE/reads" "account b should be read in isolation under its own root"
  pass "the account with the higher spendPriority is shown, each read under its own root"
}

test_the_model_scope_bounds_the_choice() {
  local out
  new_case model
  account "$CASE/a" 70 0.2 through_reset 0.9
  account "$CASE/b" 60 0.5 through_reset 0.1
  printf '%s\n%s\n' "$CASE/a" "$CASE/b" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool --model opus)
  assert_contains "$out" "candidate: $CASE/b  scope=model:opus  remaining=50%  spendPriority=0.1" "the model scope should limit account b"
  assert_contains "$out" "account: --account '$CASE/a'" "the limiting scope's spendPriority should rank the accounts"
  pass "a model-specific scope bounds each account for that model"
}

test_exhausted_and_unmeasured_accounts_are_not_chosen() {
  local out
  new_case gates
  account "$CASE/spent" 0 0.9
  account "$CASE/dry" 40 0.8 exhausted_now
  mkdir -p "$CASE/unread"
  account "$CASE/ok" 30 -0.1
  printf '%s\n' "$CASE/spent" "$CASE/dry" "$CASE/unread" "$CASE/ok" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "candidate: $CASE/spent  scope=all_models  remaining=0%  spendPriority=-  runway=through_reset  -> not eligible: 0% remaining at all_models" "a 0% account must not be eligible"
  assert_contains "$out" "$CASE/dry  scope=all_models  remaining=40%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now" "an exhausted account must not be eligible"
  assert_contains "$out" "candidate: $CASE/unread  -> eligible, unranked: quota-axi could not read this account" "an unreadable account is disclosed uncertainty"
  assert_contains "$out" "account: --account '$CASE/ok'" "the only rankable account should be shown"
  pass "exhausted and 0% accounts are excluded and an unmeasured one stays unranked"
}

test_a_rate_limited_account_names_the_vendor_reason() {
  local out
  new_case rate-limited
  rate_limited_account "$CASE/limited"
  account "$CASE/ok" 40 0.1
  printf '%s\n%s\n' "$CASE/limited" "$CASE/ok" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "candidate: $CASE/limited  -> eligible, unranked: unmeasured (unknown: Claude quota endpoint rate limited)" \
    "a rate-limited read should keep quota-axi's own reason, not report an unreadable account"
  assert_contains "$out" "account: --account '$CASE/ok'" "the measured account should still be shown"
  pass "a rate-limited account stays unranked and names the vendor's reason"
}

test_a_tie_or_nothing_rankable_escalates() {
  local out
  new_case tie
  account "$CASE/a" 70 0.4
  account "$CASE/b" 60 0.4
  printf '%s\n%s\n' "$CASE/a" "$CASE/b" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "status: escalate" "a tie must escalate"
  assert_contains "$out" "reason: genuine spendPriority tie" "the tie must be named"
  assert_not_contains "$out" "account: --account" "a tie must not pick by file order"
  rm "$CASE/a/quota.json" "$CASE/b/quota.json"
  out=$(run_tool)
  assert_contains "$out" "reason: no rankable eligible account" "no readable account must escalate"
  pass "a genuine tie or no rankable account escalates instead of picking by order"
}

test_ordinary_is_measured_from_the_default_root() {
  local out
  new_case ordinary
  account "$CASE/user-home/.claude" 50 0.3
  printf 'ordinary\n' > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "account: --account 'ordinary'" "the ordinary account should be measurable"
  assert_grep "$CASE/user-home/.claude unset" "$CASE/reads" "ordinary should be read from ~/.claude"
  pass "ordinary is measured from the default ~/.claude root"
}

test_absent_or_malformed_lists_refuse() {
  local out rc
  new_case refuse
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "an absent list must refuse"
  assert_contains "$out" "declares no config/claude-accounts" "the refusal should name the missing list"
  printf 'relative\n' > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "a malformed list must refuse"
  assert_contains "$out" "config/claude-accounts must hold one account per line" "the refusal should name the format"
  assert_absent "$CASE/reads" "a refused list must not read any quota"
  pass "an absent or malformed list refuses before any quota read"
}

test_the_higher_spend_priority_account_is_shown
test_the_model_scope_bounds_the_choice
test_exhausted_and_unmeasured_accounts_are_not_chosen
test_a_rate_limited_account_names_the_vendor_reason
test_a_tie_or_nothing_rankable_escalates
test_ordinary_is_measured_from_the_default_root
test_absent_or_malformed_lists_refuse

echo "# all fm-claude-account-quota tests passed"
