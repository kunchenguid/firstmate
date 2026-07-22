#!/usr/bin/env bash
# Contract coverage for the bounded fleet-flow-finalization finance-batch evaluator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVALUATOR="$ROOT/tests/fixtures/fleet-flow-finalization/evaluate-finance-batch.sh"
TMP_ROOT=$(fm_test_tmproot evaluate-finance-batch)

make_case() {
  local name=$1 dir="$TMP_ROOT/$1" project="$TMP_ROOT/$1/project"
  mkdir -p "$project/inputs" "$project/out" "$dir/finance/bin"
  git -C "$project" init -q
  printf '{"approved":true}\n' > "$project/inputs/artifact.json"
  printf '["source"]\n' > "$project/inputs/trusted.json"
  printf '{"mark":1}\n' > "$project/inputs/market.json"
  printf 'ignored-*\n' > "$project/.gitignore"
  printf '# fixture\n' > "$project/README.md"
  git -C "$project" add .
  git -C "$project" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
  cat > "$dir/finance/bin/finance-axi" <<'SH'
#!/usr/bin/env bash
artifact=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact) artifact=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "${FAKE_FINANCE_MUTATION:-}" in
  rewrite-output) printf '{"approved":false}\n' > "$artifact" ;;
  tracked-file) printf 'changed\n' >> "$(dirname "$(dirname "$artifact")")/README.md" ;;
esac
if [ -n "${FAKE_VALIDATION+x}" ]; then
  printf '%s\n' "$FAKE_VALIDATION"
else
  printf '%s\n' '{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0},"diagnostics":[]}'
fi
SH
  chmod +x "$dir/finance/bin/finance-axi"
  printf '%s\n' "$dir"
}

evaluate_case() {
  local dir=$1 project="$1/project" expected_revision
  expected_revision=${2:-$(git -C "$project" rev-parse HEAD)}
  FINANCE_HARNESS_HOME="$dir/finance" "$EVALUATOR" \
    "$project" \
    "$project/inputs/artifact.json" \
    "$project/out/result.json" \
    "$project/inputs/trusted.json" \
    "$project/inputs/market.json" \
    "$expected_revision"
}

evaluate_case_with_validation() {
  local dir=$1 validation=$2
  FAKE_VALIDATION="$validation" evaluate_case "$dir"
}

expect_rejected() {
  local label=$1
  shift
  if "$@" > "$TMP_ROOT/rejected.out" 2>&1; then
    fail "$label was accepted"
  fi
  pass "$label is rejected"
}

test_valid_and_bounded_control() {
  local dir project
  dir=$(make_case valid)
  project="$dir/project"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  evaluate_case "$dir" | grep -Fqx 'verdict=success' \
    || fail "valid copied artifact did not pass"

  dir=$(make_case ignored)
  project="$dir/project"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  printf 'accepted blind spot\n' > "$project/ignored-workload"
  evaluate_case "$dir" | grep -Fqx 'verdict=success' \
    || fail "bounded ignored-path blind spot did not remain accepted"
  pass "canonical copied artifact passes the bounded evaluator"
}

test_resolved_path_contract() {
  local dir project external
  dir=$(make_case local-symlink)
  project="$dir/project"
  mv "$project/inputs/artifact.json" "$project/inputs/artifact-target.json"
  ln -s artifact-target.json "$project/inputs/artifact.json"
  git -C "$project" add -A
  git -C "$project" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm symlink
  cp "$project/inputs/artifact-target.json" "$project/out/result.json"
  evaluate_case "$dir" | grep -Fqx 'verdict=success' \
    || fail "fixture-local input symlink did not pass"

  dir=$(make_case external-symlink)
  project="$dir/project"
  external="$dir/external-artifact.json"
  cp "$project/inputs/artifact.json" "$external"
  rm "$project/inputs/artifact.json"
  ln -s "$external" "$project/inputs/artifact.json"
  git -C "$project" add -A
  git -C "$project" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm symlink
  cp "$external" "$project/out/result.json"
  expect_rejected "external fixture symlink" evaluate_case "$dir"

  dir=$(make_case noncanonical-output)
  project="$dir/project"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "noncanonical output" env FINANCE_HARNESS_HOME="$dir/finance" \
    "$EVALUATOR" "$project" "$project/inputs/artifact.json" \
    "$project/inputs/artifact.json" "$project/inputs/trusted.json" \
    "$project/inputs/market.json" "$(git -C "$project" rev-parse HEAD)"

  dir=$(make_case alias)
  project="$dir/project"
  ln "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "input-output alias" evaluate_case "$dir"
  pass "resolved fixture paths allow local symlinks and reject escapes"
}

