#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-account-quota.sh: each account declared in
# config/claude-accounts is measured under its own CLAUDE_CONFIG_DIR and its
# quota facts and uncertainty are printed, never a choice.
#
# A fake quota-axi answers from <root>/quota.json, the way the real
# --profile-only read answers from that root's own credential file, and logs
# the root and arguments of every read. A read that sets
# QUOTA_AXI_CLAUDE_PROFILES stands in for the Keychain-aware multi-profile read:
# it answers from the case's synthetic shared.json, never a real Keychain or
# token, and logs its environment and arguments to shared-reads.
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
if [ -n "\${QUOTA_AXI_CLAUDE_PROFILES+set}" ]; then
  printf 'config=%s snapshot=%s token=%s securestorage=%s swap=%s profiles=%s args=%s\n' \
    "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\${CLAUDE_CODE_OAUTH_TOKEN-unset}" \
    "\${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}" "\${QUOTA_AXI_CLAUDE_SWAP-unset}" "\$QUOTA_AXI_CLAUDE_PROFILES" "\$*" >> '$CASE/shared-reads'
  [ -f '$CASE/shared.json' ] || exit 1
  cat '$CASE/shared.json'
  exit 0
fi
printf '%s %s %s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\$*" >> '$CASE/reads'
[ -f "\$CLAUDE_CONFIG_DIR/quota.json" ] || exit 1
cat "\$CLAUDE_CONFIG_DIR/quota.json"
[ ! -f "\$CLAUDE_CONFIG_DIR/exit-1" ] || exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# account <dir> <all_models-percent> <all_models-spendPriority> [runway] [model-scope-spendPriority] [usableRunwaySeconds]
# A Claude root whose profile-only read reports these numbers.
account() {
  local dir=$1 pct=$2 sp=$3 runway=${4:-through_reset} model_sp=${5:-} seconds=${6:-}
  mkdir -p "$dir"
  jq -n --argjson pct "$pct" --argjson sp "$sp" --arg runway "$runway" --arg model_sp "$model_sp" --arg seconds "$seconds" '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      quotaSemantics: {
        status: "known",
        effectiveAvailability: ([
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
           runway: ({status: $runway} + (if $seconds == "" then {} else {usableRunwaySeconds: ($seconds | tonumber), projectionConfidence: "established"} end)),
           selection: {spendPriority: $sp}}
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

# keychain_login <dir>: a signed-in root whose login lives in the macOS
# Keychain, so its --profile-only read finds no credential file and quota-axi
# exits 1 with a notSetUp row.
keychain_login() {
  mkdir -p "$1"
  jq -n '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      windows: [],
      state: {status: "unavailable", stale: false, error: "Claude profile credentials missing"},
      quotaSemantics: {status: "unknown", effectiveAvailability: []},
      accountKeys: ["default"],
      notSetUp: true
    }]
  }' > "$1/quota.json"
  : > "$1/exit-1"
}

# lane <key> <path|-> <keychainService|-> <percent> <spendPriority> [stale]
# One account lane of the multi-profile read, as --full --json names it.
lane() {
  jq -cn --arg key "$1" --arg path "$2" --arg service "$3" --argjson pct "$4" --argjson sp "$5" --arg stale "${6:-}" '{
    provider: "claude",
    accountKey: $key,
    accountKeys: [$key],
    state: {status: "fresh", stale: ($stale == "stale")},
    quotaSemantics: {
      status: "known",
      effectiveAvailability: [
        {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
         runway: {status: "through_reset"}, selection: {spendPriority: $sp}}
      ]
    }
  } + (if $path == "-" then {} else {accountLocator: ({kind: "config-dir", path: $path, delegateEligible: false}
        + (if $service == "-" then {} else {keychainService: $service} end))} end)'
}

# shared_read <lane-json>...: the multi-profile read's snapshot for this case.
shared_read() {
  printf '%s\n' "$@" | jq -s '{schemaVersion: 6, providers: .}' > "$CASE/shared.json"
}

run_tool() {
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" "$TOOL" "$@" 2>&1
}

# run_tool_with_env <NAME=value>...: run_tool under extra ambient variables.
run_tool_with_env() {
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" "$@" "$TOOL" 2>&1
}

assert_no_choice() {
  assert_not_contains "$1" "--account" "the tool must not print a chosen account"
  assert_not_contains "$1" "status: " "the tool must not print a verdict status"
  assert_not_contains "$1" "eligible" "the tool must not judge eligibility"
}

