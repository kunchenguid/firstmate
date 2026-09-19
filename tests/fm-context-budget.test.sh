#!/usr/bin/env bash
# Behavior tests for fm-context-budget.sh: the always-loaded instruction budget
# passes under it, fails clearly over it with the routing guidance, refuses a
# missing or malformed input instead of guessing, and counts only the files
# every turn actually pays for.
#
# Fixtures drive every assertion through FM_ROOT_OVERRIDE so this suite pins the
# guard's logic rather than the current size of the repo's own AGENTS.md; the
# real surface is checked by the CI invariants job that runs the script itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUDGET="$ROOT/bin/fm-context-budget.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-budget)

# make_root <name> <agents-bytes> [claude-bytes] echoes a fixture code root.
make_root() {
  local name=$1 agents_bytes=$2 claude_bytes=${3:-30} root
  root="$TMP_ROOT/$name"
  mkdir -p "$root"
  head -c "$agents_bytes" /dev/zero | tr '\0' 'a' > "$root/AGENTS.md"
  head -c "$claude_bytes" /dev/zero | tr '\0' 'b' > "$root/CLAUDE.md"
  printf '%s\n' "$root"
}

run_budget() {
  local root=$1 budget=$2
  shift 2
  FM_ROOT_OVERRIDE="$root" FM_CONTEXT_BUDGET_TOKENS="$budget" "$BUDGET" "$@"
}

test_under_budget_passes() {
  local root out status=0
  # 3000 + 30 bytes -> ceil(3000/3) + ceil(30/3) = 1010 estimated tokens.
  root=$(make_root under 3000)
  out=$(run_budget "$root" 2000 check 2>&1) || status=$?
  expect_code 0 "$status" "a surface inside the budget must pass"
  assert_contains "$out" "context-budget: OK" "passing run did not report OK"
  assert_contains "$out" "1010" "passing run did not report the measured total"
  pass "a surface inside the budget passes and reports its measurement"
}

test_over_budget_fails_with_routing_guidance() {
  local root out status=0
  root=$(make_root over 30000)
  out=$(run_budget "$root" 2000 check 2>&1) || status=$?
  expect_code 1 "$status" "a surface over the budget must fail"
  assert_contains "$out" "context-budget: FAIL" "over-budget run did not report FAIL"
  assert_contains "$out" "over budget" "over-budget run did not say it was over budget"
  assert_contains "$out" "firstmate-coding-guidelines" \
    "over-budget failure must point at the knowledge-placement decision tree"
  assert_contains "$out" ".agents/skills/" \
    "over-budget failure must name where situational procedure belongs"
  pass "an over-budget surface fails clearly and routes the fix to a skill"
}

test_boundary_is_inclusive() {
  local root status=0
  # 3000 + 30 bytes measures exactly 1010 estimated tokens.
  root=$(make_root boundary 3000)
  run_budget "$root" 1010 check >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a surface exactly at the budget must pass"

  status=0
  run_budget "$root" 1009 check >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "one estimated token over the budget must fail"
  pass "the budget boundary is inclusive and one token over fails"
}

test_only_always_loaded_files_are_counted() {
  local root out status=0
  root=$(make_root skills-ignored 3000)
  # A large skill must not count: its cost is paid only when it is loaded.
  mkdir -p "$root/.agents/skills/huge"
  head -c 400000 /dev/zero | tr '\0' 'c' > "$root/.agents/skills/huge/SKILL.md"
  out=$(run_budget "$root" 2000 check 2>&1) || status=$?
  expect_code 0 "$status" "an on-demand skill must not consume the always-loaded budget"
  assert_not_contains "$out" "SKILL.md" "the report must not list on-demand skills"
  pass "on-demand skills are excluded from the always-loaded budget"
}

test_missing_always_loaded_file_refuses() {
  local root err status=0
  root=$(make_root missing 3000)
  rm -f "$root/AGENTS.md"
  err=$(run_budget "$root" 2000 check 2>&1) || status=$?
  expect_code 2 "$status" "a missing always-loaded file must refuse, not pass"
  assert_contains "$err" "missing" "missing-file refusal did not name the problem"
  assert_contains "$err" "AGENTS.md" "missing-file refusal did not name the file"
  pass "a missing always-loaded file refuses instead of measuring nothing"
}

test_malformed_budget_refuses() {
  local root err status=0
  root=$(make_root malformed 3000)
  err=$(run_budget "$root" "not-a-number" check 2>&1) || status=$?
  expect_code 2 "$status" "a malformed budget must refuse, not default silently"
  assert_contains "$err" "positive integer" "malformed budget refusal was not specific"
  pass "a malformed budget refuses instead of guessing a default"
}

test_report_never_fails_and_budget_prints_value() {
  local root out status=0
  root=$(make_root report-mode 30000)
  out=$(run_budget "$root" 2000 report 2>&1) || status=$?
  expect_code 0 "$status" "report mode must not fail even when over budget"
  assert_not_contains "$out" "FAIL" "report mode must not emit a verdict"

  status=0
  out=$(run_budget "$root" 2000 budget 2>&1) || status=$?
  expect_code 0 "$status" "budget mode must succeed"
  assert_contains "$out" "2000" "budget mode did not print the effective budget"
  pass "report mode measures without a verdict and budget mode prints the value"
}

test_under_budget_passes
test_over_budget_fails_with_routing_guidance
test_boundary_is_inclusive
test_only_always_loaded_files_are_counted
test_missing_always_loaded_file_refuses
test_malformed_budget_refuses
test_report_never_fails_and_budget_prints_value