test_revision_and_side_effect_contract() {
  local abbreviated dir malformed project expected uppercase wrong_format_ref
  dir=$(make_case tracked)
  project="$dir/project"
  printf 'changed\n' >> "$project/README.md"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "tracked side effect" evaluate_case "$dir"

  dir=$(make_case revision)
  project="$dir/project"
  expected=$(git -C "$project" rev-parse HEAD)
  git -C "$project" -c user.name=fixture -c user.email=fixture@example.invalid commit --allow-empty -qm workload
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "changed HEAD" evaluate_case "$dir" "$expected"

  dir=$(make_case revision-format)
  project="$dir/project"
  expected=$(git -C "$project" rev-parse HEAD)
  abbreviated=${expected:0:12}
  malformed=${expected:0:39}
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "symbolic revision" evaluate_case "$dir" HEAD
  expect_rejected "abbreviated revision" evaluate_case "$dir" "$abbreviated"
  expect_rejected "malformed revision length" evaluate_case "$dir" "$malformed"
  evaluate_case "$dir" "$expected" | grep -Fqx 'verdict=success' \
    || fail "full commit OID did not pass"
  uppercase=$(printf '%s' "$expected" | tr '[:lower:]' '[:upper:]')
  evaluate_case "$dir" "$uppercase" | grep -Fqx 'verdict=success' \
    || fail "uppercase full commit OID did not pass"
  wrong_format_ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  git -C "$project" update-ref "refs/heads/$wrong_format_ref" "$expected"
  expect_rejected "cross-format all-hex ref" evaluate_case "$dir" "$wrong_format_ref"

  dir=$(make_case untracked)
  project="$dir/project"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  printf 'extra\n' > "$project/extra-output"
  expect_rejected "extra untracked side effect" evaluate_case "$dir"

  dir=$(make_case nested)
  project="$dir/project"
  mkdir -p "$project/nested/inputs" "$project/nested/out"
  cp "$project/inputs/"*.json "$project/nested/inputs/"
  cp "$project/nested/inputs/artifact.json" "$project/nested/out/result.json"
  expect_rejected "nested project root" env FINANCE_HARNESS_HOME="$dir/finance" \
    "$EVALUATOR" "$project/nested" "$project/nested/inputs/artifact.json" \
    "$project/nested/out/result.json" "$project/nested/inputs/trusted.json" \
    "$project/nested/inputs/market.json" "$(git -C "$project" rev-parse HEAD)"
}

test_finance_validator_mutations() {
  local dir project
  dir=$(make_case finance-output-mutation)
  project="$dir/project"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "finance output mutation" env FAKE_FINANCE_MUTATION=rewrite-output \
    FINANCE_HARNESS_HOME="$dir/finance" "$EVALUATOR" "$project" \
    "$project/inputs/artifact.json" "$project/out/result.json" \
    "$project/inputs/trusted.json" "$project/inputs/market.json" \
    "$(git -C "$project" rev-parse HEAD)"

  dir=$(make_case finance-tracked-mutation)
  project="$dir/project"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "finance tracked-file mutation" env FAKE_FINANCE_MUTATION=tracked-file \
    FINANCE_HARNESS_HOME="$dir/finance" "$EVALUATOR" "$project" \
    "$project/inputs/artifact.json" "$project/out/result.json" \
    "$project/inputs/trusted.json" "$project/inputs/market.json" \
    "$(git -C "$project" rev-parse HEAD)"
}

test_strict_finance_json_contract() {
  local dir project
  dir=$(make_case finance-json)
  project="$dir/project"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "missing diagnostics" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0}}'
  expect_rejected "non-object validation" evaluate_case_with_validation "$dir" '[]'
  expect_rejected "wrong field types" evaluate_case_with_validation "$dir" \
    '{"ok":1,"profile":"valuation-extract","summary":{"errors":"0","warnings":0},"diagnostics":{}}'
  expect_rejected "nonempty diagnostics" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0},"diagnostics":[{}]}'
  expect_rejected "multiple validation documents" evaluate_case_with_validation "$dir" \
    $'{"ok":false}\n{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0},"diagnostics":[]}'
}

test_valid_and_bounded_control
test_resolved_path_contract
test_revision_and_side_effect_contract
test_finance_validator_mutations
test_strict_finance_json_contract