test_two_accounts_print_their_own_rows() {
  local out rc
  new_case two
  account "$CASE/a" 70 0.2
  account "$CASE/b" 60 0.5
  printf '%s\n%s\n' "$CASE/a" "$CASE/b" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool); rc=$?
  expect_code 0 "$rc" "measuring two declared accounts should succeed: $out"
  assert_contains "$out" "row: $CASE/a  root=$CASE/a  scope=all_models  status=known  remaining=70%  spendPriority=0.2  runway=through_reset" "account a's own row should be shown"
  assert_contains "$out" "row: $CASE/b  root=$CASE/b  scope=all_models  status=known  remaining=60%  spendPriority=0.5  runway=through_reset" "account b's own row should be shown"
  assert_no_choice "$out"
  assert_grep "$CASE/a unset --provider claude --profile-only --json" "$CASE/reads" "account a should be read in isolation under its own root"
  assert_grep "$CASE/b unset --provider claude --profile-only --json" "$CASE/reads" "account b should be read in isolation under its own root"
  assert_absent "$CASE/shared-reads" "accounts with credential files must not trigger the Keychain-aware read"
  pass "each declared account prints its own quota row, read under its own root"
}

test_the_model_scope_is_printed() {
  local out
  new_case model
  account "$CASE/a" 70 0.2 through_reset 0.9
  printf '%s\n' "$CASE/a" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool --model opus)
  assert_contains "$out" "row: $CASE/a  root=$CASE/a  scope=all_models  status=known  remaining=70%  spendPriority=0.2" "the all_models scope applies to the model"
  assert_contains "$out" "row: $CASE/a  root=$CASE/a  scope=model:opus  status=known  remaining=50%  spendPriority=0.9" "the model scope should be printed"
  out=$(run_tool)
  assert_not_contains "$out" "scope=model:opus" "a model scope does not apply without --model"
  assert_no_choice "$out"
  pass "a model-specific scope is printed only for that model"
}

test_exhausted_and_unreadable_accounts_print_facts() {
  local out
  new_case gates
  account "$CASE/spent" 0 0.9
  account "$CASE/dry" 40 0.8 exhausted_now
  mkdir -p "$CASE/unread"
  printf '%s\n' "$CASE/spent" "$CASE/dry" "$CASE/unread" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/spent  root=$CASE/spent  scope=all_models  status=known  remaining=0%  spendPriority=0.9  runway=through_reset" "a 0% account prints its facts"
  assert_contains "$out" "row: $CASE/dry  root=$CASE/dry  scope=all_models  status=known  remaining=40%  spendPriority=0.8  runway=exhausted_now" "an exhausted account prints its runway"
  assert_contains "$out" "row: $CASE/unread  root=$CASE/unread  uncertainty: quota-axi could not read this account" "an unreadable account is disclosed uncertainty"
  assert_no_choice "$out"
  pass "exhausted, 0%, and unreadable accounts print facts and uncertainty without a verdict"
}

test_projected_runway_prints_its_seconds() {
  local out
  new_case runway
  account "$CASE/long" 80 0.4 projected_exhaustion "" 241920
  account "$CASE/short" 30 0.9 projected_exhaustion "" 2700
  account "$CASE/unknown" 50 0.5 projected_exhaustion
  printf '%s\n' "$CASE/long" "$CASE/short" "$CASE/unknown" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/long  root=$CASE/long  scope=all_models  status=known  remaining=80%  spendPriority=0.4  runway=projected_exhaustion  usableRunwaySeconds=241920  confidence=established" \
    "a projected exhaustion should carry its runway seconds"
  assert_contains "$out" "row: $CASE/short  root=$CASE/short  scope=all_models  status=known  remaining=30%  spendPriority=0.9  runway=projected_exhaustion  usableRunwaySeconds=2700  confidence=established" \
    "each account should carry its own runway seconds"
  assert_contains "$out" "row: $CASE/unknown  root=$CASE/unknown  scope=all_models  status=known  remaining=50%  spendPriority=0.5  runway=projected_exhaustion  usableRunwaySeconds=-" \
    "a projection without seconds should show that it is missing"
  assert_not_contains "$out" "runway=through_reset  usableRunwaySeconds" "through_reset carries no runway seconds"
  assert_no_choice "$out"
  pass "a projected exhaustion prints each account's own runway seconds and confidence without a verdict"
}

test_a_rate_limited_account_names_the_vendor_reason() {
  local out
  new_case rate-limited
  rate_limited_account "$CASE/limited"
  printf '%s\n' "$CASE/limited" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/limited  root=$CASE/limited  uncertainty: quota unknown (rate_limited: Claude quota endpoint rate limited)" \
    "a rate-limited read should keep quota-axi's own reason, not report an unreadable account"
  assert_not_contains "$out" "could not read" "a rate-limited snapshot is not an unreadable root"
  assert_no_choice "$out"
  pass "a rate-limited account names the vendor's reason"
}

