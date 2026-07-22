#!/usr/bin/env bash
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
if [ -n "${FAKE_VALIDATION+x}" ]; then
  printf '%s\n' "$FAKE_VALIDATION"
else
  printf '%s\n' '{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0},"diagnostics":[]}'
fi
SH
  chmod +x "$dir/finance/bin/finance-axi"
  printf '%s\n' "$dir"
}

snapshot_case() {
  local dir=$1 project="$1/project"
  "$EVALUATOR" snapshot "$project" "$project/out/result.json" "$dir/baseline" > "$dir/baseline.sha256"
}

evaluate_case() {
  local dir=$1 project="$1/project"
  FINANCE_HARNESS_HOME="$dir/finance" "$EVALUATOR" evaluate \
    "$project" \
    "$project/inputs/artifact.json" \
    "$project/out/result.json" \
    "$project/inputs/trusted.json" \
    "$project/inputs/market.json" \
    "$dir/baseline" \
    "$(< "$dir/baseline.sha256")"
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

test_valid_control() {
  local dir
  dir=$(make_case valid)
  snapshot_case "$dir"
  cp "$dir/project/inputs/artifact.json" "$dir/project/out/result.json"
  evaluate_case "$dir" | grep -Fqx 'verdict=success' \
    || fail "valid copied artifact did not pass"
  pass "trusted snapshot accepts the one canonical copied artifact"
}

test_noncanonical_output_bypass() {
  local dir project
  dir=$(make_case noncanonical)
  project="$dir/project"
  snapshot_case "$dir"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "noncanonical output bypass" env FINANCE_HARNESS_HOME="$dir/finance" \
    "$EVALUATOR" evaluate "$project" \
    "$project/inputs/artifact.json" "$project/inputs/artifact.json" \
    "$project/inputs/trusted.json" "$project/inputs/market.json" "$dir/baseline" \
    "$(< "$dir/baseline.sha256")"
}

test_snapshot_contract_bypasses() {
  local dir project
  dir=$(make_case snapshot-contract)
  project="$dir/project"
  expect_rejected "noncanonical snapshot output bypass" \
    "$EVALUATOR" snapshot "$project" "$project/out/other.json" "$dir/baseline"
  expect_rejected "in-project baseline bypass" \
    "$EVALUATOR" snapshot "$project" "$project/out/result.json" "$project/baseline"
  expect_rejected "evaluation without a trusted snapshot bypass" env \
    FINANCE_HARNESS_HOME="$dir/finance" "$EVALUATOR" evaluate \
    "$project" "$project/inputs/artifact.json" "$project/out/result.json" \
    "$project/inputs/trusted.json" "$project/inputs/market.json" \
    "$dir/missing-baseline" "$(printf '0%.0s' {1..64})"

  snapshot_case "$dir"
  expect_rejected "existing baseline replacement bypass" \
    "$EVALUATOR" snapshot "$project" "$project/out/result.json" "$dir/baseline"
}

test_symlink_and_alias_bypasses() {
  local dir project external
  dir=$(make_case symlink)
  project="$dir/project"
  external="$dir/external-artifact.json"
  cp "$project/inputs/artifact.json" "$external"
  rm "$project/inputs/artifact.json"
  ln -s "$external" "$project/inputs/artifact.json"
  snapshot_case "$dir"
  cp "$external" "$project/out/result.json"
  expect_rejected "fixture input symlink bypass" evaluate_case "$dir"

  dir=$(make_case trusted-symlink)
  project="$dir/project"
  external="$dir/external-trusted.json"
  cp "$project/inputs/trusted.json" "$external"
  rm "$project/inputs/trusted.json"
  ln -s "$external" "$project/inputs/trusted.json"
  snapshot_case "$dir"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "trusted-sources symlink bypass" evaluate_case "$dir"

  dir=$(make_case market-symlink)
  project="$dir/project"
  external="$dir/external-market.json"
  cp "$project/inputs/market.json" "$external"
  rm "$project/inputs/market.json"
  ln -s "$external" "$project/inputs/market.json"
  snapshot_case "$dir"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "market-mark symlink bypass" evaluate_case "$dir"

  dir=$(make_case output-symlink)
  project="$dir/project"
  external="$dir/external-output.json"
  cp "$project/inputs/artifact.json" "$external"
  snapshot_case "$dir"
  ln -s "$external" "$project/out/result.json"
  expect_rejected "output symlink bypass" evaluate_case "$dir"

  dir=$(make_case alias)
  project="$dir/project"
  snapshot_case "$dir"
  ln "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "input-output alias bypass" evaluate_case "$dir"
}

test_unapproved_side_effect_bypasses() {
  local dir project
  dir=$(make_case ignored)
  project="$dir/project"
  snapshot_case "$dir"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  printf 'hidden\n' > "$project/ignored-workload"
  expect_rejected "ignored side effect bypass" evaluate_case "$dir"

  dir=$(make_case tracked)
  project="$dir/project"
  snapshot_case "$dir"
  printf 'changed\n' >> "$project/README.md"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "tracked side effect bypass" evaluate_case "$dir"

  dir=$(make_case commit)
  project="$dir/project"
  snapshot_case "$dir"
  git -C "$project" -c user.name=fixture -c user.email=fixture@example.invalid commit --allow-empty -qm workload
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "post-snapshot commit bypass" evaluate_case "$dir"

  dir=$(make_case metadata)
  project="$dir/project"
  snapshot_case "$dir"
  printf 'changed\n' >> "$project/.git/config"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "Git metadata bypass" evaluate_case "$dir"

  dir=$(make_case baseline-tamper)
  project="$dir/project"
  snapshot_case "$dir"
  printf 'manifest=%064d\n' 0 >> "$dir/baseline"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "baseline tamper bypass" evaluate_case "$dir"
}

test_permissive_json_bypasses() {
  local dir project
  dir=$(make_case missing-diagnostics)
  project="$dir/project"
  snapshot_case "$dir"
  cp "$project/inputs/artifact.json" "$project/out/result.json"
  expect_rejected "missing diagnostics bypass" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0}}'
  expect_rejected "non-object validation bypass" evaluate_case_with_validation "$dir" '[]'
  expect_rejected "non-boolean ok bypass" evaluate_case_with_validation "$dir" \
    '{"ok":1,"profile":"valuation-extract","summary":{"errors":0,"warnings":0},"diagnostics":[]}'
  expect_rejected "wrong profile bypass" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":1,"summary":{"errors":0,"warnings":0},"diagnostics":[]}'
  expect_rejected "non-object summary bypass" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":"valuation-extract","summary":[],"diagnostics":[]}'
  expect_rejected "non-numeric errors bypass" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":"valuation-extract","summary":{"errors":"0","warnings":0},"diagnostics":[]}'
  expect_rejected "non-numeric warnings bypass" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":"0"},"diagnostics":[]}'
  expect_rejected "non-array diagnostics bypass" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0},"diagnostics":{}}'
  expect_rejected "nonempty diagnostics bypass" evaluate_case_with_validation "$dir" \
    '{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0},"diagnostics":[{"message":"failure"}]}'
  expect_rejected "multiple validation documents bypass" evaluate_case_with_validation "$dir" \
    $'{"ok":false}\n{"ok":true,"profile":"valuation-extract","summary":{"errors":0,"warnings":0},"diagnostics":[]}'
}

test_valid_control
test_noncanonical_output_bypass
test_snapshot_contract_bypasses
test_symlink_and_alias_bypasses
test_unapproved_side_effect_bypasses
test_permissive_json_bypasses
