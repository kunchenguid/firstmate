#!/usr/bin/env bash
# Behavior tests for the allowlisted, home-local native subscription account resolver.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB=$(fm_test_tmproot fm-account-lane-tests)
ACCOUNTS="$ROOT/bin/fm-account-lane.sh"
ACCOUNTS_FILE="$LAB/crew-accounts.json"

command -v jq >/dev/null 2>&1 || fail "jq is required for account-lane tests"

write_accounts() {
  printf '%s\n' "$1" > "$ACCOUNTS_FILE"
}

expect_failure_contains() {
  local expected=$1 out rc
  shift
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected command failure: $*"
  assert_contains "$out" "$expected" "expected account-lane validation error"
}

test_valid_native_accounts() {
  mkdir -p "$LAB/claude" "$LAB/codex-1" "$LAB/codex-2"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{"claude-primary":{harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:($root+"/claude")},"codex-primary":{harness:"codex",envName:"CODEX_HOME",configDir:($root+"/codex-1")},"codex-secondary":{harness:"codex",envName:"CODEX_HOME",configDir:($root+"/codex-2")}}}')"
  "$ACCOUNTS" validate "$ACCOUNTS_FILE"
  [ "$("$ACCOUNTS" env-name codex-secondary "$ACCOUNTS_FILE")" = CODEX_HOME ] || fail "wrong Codex environment name"
  [ "$("$ACCOUNTS" config-dir codex-secondary "$ACCOUNTS_FILE")" = "$LAB/codex-2" ] || fail "wrong Codex configuration directory"
  pass "account lanes resolve valid native Claude and Codex mappings"
}

test_rejects_arbitrary_environment() {
  mkdir -p "$LAB/bad"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{bad:{harness:"codex",envName:"PATH",configDir:($root+"/bad")}}}')"
  expect_failure_contains "codex accounts require CODEX_HOME" "$ACCOUNTS" validate "$ACCOUNTS_FILE"
  pass "account lanes reject arbitrary environment names"
}

test_rejects_credential_material() {
  mkdir -p "$LAB/bad"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{bad:{harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:($root+"/bad"),token:"secret"}}}')"
  expect_failure_contains "forbidden credential field: token" "$ACCOUNTS" validate "$ACCOUNTS_FILE"
  pass "account lanes reject credential material"
}

test_selected_account_requires_readable_configuration_directory() {
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{missing:{harness:"codex",envName:"CODEX_HOME",configDir:($root+"/missing")}}}')"
  expect_failure_contains "configDir must be an existing readable directory" "$ACCOUNTS" config-dir missing "$ACCOUNTS_FILE"
  pass "selected account lanes require an existing readable configuration directory"
}

test_valid_native_accounts
test_rejects_arbitrary_environment
test_rejects_credential_material
test_selected_account_requires_readable_configuration_directory