test_ordinary_is_measured_from_the_default_root() {
  local out
  new_case ordinary
  account "$CASE/user-home/.claude" 50 0.3
  printf 'ordinary\n' > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.claude  scope=all_models  status=known  remaining=50%  spendPriority=0.3" "the ordinary account should be measurable"
  assert_no_choice "$out"
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

test_keychain_logins_are_bound_by_locator() {
  local out rc
  new_case keychain
  keychain_login "$CASE/user-home/.claude"
  keychain_login "$CASE/second"
  shared_read \
    "$(lane profile:aaa "$CASE/user-home/.claude" "Claude Code-credentials" 70 0.2)" \
    "$(lane profile:bbb "$CASE/second" "Claude Code-credentials-0b1c2d3e" 40 0.6)" \
    "$(lane profile:ccc "$CASE/elsewhere" "Claude Code-credentials-9f8e7d6c" 5 0.99)"
  printf 'ordinary\n%s\n' "$CASE/second" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool_with_env CLAUDE_CONFIG_DIR="$CASE/ambient" CLAUDE_CODE_OAUTH_TOKEN=ambient-token \
    CLAUDE_SECURESTORAGE_CONFIG_DIR="$CASE/ambient" QUOTA_AXI_CLAUDE_SWAP=1); rc=$?
  expect_code 0 "$rc" "binding Keychain logins should succeed: $out"
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.claude  scope=all_models  status=known  remaining=70%  spendPriority=0.2  runway=through_reset" \
    "ordinary should take the lane of the unsuffixed default Keychain item"
  assert_contains "$out" "row: $CASE/second  root=$CASE/second  scope=all_models  status=known  remaining=40%  spendPriority=0.6  runway=through_reset" \
    "a directory should take the lane located at that directory"
  assert_not_contains "$out" "uncertainty" "both Keychain logins should be measured"
  assert_not_contains "$out" "spendPriority=0.99" "a lane no entry declares must not answer for any entry"
  assert_no_choice "$out"
  assert_equals 1 "$(wc -l < "$CASE/shared-reads" | tr -d ' ')" "every declared entry should be measured in one shared read"
  assert_grep "config=unset snapshot=unset token=unset securestorage=unset swap=unset profiles=$CASE/second args=--provider claude --full --json --no-credential-refresh" \
    "$CASE/shared-reads" "the shared read should list the declared directories with no ambient account selector, token, or refresh"
  assert_no_grep "allow-keychain-prompt" "$CASE/shared-reads" "the script must never ask quota-axi to prompt the Keychain"
  pass "Keychain logins without a credential file are bound to their own lane by accountLocator"
}

test_file_readings_win_over_the_shared_read() {
  local out
  new_case mixed
  account "$CASE/filed" 80 0.3
  keychain_login "$CASE/keyed"
  shared_read \
    "$(lane profile:aaa "$CASE/filed" "Claude Code-credentials-11111111" 10 0.9)" \
    "$(lane profile:bbb "$CASE/keyed" "Claude Code-credentials-22222222" 40 0.6)"
  printf '%s\n%s\n' "$CASE/filed" "$CASE/keyed" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/filed  root=$CASE/filed  scope=all_models  status=known  remaining=80%  spendPriority=0.3" \
    "an entry its credential file measured should keep that reading"
  assert_not_contains "$out" "remaining=10%" "the shared read must not replace a credential-file reading"
  assert_contains "$out" "row: $CASE/keyed  root=$CASE/keyed  scope=all_models  status=known  remaining=40%  spendPriority=0.6" \
    "the Keychain login should be measured from its own lane"
  assert_grep "profiles=$CASE/filed:$CASE/keyed " "$CASE/shared-reads" "the shared read should list every declared directory in file order"
  pass "a credential-file reading is kept and only the Keychain login is bound from the shared read"
}

test_unbindable_entries_stay_unmeasured() {
  local out
  new_case unbound
  keychain_login "$CASE/user-home/.claude"
  keychain_login "$CASE/missing"
  keychain_login "$CASE/twice"
  keychain_login "$CASE/user-home/.claude-named"
  shared_read \
    "$(lane profile:aaa "$CASE/user-home/.claude-named" "Claude Code-credentials" 90 0.9)" \
    "$(lane profile:bbb "$CASE/twice" "Claude Code-credentials-33333333" 30 0.4)" \
    "$(lane profile:ccc "$CASE/twice" "Claude Code-credentials-44444444" 20 0.5)" \
    "$(lane profile:ddd - - 60 0.7)"
  printf 'ordinary\n%s\n%s\n%s\n' "$CASE/missing" "$CASE/twice" "$CASE/user-home/.claude-named" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.claude  scope=all_models  status=known  remaining=90%" \
    "ordinary binds by the default Keychain item, wherever quota-axi locates it"
  assert_contains "$out" "row: $CASE/missing  root=$CASE/missing  uncertainty: quota unknown (unavailable: Claude profile credentials missing)" \
    "an entry no lane claims should keep its own unmeasured reading"
  assert_contains "$out" "row: $CASE/missing  root=$CASE/missing  uncertainty: no Keychain-aware lane is located at this account" \
    "an entry no lane claims should say why"
  assert_contains "$out" "row: $CASE/twice  root=$CASE/twice  uncertainty: 2 Keychain-aware lanes claim this account, so none is used" \
    "an entry two lanes claim should stay unmeasured"
  assert_contains "$out" "row: $CASE/user-home/.claude-named  root=$CASE/user-home/.claude-named  uncertainty: no Keychain-aware lane is located at this account" \
    "a directory must not take the default Keychain item's lane even at the same path"
  assert_not_contains "$out" "remaining=60%" "a lane without a locator must not answer for any entry"
  assert_not_contains "$out" "remaining=30%" "an ambiguous lane must not answer"
  assert_not_contains "$out" "remaining=20%" "an ambiguous lane must not answer"
  assert_no_choice "$out"
  pass "an entry no lane or several lanes claim stays unmeasured and never takes another lane"
}

