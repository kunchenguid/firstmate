#!/usr/bin/env bash
# fm-devenv-registry.test.sh - validation and lookup contract for the existing
# Expanly devenv environment registry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LIB="$ROOT/bin/fm-devenv-lib.sh"
# shellcheck source=/dev/null
[ ! -f "$LIB" ] || . "$LIB"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-devenv-registry.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

write_registry() {  # <json>
  printf '%s\n' "$1" > "$TMP_ROOT/registry.json"
}

assert_registry_rejected() {  # <json> <label>
  local json=$1 label=$2 stdout stderr rc line_count
  write_registry "$json"
  stdout="$TMP_ROOT/stdout"
  stderr="$TMP_ROOT/stderr"
  fm_devenv_registry_json "$TMP_ROOT/registry.json" >"$stdout" 2>"$stderr"
  rc=$?
  expect_code 1 "$rc" "$label rejection"
  [ ! -s "$stdout" ] || fail "$label printed registry data on failure"
  [ -s "$stderr" ] || fail "$label did not report a precise error"
  line_count=$(wc -l < "$stderr" | tr -d ' ')
  [ "$line_count" = 1 ] || fail "$label printed more than one error"
}

test_discovery_prepends_main_and_sorts_by_slot() {
  local result expected first
  write_registry '[
    {"name":"beta","vm":"expanly-beta","slot":2,"frontend_port":5175,"branch":"feature/beta"},
    {"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}
  ]'

  result=$(fm_devenv_registry_json "$TMP_ROOT/registry.json") \
    || fail "valid feature environments were rejected"
  expected='[{"name":"main","vm":"expanly-main","slot":0,"frontend_port":5173,"branch":""},{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"},{"name":"beta","vm":"expanly-beta","slot":2,"frontend_port":5175,"branch":"feature/beta"}]'
  [ "$(printf '%s' "$result" | jq -c .)" = "$expected" ] \
    || fail "discovery did not prepend main and sort every row by slot: $result"
  first=$(printf '%s' "$result" | jq -c '.[0]')
  [ "$first" = '{"name":"main","vm":"expanly-main","slot":0,"frontend_port":5173,"branch":""}' ] \
    || fail "discovery did not synthesize the exact main row"
  pass "devenv registry: discovery prepends the exact main row and sorts every environment by slot"
}

test_validators_and_exact_lookup() {
  local row
  fm_devenv_name_valid 'alpha_1-beta' || fail "valid environment name was rejected"
  ! fm_devenv_name_valid 'alpha beta' || fail "invalid environment name was accepted"
  fm_devenv_vm_valid 'expanly-alpha_1-beta' || fail "valid VM name was rejected"
  ! fm_devenv_vm_valid 'alpha' || fail "invalid VM name was accepted"

  write_registry '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}]'
  row=$(fm_devenv_registry_get "$TMP_ROOT/registry.json" alpha) \
    || fail "exact environment lookup rejected an existing row"
  [ "$row" = '{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}' ] \
    || fail "exact environment lookup returned the wrong row: $row"
  ! fm_devenv_registry_get "$TMP_ROOT/registry.json" missing >/dev/null 2>&1 \
    || fail "exact environment lookup accepted a missing row"
  pass "devenv registry: reusable validators and exact lookup reject invalid input"
}

test_registry_uses_one_immutable_snapshot() {
  local registry fakebin real_jq triggered replacement result expected
  registry="$TMP_ROOT/mutable-registry.json"
  fakebin="$TMP_ROOT/mutable-fakebin"
  real_jq=$(command -v jq)
  triggered="$TMP_ROOT/jq-triggered"
  replacement='[{"name":"intruder","vm":"expanly-intruder","slot":2,"frontend_port":5175,"branch":"feature/intruder"}]'
  printf '%s\n' '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}]' > "$registry"
  mkdir -p "$fakebin"
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
output=$("$FM_TEST_REAL_JQ" "$@")
rc=$?
if [ ! -e "$FM_TEST_JQ_TRIGGERED" ]; then
  : > "$FM_TEST_JQ_TRIGGERED"
  printf '%s\n' "$FM_TEST_REPLACEMENT_JSON" > "$FM_TEST_MUTABLE_REGISTRY"
fi
printf '%s' "$output"
[ -z "$output" ] || printf '\n'
exit "$rc"
SH
  chmod +x "$fakebin/jq"

  result=$(
    export FM_TEST_REAL_JQ="$real_jq"
    export FM_TEST_JQ_TRIGGERED="$triggered"
    export FM_TEST_MUTABLE_REGISTRY="$registry"
    export FM_TEST_REPLACEMENT_JSON="$replacement"
    export PATH="$fakebin:$PATH"
    fm_devenv_registry_json "$registry"
  ) || fail "registry discovery failed while its source path changed"
  expected='[{"name":"main","vm":"expanly-main","slot":0,"frontend_port":5173,"branch":""},{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}]'
  [ -e "$triggered" ] || fail "mutable-registry fixture did not replace the source path"
  [ "$(printf '%s' "$result" | "$real_jq" -c .)" = "$expected" ] \
    || fail "registry output did not come from the same snapshot that validation observed: $result"
  pass "devenv registry: validation and output consume one immutable registry snapshot"
}

test_hostile_name_reports_one_line() {
  assert_registry_rejected '[{"name":"alpha\nbeta","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}]' \
    "name containing a newline"
  pass "devenv registry: hostile names cannot split a validation diagnostic across lines"
}

test_invalid_registries_fail_closed() {
  assert_registry_rejected '{' "invalid JSON"
  assert_registry_rejected '[]
[]' "multiple JSON documents"
  assert_registry_rejected '{"name":"alpha"}' "non-array root"
  assert_registry_rejected '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},{"name":"beta","vm":"expanly-alpha","slot":2,"frontend_port":5175,"branch":""}]' "duplicate VM names"
  assert_registry_rejected '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},{"name":"beta","vm":"expanly-beta","slot":1,"frontend_port":5175,"branch":""}]' "duplicate slots"
  assert_registry_rejected '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},{"name":"beta","vm":"expanly-beta","slot":2,"frontend_port":5174,"branch":""}]' "duplicate ports"
  assert_registry_rejected '[{"name":"alpha beta","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}]' "invalid names"
  assert_registry_rejected '[{"name":"alpha","vm":"expanly-alpha","slot":1.5,"frontend_port":5174,"branch":""}]' "non-integer slots"
  assert_registry_rejected '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174.5,"branch":""}]' "non-integer ports"
  assert_registry_rejected '[{"name":"alpha","vm":"expanly-alpha","slot":0,"frontend_port":5174,"branch":""}]' "feature slot zero"
  assert_registry_rejected '[{"name":"main","vm":"expanly-other","slot":1,"frontend_port":5174,"branch":""}]' "feature named main"
  pass "devenv registry: malformed, conflicting, and reserved feature records fail closed"
}

test_discovery_prepends_main_and_sorts_by_slot
test_validators_and_exact_lookup
test_hostile_name_reports_one_line
test_registry_uses_one_immutable_snapshot
test_invalid_registries_fail_closed
