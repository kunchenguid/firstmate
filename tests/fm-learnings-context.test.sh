#!/usr/bin/env bash
# Behavior tests for the topic-split learnings context and its budgets:
# session start prints only the index, topic files stay on demand, a home that
# predates the split still gets every learning, each topic file is bounded on
# its own, and `check` actually fails on a real overrun rather than only
# validating that a config value parses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUDGET="$ROOT/bin/fm-startup-memory-budget.sh"
SUPERVISION="$ROOT/bin/fm-supervision-instructions.sh"
TMP_ROOT=$(fm_test_tmproot fm-learnings-context)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '5000\n' > "$home/config/startup-memory-budget"
  printf '# captain\n' > "$home/data/captain.md"
  printf '%s\n' "$home"
}

split_home() {
  local home=$1
  mkdir -p "$home/data/learnings"
  printf '# index\n\nrouter row: github.md when the task touches repos\n' \
    > "$home/data/learnings/index.md"
  printf '# github\n\n- a repo gotcha\n' > "$home/data/learnings/github.md"
  printf '# aws\n\n- an aws gotcha\n' > "$home/data/learnings/aws-terraform.md"
}

test_report_measures_index_not_topics() {
  local home out
  home=$(make_home index-only)
  split_home "$home"

  out=$(FM_HOME="$home" "$BUDGET" report) || fail "report failed on a split home"
  assert_contains "$out" 'file=data/learnings/index.md' \
    "the startup class must measure the learnings index"
  assert_not_contains "$out" 'file=data/learnings/github.md' \
    "a topic file must not be counted in the always-loaded startup class"
  assert_contains "$out" 'topic=data/learnings/github.md' \
    "each topic file must be accounted for in the topic class"
  assert_contains "$out" 'topic_files=2' "report did not count the topic files"
  pass "the index is startup-class and topic files are budgeted separately"
}

test_flat_home_still_measured() {
  local home out
  home=$(make_home flat)
  printf '# learnings\n\n- a flat gotcha\n' > "$home/data/learnings.md"

  out=$(FM_HOME="$home" "$BUDGET" report) || fail "report failed on a flat home"
  assert_contains "$out" 'file=data/learnings.md' \
    "a home that predates the split must still have its learnings measured"
  pass "a pre-split home still accounts for its flat learnings file"
}

test_index_wins_over_flat_file() {
  local home out
  home=$(make_home both)
  split_home "$home"
  printf '# stale flat copy\n' > "$home/data/learnings.md"

  out=$(FM_HOME="$home" "$BUDGET" report) || fail "report failed when both layouts exist"
  assert_contains "$out" 'file=data/learnings/index.md' \
    "the split layout must win when both exist"
  assert_not_contains "$out" 'file=data/learnings.md ' \
    "the flat file must not also be counted once the split layout exists"
  pass "the split layout takes precedence over a leftover flat file"
}

test_check_fails_on_oversized_topic() {
  local home status=0 out
  home=$(make_home fat-topic)
  split_home "$home"
  # Comfortably past the 1500-token default at ceil(bytes/3).
  head -c 9000 /dev/zero | tr '\0' 'x' > "$home/data/learnings/github.md"

  out=$(FM_HOME="$home" "$BUDGET" check 2>&1) || status=$?
  expect_code 1 "$status" "an oversized topic file must fail the check"
  assert_contains "$out" 'topic=data/learnings/github.md' "check did not name the offending topic"
  assert_contains "$out" 'status=over-budget' "check did not mark the topic over budget"
  assert_contains "$out" 'stow' "check did not point at the curation owner"
  pass "check fails and names the topic file that broke its own budget"
}

test_check_fails_on_oversized_startup_class() {
  local home status=0 out
  home=$(make_home fat-startup)
  split_home "$home"
  head -c 30000 /dev/zero | tr '\0' 'x' > "$home/data/captain.md"

  out=$(FM_HOME="$home" "$BUDGET" check 2>&1) || status=$?
  expect_code 1 "$status" "an oversized always-loaded class must fail the check"
  assert_contains "$out" 'budget_status=over-budget' "check did not surface the startup overrun"
  pass "check fails when the always-loaded startup class is over budget"
}

test_check_passes_within_budget_and_report_never_fails() {
  local home status=0
  home=$(make_home healthy)
  split_home "$home"

  FM_HOME="$home" "$BUDGET" check >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a healthy home must pass the check"

  status=0
  head -c 9000 /dev/zero | tr '\0' 'x' > "$home/data/learnings/github.md"
  FM_HOME="$home" "$BUDGET" report >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "report must never fail, even over budget"
  pass "check gates and report only measures"
}

test_topic_budget_override_is_honored_and_validated() {
  local home status=0 out
  home=$(make_home override)
  split_home "$home"
  head -c 9000 /dev/zero | tr '\0' 'x' > "$home/data/learnings/github.md"

  printf '5000\n' > "$home/config/learning-topic-budget"
  FM_HOME="$home" "$BUDGET" check >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a raised topic budget must be honored"

  printf 'not-a-number\n' > "$home/config/learning-topic-budget"
  status=0
  out=$(FM_HOME="$home" "$BUDGET" report 2>&1) || status=$?
  expect_code 2 "$status" "a malformed topic budget must be an error, not a silent default"
  assert_contains "$out" 'learning-topic-budget' "the error did not name the offending config file"
  pass "the topic budget override is honored and a malformed one refuses"
}

test_supervision_startup_brief_omits_static_body() {
  local full brief
  full=$("$SUPERVISION" --harness claude) || fail "full supervision render failed"
  brief=$("$SUPERVISION" --harness claude --startup-brief) \
    || fail "startup-brief supervision render failed"

  assert_contains "$brief" 'Current state:' "the brief dropped the dynamic current-state lines"
  assert_contains "$brief" 'Ordinary wake:' "the brief dropped the ordinary-wake ownership line"
  assert_contains "$brief" 'docs/supervision-protocols/claude.md' \
    "the brief must name the authoritative protocol source"
  assert_contains "$brief" 'bin/fm-supervision-instructions.sh' \
    "the brief must name the command that retrieves the full protocol"
  [ "${#brief}" -lt "${#full}" ] \
    || fail "the brief must be smaller than the full render"

  # The full body must still be retrievable for a turn that actually supervises.
  assert_contains "$full" 'bin/fm-wake-drain.sh' "the full protocol lost its drain instruction"
  pass "startup-brief keeps dynamic state and points at the retrievable full protocol"
}

test_report_measures_index_not_topics
test_flat_home_still_measured
test_index_wins_over_flat_file
test_check_fails_on_oversized_topic
test_check_fails_on_oversized_startup_class
test_check_passes_within_budget_and_report_never_fails
test_topic_budget_override_is_honored_and_validated
test_supervision_startup_brief_omits_static_body
