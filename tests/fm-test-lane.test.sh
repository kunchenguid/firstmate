#!/usr/bin/env bash
# Contract tests for the public shell behavior lane runner.
#
# The public seam is bin/fm-test-lane.sh <unit|integration|e2e>.
# The runner owns manifest validation, deterministic selection, timing markers,
# and exit propagation before CI or local operators depend on it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-lane.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-lane)

make_fixture() {  # <name>
  local dir=$1
  mkdir -p "$dir/tests" "$dir/bin"
}

write_script() {  # <dir> <script> <body>
  local dir=$1 script=$2 body=$3
  cat > "$dir/tests/$script" <<SH
#!/usr/bin/env bash
set -u
$body
SH
  chmod +x "$dir/tests/$script"
}

run_lane() {  # <dir> <lane> [manifest]
  local dir=$1 lane=$2 manifest
  manifest=${3:-$dir/manifest.tsv}
  FM_TEST_LANE_TEST_DIR="$dir/tests" \
    FM_TEST_LANE_MANIFEST="$manifest" \
    "$RUNNER" "$lane" > "$dir/stdout" 2> "$dir/stderr"
}

test_requires_known_lane() {
  local dir rc
  dir="$TMP_ROOT/known-lane"; make_fixture "$dir"
  write_script "$dir" alpha.test.sh 'exit 0'
  printf 'unit\talpha.test.sh\tfixture\n' > "$dir/manifest.tsv"

  run_lane "$dir" nope
  rc=$?

  expect_code 2 "$rc" "unknown lane must exit 2"
  assert_contains "$(cat "$dir/stderr")" "usage: fm-test-lane.sh <unit|integration|e2e>" \
    "unknown lane must print usage"
  pass "fm-test-lane: rejects unknown lanes before running tests"
}

test_manifest_must_cover_each_script_once() {
  local dir rc
  dir="$TMP_ROOT/manifest-coverage"; make_fixture "$dir"
  write_script "$dir" alpha.test.sh 'exit 0'
  write_script "$dir" beta.test.sh 'exit 0'

  printf 'unit\talpha.test.sh\tfixture\n' > "$dir/manifest.tsv"
  run_lane "$dir" unit
  rc=$?
  expect_code 2 "$rc" "missing manifest entry must exit 2"
  assert_contains "$(cat "$dir/stderr")" "missing lane classification: beta.test.sh" \
    "missing script must be named"

  printf 'unit\talpha.test.sh\tfixture\nintegration\talpha.test.sh\tdup\nunit\tbeta.test.sh\tfixture\n' > "$dir/manifest.tsv"
  run_lane "$dir" unit
  rc=$?
  expect_code 2 "$rc" "duplicate manifest entry must exit 2"
  assert_contains "$(cat "$dir/stderr")" "duplicate lane classification: alpha.test.sh" \
    "duplicate script must be named"

  printf 'unit\talpha.test.sh\tfixture\nunit\tbeta.test.sh\tfixture\nunit\tghost.test.sh\tstale\n' > "$dir/manifest.tsv"
  run_lane "$dir" unit
  rc=$?
  expect_code 2 "$rc" "stale manifest entry must exit 2"
  assert_contains "$(cat "$dir/stderr")" "stale lane classification: ghost.test.sh" \
    "stale script must be named"

  pass "fm-test-lane: validates manifest completeness, uniqueness, and freshness"
}

test_runs_selected_lane_in_manifest_order_with_timing_markers() {
  local dir rc out order
  dir="$TMP_ROOT/ordered"; make_fixture "$dir"
  write_script "$dir" alpha.test.sh "printf 'alpha\n' >> '$dir/order.log'"
  write_script "$dir" beta.test.sh "printf 'beta\n' >> '$dir/order.log'"
  write_script "$dir" gamma.test.sh "printf 'gamma\n' >> '$dir/order.log'"
  {
    printf 'unit\tbeta.test.sh\tfixture\n'
    printf 'integration\tgamma.test.sh\tfixture\n'
    printf 'unit\talpha.test.sh\tfixture\n'
  } > "$dir/manifest.tsv"

  run_lane "$dir" unit
  rc=$?
  expect_code 0 "$rc" "unit lane should pass"
  out=$(cat "$dir/stdout")
  order=$(cat "$dir/order.log")
  [ "$order" = $'beta\nalpha' ] || fail "unit lane did not run in manifest order: $order"
  assert_contains "$out" "lane-start lane=unit" "lane start marker missing"
  assert_contains "$out" "script-start lane=unit script=tests/beta.test.sh" "first script start marker missing"
  assert_contains "$out" "script-end lane=unit script=tests/beta.test.sh status=0 elapsed=" "script end timing missing"
  assert_contains "$out" "lane-end lane=unit status=0 elapsed=" "lane end timing missing"
  assert_not_contains "$out" "gamma.test.sh" "integration script leaked into unit lane"
  pass "fm-test-lane: runs selected scripts in manifest order with timing markers"
}

test_propagates_nonzero_with_failure_identity() {
  local dir rc out
  dir="$TMP_ROOT/nonzero"; make_fixture "$dir"
  write_script "$dir" alpha.test.sh 'exit 0'
  write_script "$dir" beta.test.sh 'exit 7'
  printf 'unit\talpha.test.sh\tfixture\nunit\tbeta.test.sh\tfixture\n' > "$dir/manifest.tsv"

  run_lane "$dir" unit
  rc=$?

  expect_code 7 "$rc" "runner must return the failing script status"
  out=$(cat "$dir/stdout")
  assert_contains "$out" "script-end lane=unit script=tests/beta.test.sh status=7 elapsed=" \
    "failing script marker missing"
  assert_contains "$out" "lane-end lane=unit status=7 failed=tests/beta.test.sh elapsed=" \
    "lane failure identity missing"
  pass "fm-test-lane: propagates nonzero status with failure identity"
}

test_requires_known_lane
test_manifest_must_cover_each_script_once
test_runs_selected_lane_in_manifest_order_with_timing_markers
test_propagates_nonzero_with_failure_identity