test_shared_read_failures_are_disclosed() {
  local out
  new_case shared-fail
  keychain_login "$CASE/keyed"
  keychain_login "$CASE/odd:dir"
  printf '%s\n%s\n' "$CASE/keyed" "$CASE/odd:dir" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/keyed  root=$CASE/keyed  uncertainty: the Keychain-aware quota-axi read returned no valid snapshot" \
    "a failed shared read should be disclosed on each entry it was for"
  assert_grep "profiles=$CASE/keyed args=" "$CASE/shared-reads" "a directory containing : cannot be listed in QUOTA_AXI_CLAUDE_PROFILES"
  shared_read "$(lane profile:aaa "$CASE/keyed" "Claude Code-credentials-55555555" 50 0.5)"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/odd:dir  root=$CASE/odd:dir  uncertainty: a path containing : cannot be named in QUOTA_AXI_CLAUDE_PROFILES" \
    "a directory containing : should say why it stays unmeasured"
  assert_contains "$out" "row: $CASE/keyed  root=$CASE/keyed  scope=all_models  status=known  remaining=50%" "the listable directory is still measured"

  new_case only-ordinary
  keychain_login "$CASE/user-home/.claude"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.claude  uncertainty: no declared config directory to read beside the default profile" \
    "ordinary alone has no directory to list, so it stays unmeasured"
  assert_absent "$CASE/shared-reads" "nothing should be read when no directory can be listed"
  pass "a failed or impossible shared read leaves its entries unmeasured with the reason"
}

test_shared_lane_facts_are_disclosed() {
  local out
  new_case lane-facts
  keychain_login "$CASE/user-home/.claude"
  keychain_login "$CASE/stale"
  keychain_login "$CASE/ungranted"
  shared_read \
    "$(lane profile:aaa "$CASE/user-home/.claude" - 70 0.2)" \
    "$(lane profile:bbb "$CASE/stale" - 40 0.6 stale)" \
    "$(jq -cn --arg path "$CASE/ungranted" '{provider: "claude", accountKey: "profile:ccc", accountKeys: ["profile:ccc"],
      accountLocator: {kind: "config-dir", path: $path, delegateEligible: false},
      state: {status: "unavailable", stale: false, error: "Claude Keychain access required"},
      quotaSemantics: {status: "unknown", effectiveAvailability: []}}')"
  printf 'ordinary\n%s\n%s\n' "$CASE/stale" "$CASE/ungranted" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.claude  scope=all_models  status=known  remaining=70%" \
    "without keychainService, ordinary binds to the lane at ~/.claude"
  assert_contains "$out" "row: $CASE/stale  root=$CASE/stale  uncertainty: stale reading served from the quota-axi cache" \
    "a stale lane should be disclosed"
  assert_contains "$out" "row: $CASE/stale  root=$CASE/stale  scope=all_models  status=known  remaining=40%" \
    "a stale lane still prints its facts"
  assert_contains "$out" "row: $CASE/ungranted  root=$CASE/ungranted  uncertainty: quota unknown (unavailable: Claude Keychain access required)" \
    "a lane quota-axi could not open should keep its own reason"
  assert_no_choice "$out"
  pass "a bound lane's stale or unavailable state is disclosed as uncertainty"
}

test_two_accounts_print_their_own_rows
test_the_model_scope_is_printed
test_exhausted_and_unreadable_accounts_print_facts
test_projected_runway_prints_its_seconds
test_a_rate_limited_account_names_the_vendor_reason
test_ordinary_is_measured_from_the_default_root
test_absent_or_malformed_lists_refuse
test_keychain_logins_are_bound_by_locator
test_file_readings_win_over_the_shared_read
test_unbindable_entries_stay_unmeasured
test_shared_read_failures_are_disclosed
test_shared_lane_facts_are_disclosed

echo "# all fm-claude-account-quota tests passed"
