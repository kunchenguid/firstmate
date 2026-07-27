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
  write_registry '{
    "reviews":{"vm":"expanly-reviews","slot":2,"frontend_port":5175,"branch":"reviews"},
    "scoring":{"vm":"expanly-scoring","slot":5,"frontend_port":5178,"branch":"scoring"},
    "feature-dev":{"vm":"expanly-feature-dev","slot":1,"frontend_port":5174,"branch":"feature-dev"},
    "pipeline":{"vm":"expanly-pipeline","slot":4,"frontend_port":5177,"branch":"pipeline"},
    "billing":{"vm":"expanly-billing","slot":3,"frontend_port":5176,"branch":"billing"}
  }'

  result=$(fm_devenv_registry_json "$TMP_ROOT/registry.json") \
    || fail "valid feature environments were rejected"
  expected='[{"name":"main","vm":"expanly-main","slot":0,"frontend_port":5173,"branch":""},{"name":"feature-dev","vm":"expanly-feature-dev","slot":1,"frontend_port":5174,"branch":"feature-dev"},{"name":"reviews","vm":"expanly-reviews","slot":2,"frontend_port":5175,"branch":"reviews"},{"name":"billing","vm":"expanly-billing","slot":3,"frontend_port":5176,"branch":"billing"},{"name":"pipeline","vm":"expanly-pipeline","slot":4,"frontend_port":5177,"branch":"pipeline"},{"name":"scoring","vm":"expanly-scoring","slot":5,"frontend_port":5178,"branch":"scoring"}]'
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

  write_registry '{"feature-dev":{"vm":"expanly-feature-dev","slot":1,"frontend_port":5174,"branch":"feature-dev"}}'
  row=$(fm_devenv_registry_get "$TMP_ROOT/registry.json" feature-dev) \
    || fail "exact environment lookup rejected an existing row"
  [ "$row" = '{"name":"feature-dev","vm":"expanly-feature-dev","slot":1,"frontend_port":5174,"branch":"feature-dev"}' ] \
    || fail "exact environment lookup returned the wrong row: $row"
  ! fm_devenv_registry_get "$TMP_ROOT/registry.json" missing >/dev/null 2>&1 \
    || fail "exact environment lookup accepted a missing row"
  pass "devenv registry: reusable validators and exact lookup reject invalid input"
}

test_registry_uses_one_immutable_snapshot() {
  local registry snapshot_dir fakebin real_jq triggered replacement result expected leaked
  registry="$TMP_ROOT/mutable-registry.json"
  snapshot_dir="$TMP_ROOT/mutable-snapshots"
  fakebin="$TMP_ROOT/mutable-fakebin"
  real_jq=$(command -v jq)
  triggered="$TMP_ROOT/jq-triggered"
  replacement='{"intruder":{"vm":"expanly-intruder","slot":2,"frontend_port":5175,"branch":"feature/intruder"}}'
  printf '%s\n' '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}}' > "$registry"
  mkdir -p "$snapshot_dir" "$fakebin"
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
    export TMPDIR="$snapshot_dir"
    fm_devenv_registry_json "$registry"
  ) || fail "registry discovery failed while its source path changed"
  expected='[{"name":"main","vm":"expanly-main","slot":0,"frontend_port":5173,"branch":""},{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}]'
  [ -e "$triggered" ] || fail "mutable-registry fixture did not replace the source path"
  [ "$(printf '%s' "$result" | "$real_jq" -c .)" = "$expected" ] \
    || fail "registry output did not come from the same snapshot that validation observed: $result"
  leaked=$(find "$snapshot_dir" -mindepth 1 -maxdepth 1 -print -quit)
  [ -z "$leaked" ] || fail "successful registry discovery leaked an immutable snapshot: $leaked"
  pass "devenv registry: validation and output consume one immutable registry snapshot"
}

test_hostile_name_reports_one_line() {
  assert_registry_rejected '{"alpha\nbeta":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}}' \
    "name containing a newline"
  pass "devenv registry: hostile names cannot split a validation diagnostic across lines"
}

test_raw_nul_registry_is_rejected_without_snapshot_leak() {
  local registry snapshot_dir stdout stderr rc line_count leaked
  registry="$TMP_ROOT/nul-registry.json"
  snapshot_dir="$TMP_ROOT/nul-snapshots"
  stdout="$TMP_ROOT/nul-stdout"
  stderr="$TMP_ROOT/nul-stderr"
  mkdir -p "$snapshot_dir"
  printf '\0%s\n' '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}}' > "$registry"

  TMPDIR="$snapshot_dir" fm_devenv_registry_json "$registry" >"$stdout" 2>"$stderr"
  rc=$?
  expect_code 1 "$rc" "raw NUL registry rejection"
  [ ! -s "$stdout" ] || fail "raw NUL registry printed registry data on failure"
  line_count=$(wc -l < "$stderr" | tr -d ' ')
  [ "$line_count" = 1 ] || fail "raw NUL registry did not print exactly one error"
  leaked=$(find "$snapshot_dir" -mindepth 1 -maxdepth 1 -print -quit)
  [ -z "$leaked" ] || fail "raw NUL registry leaked an immutable snapshot: $leaked"
  pass "devenv registry: raw NUL input fails once without output or snapshot leakage"
}

test_invalid_registries_fail_closed() {
  assert_registry_rejected '{' "invalid JSON"
  assert_registry_rejected '{}
{}' "multiple JSON documents"
  assert_registry_rejected '[]' "non-object root"
  assert_registry_rejected '{"alpha":"not-an-object"}' "non-object feature value"
  assert_registry_rejected '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},"beta":{"vm":"expanly-alpha","slot":2,"frontend_port":5175,"branch":""}}' "duplicate VM names"
  assert_registry_rejected '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},"beta":{"vm":"expanly-beta","slot":1,"frontend_port":5175,"branch":""}}' "duplicate slots"
  assert_registry_rejected '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},"beta":{"vm":"expanly-beta","slot":2,"frontend_port":5174,"branch":""}}' "duplicate ports"
  assert_registry_rejected '{"alpha":{"vm":"expanly-main","slot":1,"frontend_port":5174,"branch":""}}' "VM name duplicated with main"
  assert_registry_rejected '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5173,"branch":""}}' "frontend port duplicated with main"
  assert_registry_rejected '{"alpha beta":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}}' "invalid environment key"
  assert_registry_rejected '{"alpha":{"vm":"alpha","slot":1,"frontend_port":5174,"branch":""}}' "invalid VM field"
  assert_registry_rejected '{"alpha":{"vm":"expanly-alpha","slot":1.5,"frontend_port":5174,"branch":""}}' "non-integer slots"
  assert_registry_rejected '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5174.5,"branch":""}}' "non-integer ports"
  assert_registry_rejected '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":1}}' "non-string branch"
  assert_registry_rejected '{"alpha":{"vm":"expanly-alpha","slot":0,"frontend_port":5174,"branch":""}}' "feature slot zero"
  assert_registry_rejected '{"main":{"vm":"expanly-other","slot":1,"frontend_port":5174,"branch":""}}' "feature keyed main"
  pass "devenv registry: malformed, conflicting, and reserved feature records fail closed"
}

test_discovery_prepends_main_and_sorts_by_slot
test_validators_and_exact_lookup
test_hostile_name_reports_one_line
test_raw_nul_registry_is_rejected_without_snapshot_leak
test_registry_uses_one_immutable_snapshot
test_invalid_registries_fail_closed
