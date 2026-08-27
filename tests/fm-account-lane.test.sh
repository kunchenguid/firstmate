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
  "$ACCOUNTS" resolve codex-secondary "$ACCOUNTS_FILE" \
    | jq -e --arg dir "$LAB/codex-2" '. == {harness:"codex",envName:"CODEX_HOME",configDir:$dir}' >/dev/null \
    || fail "single-snapshot Codex account resolution returned the wrong tuple"
  pass "account lanes resolve valid native Claude and Codex mappings"
}

test_concurrent_atomic_replacement_never_mixes_account_tuple() {
  local writer_pid iteration=0 resolved
  mkdir -p "$LAB/snapshot-claude" "$LAB/snapshot-codex"
  jq -n --arg dir "$LAB/snapshot-claude" \
    '{version:1,accounts:{lane:{harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:$dir}}}' \
    > "$LAB/accounts-a.json"
  jq -n --arg dir "$LAB/snapshot-codex" \
    '{version:1,accounts:{lane:{harness:"codex",envName:"CODEX_HOME",configDir:$dir}}}' \
    > "$LAB/accounts-b.json"
  cp "$LAB/accounts-a.json" "$ACCOUNTS_FILE"
  (
    while [ "$iteration" -lt 100 ]; do
      cp "$LAB/accounts-a.json" "$LAB/accounts-next.json"
      mv "$LAB/accounts-next.json" "$ACCOUNTS_FILE"
      cp "$LAB/accounts-b.json" "$LAB/accounts-next.json"
      mv "$LAB/accounts-next.json" "$ACCOUNTS_FILE"
      iteration=$((iteration + 1))
    done
  ) &
  writer_pid=$!
  iteration=0
  while [ "$iteration" -lt 100 ]; do
    resolved=$("$ACCOUNTS" resolve lane "$ACCOUNTS_FILE") \
      || fail "single-snapshot account resolution failed during atomic replacement"
    jq -e --arg claude "$LAB/snapshot-claude" --arg codex "$LAB/snapshot-codex" '
      . == {harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:$claude}
      or . == {harness:"codex",envName:"CODEX_HOME",configDir:$codex}
    ' <<<"$resolved" >/dev/null || fail "account resolver mixed fields from two snapshots: $resolved"
    iteration=$((iteration + 1))
  done
  wait "$writer_pid" || fail "atomic account-map writer failed"
  pass "account resolution consumes one internally consistent map snapshot"
}

test_credential_shaped_account_id_is_allowed() {
  mkdir -p "$LAB/token"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{token:{harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:($root+"/token")}}}')"
  "$ACCOUNTS" validate "$ACCOUNTS_FILE"
  [ "$("$ACCOUNTS" harness token "$ACCOUNTS_FILE")" = claude ] || fail "credential-shaped account ID did not resolve"
  [ "$("$ACCOUNTS" config-dir token "$ACCOUNTS_FILE")" = "$LAB/token" ] || fail "credential-shaped account ID resolved the wrong directory"
  pass "account lanes allow credential-shaped account IDs at the account-map boundary"
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

test_rejects_nested_credential_material() {
  mkdir -p "$LAB/bad"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{bad:{harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:($root+"/bad"),token:{nested:"secret"}}}}')"
  expect_failure_contains "forbidden credential field: token" "$ACCOUNTS" validate "$ACCOUNTS_FILE"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{bad:{harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:($root+"/bad"),authorization:["secret"]}}}')"
  expect_failure_contains "forbidden credential field: authorization" "$ACCOUNTS" validate "$ACCOUNTS_FILE"
  pass "account lanes reject nested object and array credential material"
}
test_selected_account_requires_readable_configuration_directory() {
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{missing:{harness:"codex",envName:"CODEX_HOME",configDir:($root+"/missing")}}}')"
  expect_failure_contains "configDir must be an existing readable directory" "$ACCOUNTS" config-dir missing "$ACCOUNTS_FILE"
  pass "selected account lanes require an existing readable configuration directory"
}

test_valid_native_accounts
test_concurrent_atomic_replacement_never_mixes_account_tuple
test_credential_shaped_account_id_is_allowed
test_rejects_arbitrary_environment
test_rejects_credential_material
test_selected_account_requires_readable_configuration_directory
test_rejects_nested_credential_material
