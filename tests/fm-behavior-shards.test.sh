#!/usr/bin/env bash
# Behavior tests for deterministic duration-balanced CI sharding and the
# post-execution completeness guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHARDER="$ROOT/bin/fm-behavior-shards.sh"
DURATIONS="$ROOT/tests/behavior-test-durations.tsv"
CI="$ROOT/.github/workflows/ci.yml"
TEARDOWN_SUITE="$ROOT/tests/fm-teardown-suite.sh"
SHARD_COUNT=8

test_checked_in_plan_is_complete_balanced_and_deterministic() {
  local tmp plan_a plan_b inventory planned out
  tmp=$(fm_test_tmproot fm-behavior-plan)
  plan_a="$tmp/plan-a.tsv"
  plan_b="$tmp/plan-b.tsv"
  inventory="$tmp/inventory.txt"
  planned="$tmp/planned.txt"

  out=$("$SHARDER" --check "$SHARD_COUNT") \
    || fail "checked-in behavior shard plan failed its coverage guard"
  assert_contains "$out" "FM_BEHAVIOR_PLAN ok tests=92 shards=8" \
    "coverage guard did not report the complete 92-test inventory"
  "$SHARDER" --plan "$SHARD_COUNT" > "$plan_a"
  "$SHARDER" --plan "$SHARD_COUNT" > "$plan_b"
  cmp -s "$plan_a" "$plan_b" || fail "same durations produced different shard plans"

  find "$ROOT/tests" -maxdepth 1 -type f -name '*.test.sh' -print \
    | sed "s#^$ROOT/##" | LC_ALL=C sort > "$inventory"
  cut -f3 "$plan_a" | LC_ALL=C sort > "$planned"
  cmp -s "$inventory" "$planned" \
    || fail "planned shard union did not equal tests/*.test.sh"
  [ "$(cut -f3 "$plan_a" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "a test was assigned to more than one shard"
  [ "$(awk -F '\t' '{ load[$1] += $2 } END { max=0; for (s in load) if (load[s] > max) max=load[s]; print max }' "$plan_a")" -le 675000 ] \
    || fail "duration-balanced plan exceeds the measured single-test floor"
  pass "checked-in LPT plan is deterministic, complete, disjoint, and duration-balanced"
}

test_plan_refuses_missing_and_duplicate_duration_entries() {
  local tmp missing duplicate out rc
  tmp=$(fm_test_tmproot fm-behavior-plan-invalid)
  missing="$tmp/missing.tsv"
  duplicate="$tmp/duplicate.tsv"
  grep -vF $'\ttests/fm-x-mode.test.sh' "$DURATIONS" > "$missing"
  cp "$DURATIONS" "$duplicate"
  grep -F $'\ttests/fm-x-mode.test.sh' "$DURATIONS" >> "$duplicate"

  rc=0
  out=$(FM_BEHAVIOR_DURATIONS_FILE="$missing" "$SHARDER" --check "$SHARD_COUNT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "coverage guard accepted a missing duration entry"
  assert_contains "$out" "duration inventory does not exactly match" \
    "missing-entry refusal did not name the inventory mismatch"

  rc=0
  out=$(FM_BEHAVIOR_DURATIONS_FILE="$duplicate" "$SHARDER" --check "$SHARD_COUNT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "coverage guard accepted a duplicate duration entry"
  assert_contains "$out" "duplicate duration paths" \
    "duplicate-entry refusal did not name the duplicate"
  pass "coverage guard rejects missing and duplicate duration entries"
}

make_runner_fixture() {
  local root=$1
  mkdir -p "$root/bin" "$root/tests"
  cp "$SHARDER" "$root/bin/fm-behavior-shards.sh"
  chmod +x "$root/bin/fm-behavior-shards.sh"
  cat > "$root/tests/one.test.sh" <<'SH'
#!/usr/bin/env bash
printf 'one\n' >> "${FM_FIXTURE_EXECUTED:?}"
printf 'ok - fixture one\n'
SH
  cat > "$root/tests/two.test.sh" <<'SH'
#!/usr/bin/env bash
printf 'two\n' >> "${FM_FIXTURE_EXECUTED:?}"
printf 'ok - fixture two\n'
SH
  chmod +x "$root/tests/one.test.sh" "$root/tests/two.test.sh"
  cat > "$root/tests/behavior-test-durations.tsv" <<'EOF_DURATIONS'
10	tests/one.test.sh
20	tests/two.test.sh
EOF_DURATIONS
}

test_runner_executes_every_assigned_test_and_records_failures() {
  local tmp fixture manifest executed out rc
  tmp=$(fm_test_tmproot fm-behavior-run)
  fixture="$tmp/fixture"
  manifest="$tmp/executed-1.tsv"
  executed="$tmp/executed.log"
  make_runner_fixture "$fixture"
  : > "$executed"

  FM_FIXTURE_EXECUTED="$executed" "$fixture/bin/fm-behavior-shards.sh" \
    --run 1 1 "$manifest" > "$tmp/success.out" \
    || fail "fixture shard failed despite two passing tests"
  [ "$(wc -l < "$manifest" | tr -d ' ')" -eq 2 ] \
    || fail "successful shard manifest did not record both tests"
  [ "$(wc -l < "$executed" | tr -d ' ')" -eq 2 ] \
    || fail "successful shard did not execute both assigned tests"

  cat > "$fixture/tests/two.test.sh" <<'SH'
#!/usr/bin/env bash
printf 'two\n' >> "${FM_FIXTURE_EXECUTED:?}"
printf 'not ok - fixture two\n' >&2
exit 7
SH
  chmod +x "$fixture/tests/two.test.sh"
  : > "$executed"
  rc=0
  out=$(FM_FIXTURE_EXECUTED="$executed" "$fixture/bin/fm-behavior-shards.sh" \
    --run 1 1 "$manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "shard runner hid a failing test"
  [ "$(wc -l < "$manifest" | tr -d ' ')" -eq 2 ] \
    || fail "failing shard stopped before recording every assigned test"
  [ "$(awk -F '\t' '$3 == 7 { count++ } END { print count + 0 }' "$manifest")" -eq 1 ] \
    || fail "failing test exit code was not preserved in the manifest"
  assert_contains "$out" "FM_BEHAVIOR_TEST_BEGIN tests/two.test.sh" \
    "failure output did not name the failing test"
  assert_contains "$out" "FM_BEHAVIOR_SHARD_RESULT shard=1/1 tests=2 failed=1" \
    "failure output did not identify the failing shard"
  pass "shard runner names tests, runs the full assignment, and preserves failures"
}

test_record_refreshes_complete_fixture_timings() {
  local tmp fixture recorded executed
  tmp=$(fm_test_tmproot fm-behavior-record)
  fixture="$tmp/fixture"
  recorded="$tmp/refreshed.tsv"
  executed="$tmp/executed.log"
  make_runner_fixture "$fixture"
  : > "$executed"
  FM_FIXTURE_EXECUTED="$executed" "$fixture/bin/fm-behavior-shards.sh" \
    --record "$recorded" > "$tmp/record.out" \
    || fail "timing refresh failed for passing fixture tests"
  grep -Fq $'\ttests/one.test.sh' "$recorded" \
    || fail "timing refresh omitted fixture one"
  grep -Fq $'\ttests/two.test.sh' "$recorded" \
    || fail "timing refresh omitted fixture two"
  [ "$(grep -c $'^[1-9][0-9]*\ttests/' "$recorded")" -eq 2 ] \
    || fail "timing refresh did not emit positive milliseconds for both tests"
  pass "timing data is checked in and refreshable through the real runner"
}

write_complete_manifests() {
  local plan=$1 dir=$2 shard ms path
  mkdir -p "$dir"
  while IFS=$'\t' read -r shard ms path; do
    printf '%s\t%s\t0\t%s\n' "$shard" "$path" "$ms" >> "$dir/executed-$shard.tsv"
  done < "$plan"
}

test_post_run_guard_requires_the_exact_executed_union() {
  local tmp plan good missing duplicate failed out rc first_file first_row
  tmp=$(fm_test_tmproot fm-behavior-verify)
  plan="$tmp/plan.tsv"
  good="$tmp/good"
  missing="$tmp/missing"
  duplicate="$tmp/duplicate"
  failed="$tmp/failed"
  "$SHARDER" --plan "$SHARD_COUNT" > "$plan"
  write_complete_manifests "$plan" "$good"
  out=$("$SHARDER" --verify "$SHARD_COUNT" "$good") \
    || fail "post-run guard rejected the exact complete manifest union"
  assert_contains "$out" "FM_BEHAVIOR_COMPLETENESS ok tests=92 shards=8" \
    "post-run guard did not report complete execution"

  cp -R "$good" "$missing"
  first_file=$(find "$missing" -type f -name 'executed-*.tsv' -print \
    | while IFS= read -r file; do printf '%s\t%s\n' "$(wc -l < "$file" | tr -d ' ')" "$file"; done \
    | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 | head -n 1 | cut -f2-)
  sed '$d' "$first_file" > "$first_file.tmp"
  mv "$first_file.tmp" "$first_file"
  rc=0
  out=$("$SHARDER" --verify "$SHARD_COUNT" "$missing" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "post-run guard accepted a missing execution row"
  assert_contains "$out" "executed shard union differs" \
    "missing-execution refusal did not name the union mismatch"

  cp -R "$good" "$duplicate"
  first_file=$(find "$duplicate" -type f -name 'executed-*.tsv' | LC_ALL=C sort | head -n 1)
  first_row=$(head -n 1 "$first_file")
  printf '%s\n' "$first_row" >> "$first_file"
  rc=0
  "$SHARDER" --verify "$SHARD_COUNT" "$duplicate" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "post-run guard accepted a duplicate execution row"

  cp -R "$good" "$failed"
  first_file=$(find "$failed" -type f -name 'executed-*.tsv' | LC_ALL=C sort | head -n 1)
  awk -F '\t' -v OFS='\t' 'NR == 1 { $3 = 9 } { print }' "$first_file" > "$first_file.tmp"
  mv "$first_file.tmp" "$first_file"
  rc=0
  out=$("$SHARDER" --verify "$SHARD_COUNT" "$failed" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "post-run guard hid a recorded test failure"
  assert_contains "$out" "failed test: shard=" \
    "recorded failure did not name its shard and test"
  pass "post-run guard rejects missing, duplicate, and failed executions"
}

test_ci_wires_matrix_isolation_timeout_and_union_verification() {
  # shellcheck disable=SC2016  # The GitHub expression is a literal YAML needle.
  assert_grep 'name: Behavior tests (shard ${{ matrix.shard }}/8)' "$CI" \
    "CI does not expose the failing shard in the job name"
  assert_grep 'shard: [1, 2, 3, 4, 5, 6, 7, 8]' "$CI" \
    "CI does not launch every deterministic shard"
  [ "$(grep -Fc 'timeout-minutes: 15' "$CI")" -eq 1 ] \
    || fail "behavior matrix must have one 15-minute per-shard timeout"
  # shellcheck disable=SC2016  # Workflow shell variables must remain literal.
  assert_grep 'echo "TMPDIR=$shard_root/tmp"' "$CI" \
    "CI does not give each shard a private temp root"
  # shellcheck disable=SC2016  # Workflow shell variables must remain literal.
  assert_grep 'echo "TMUX_TMPDIR=$shard_root/tmux"' "$CI" \
    "CI does not give each shard a private tmux socket root"
  # shellcheck disable=SC2016  # Workflow shell variables must remain literal.
  assert_grep 'bin/fm-behavior-shards.sh --verify 8 "$RUNNER_TEMP/behavior-manifests"' "$CI" \
    "CI does not verify the union of executed manifests"
  assert_grep 'overwrite: true' "$CI" \
    "CI cannot refresh a failed shard manifest during a failed-jobs rerun"
  assert_no_grep 'for test_script in tests/*.test.sh' "$CI" \
    "CI retained the 57-minute serial behavior loop"
  pass "CI wires eight named isolated shards, a tight timeout, and executed-union verification"
}

test_teardown_partition_preserves_every_full_suite_case() {
  local tmp definitions listed focused expected_focused wrapper_a wrapper_b
  tmp=$(fm_test_tmproot fm-teardown-partition)
  definitions="$tmp/definitions.txt"
  listed="$tmp/listed.txt"
  focused="$tmp/focused.txt"
  expected_focused="$tmp/expected-focused.txt"
  wrapper_a="$ROOT/tests/fm-teardown-a.test.sh"
  wrapper_b="$ROOT/tests/fm-teardown-b.test.sh"

  sed -n 's/^\(test_[A-Za-z0-9_]*\)() {.*/\1/p' "$TEARDOWN_SUITE" \
    | LC_ALL=C sort > "$definitions"
  awk '
    /^TEARDOWN_FULL_SUITE_CASES=\($/ { in_cases = 1; next }
    in_cases && /^\)$/ { exit }
    in_cases && $1 ~ /^test_[A-Za-z0-9_]+$/ { print $1 }
  ' "$TEARDOWN_SUITE" > "$listed"
  [ "$(wc -l < "$listed" | tr -d ' ')" -eq 111 ] \
    || fail "teardown partition does not retain all 111 normal-run cases"
  [ "$(LC_ALL=C sort "$listed" | uniq -d | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "teardown partition lists a normal-run case more than once"
  comm -13 "$definitions" <(LC_ALL=C sort "$listed") > "$tmp/undefined.txt"
  [ ! -s "$tmp/undefined.txt" ] \
    || fail "teardown partition lists an undefined test function"
  comm -23 "$definitions" <(LC_ALL=C sort "$listed") > "$focused"
  printf '%s\n' \
    test_bounded_runner_preserves_command_status_125 \
    test_pr_check_backfills_legacy_generation_and_records_state \
    test_pr_check_backfills_legacy_generation_before_race_check \
    | LC_ALL=C sort > "$expected_focused"
  cmp -s "$expected_focused" "$focused" \
    || fail "teardown partition dropped or absorbed a focused-only case"
  [ "$(awk 'NR % 2 == 1 { count++ } END { print count + 0 }' "$listed")" -eq 56 ] \
    || fail "teardown partition A does not own exactly 56 cases"
  [ "$(awk 'NR % 2 == 0 { count++ } END { print count + 0 }' "$listed")" -eq 55 ] \
    || fail "teardown partition B does not own exactly 55 cases"
  assert_grep 'FM_TEST_PART_INDEX=1 FM_TEST_PART_TOTAL=2' "$wrapper_a" \
    "teardown wrapper A does not select partition 1/2"
  assert_grep 'FM_TEST_PART_INDEX=2 FM_TEST_PART_TOTAL=2' "$wrapper_b" \
    "teardown wrapper B does not select partition 2/2"
  [ ! -e "$ROOT/tests/fm-teardown.test.sh" ] \
    || fail "the unsplit teardown test remains in the behavior inventory"
  pass "teardown wrappers preserve all 111 normal cases and three focused-only cases"
}

test_checked_in_plan_is_complete_balanced_and_deterministic
test_plan_refuses_missing_and_duplicate_duration_entries
test_runner_executes_every_assigned_test_and_records_failures
test_record_refreshes_complete_fixture_timings
test_post_run_guard_requires_the_exact_executed_union
test_ci_wires_matrix_isolation_timeout_and_union_verification
test_teardown_partition_preserves_every_full_suite_case
