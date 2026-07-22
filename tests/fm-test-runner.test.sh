#!/usr/bin/env bash
# Regression coverage for canonical-runner sharding and manifest failure propagation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

make_fixture() {
  local fixture
  fixture=$(fm_test_tmproot fm-test-shards)
  mkdir -p "$fixture/bin" "$fixture/tests"
  cp "$RUNNER" "$fixture/bin/fm-test-run.sh"
  chmod +x "$fixture/bin/fm-test-run.sh"
  printf '%s\n' "$fixture"
}

write_test() {
  local fixture=$1 name=$2 body=$3
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$fixture/tests/$name"
  chmod +x "$fixture/tests/$name"
}

test_manifest_completeness_and_duplicates() {
  local fixture out rc
  fixture=$(make_fixture)
  write_test "$fixture" a.test.sh 'exit 0'
  write_test "$fixture" b.test.sh 'exit 0'
  printf '1\ttests/a.test.sh\n' >"$fixture/tests/behavior-shards.txt"
  rc=0
  out=$(cd "$fixture" && bin/fm-test-run.sh --list --shard 1/4 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "runner accepted a manifest missing a test"
  assert_contains "$out" 'manifest does not assign test: tests/b.test.sh' "runner did not name the missing test"

  printf '1\ttests/a.test.sh\n2\ttests/a.test.sh\n3\ttests/b.test.sh\n' >"$fixture/tests/behavior-shards.txt"
  rc=0
  out=$(cd "$fixture" && bin/fm-test-run.sh --list --shard 1/4 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "runner accepted a duplicate assignment"
  assert_contains "$out" 'manifest assigns a test more than once: tests/a.test.sh' "runner did not name the duplicate test"
  pass "behavior manifest rejects missing and duplicate assignments"
}

test_shard_selection_and_failure_propagation() {
  local fixture out rc first_end second_end third_end
  fixture=$(make_fixture)
  write_test "$fixture" a.test.sh "printf 'alpha\\n'; exit 1"
  write_test "$fixture" b.test.sh "printf 'bravo\\n'; exit 2"
  write_test "$fixture" c.test.sh "printf 'charlie\\n'; exit 0"
  write_test "$fixture" d.test.sh "printf 'delta\\n'; exit 0"
  printf '1\ttests/a.test.sh\n1\ttests/b.test.sh\n2\ttests/c.test.sh\n1\ttests/d.test.sh\n' >"$fixture/tests/behavior-shards.txt"

  rc=0
  out=$(cd "$fixture" && bin/fm-test-run.sh --shard 1/4 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "runner hid a test failure"
  assert_contains "$out" 'alpha' "runner omitted the first failure"
  assert_contains "$out" 'bravo' "runner omitted the second failure"
  assert_contains "$out" 'delta' "runner stopped before a later passing test"
  assert_not_contains "$out" 'charlie' "runner executed a different shard"
  assert_contains "$out" 'FM_TEST_SUMMARY total=3 failed=2' "runner summary did not aggregate both failures"
  first_end=$(printf '%s\n' "$out" | grep -n '^FM_TEST_END .*tests/a.test.sh exit=1 ' | cut -d: -f1)
  second_end=$(printf '%s\n' "$out" | grep -n '^FM_TEST_END .*tests/b.test.sh exit=2 ' | cut -d: -f1)
  third_end=$(printf '%s\n' "$out" | grep -n '^FM_TEST_END .*tests/d.test.sh exit=0 ' | cut -d: -f1)
  [ "$first_end" -lt "$second_end" ] && [ "$second_end" -lt "$third_end" ] \
    || fail "failure aggregation did not preserve manifest order"
  pass "a shard runs only its assignments and propagates failures after completing them"
}

test_real_manifest_matches_inventory() {
  local listed inventory shard
  listed=$(
    for shard in 1 2 3 4; do
      "$RUNNER" --list --shard "$shard/4"
    done | LC_ALL=C sort
  )
  inventory=$(find "$ROOT/tests" -maxdepth 1 -type f -name '*.test.sh' -print | sed "s#^$ROOT/##" | LC_ALL=C sort)
  [ "$listed" = "$inventory" ] || fail "real behavior manifest differs from the complete test inventory"
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = "$(printf '%s\n' "$inventory" | wc -l | tr -d ' ')" ] \
    || fail "real behavior manifest contains a duplicate"
  pass "real behavior manifest assigns every suite exactly once"
}

test_ci_uses_every_owned_shard() {
  local ci="$ROOT/.github/workflows/ci.yml"
  assert_grep 'shard: [1, 2, 3, 4]' "$ci" "CI must schedule every behavior shard"
  # shellcheck disable=SC2016 # GitHub's expression must remain literal test data.
  assert_grep 'bin/fm-test-run.sh --shard "${{ matrix.shard }}/4"' "$ci" "CI must use the canonical runner"
  assert_no_grep 'for test_script in tests/*.test.sh' "$ci" "CI must not duplicate behavior inventory"
  assert_grep 'name: Preserve the canonical aggregate check' "$ci" "CI must preserve one aggregate behavior result"
  # shellcheck disable=SC2016 # GitHub's expression must remain literal test data.
  assert_grep 'SHARD_RESULT: ${{ needs.tests.result }}' "$ci" "aggregate behavior must fail with any shard"
  assert_grep '/bin/bash bin/fm-test-run.sh --list --shard 1/4' "$ci" "stock macOS Bash must validate shard listing"
  pass "CI schedules every shard, aggregates failure, and lists with stock macOS Bash"
}

test_manifest_completeness_and_duplicates
test_shard_selection_and_failure_propagation
test_real_manifest_matches_inventory
test_ci_uses_every_owned_shard
