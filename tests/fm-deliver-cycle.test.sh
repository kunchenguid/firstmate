#!/usr/bin/env bash
# Behavior tests for bin/fm-deliver-cycle.sh, the no-argument delivery pass the
# opt-in restricted Pi supervision runs: it arms merge monitoring only for a
# ship task whose current status is exactly one ready change, cleans up only a
# task whose recorded change the merge monitor confirmed merged, never passes
# --force, and leaves every missing or ambiguous record alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deliver-cycle)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE

# One copy of bin/ whose two engine commands are recording stubs, so each case
# observes exactly what the pass asked the engine to do in its own home.
FIXTURE_BIN="$TMP_ROOT/root/bin"
mkdir -p "$TMP_ROOT/root"
cp -R "$ROOT/bin" "$FIXTURE_BIN"
cat > "$FIXTURE_BIN/fm-pr-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'pr-check %s\n' "$*" >> "$FM_HOME/calls"
if [ -e "$FM_HOME/refuse-pr-check" ]; then
  echo "error: refused by the engine" >&2
  exit 1
fi
printf 'pr=%s\n' "$2" >> "$FM_HOME/state/$1.meta"
echo "armed"
SH
cat > "$FIXTURE_BIN/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s\n' "$*" >> "$FM_HOME/calls"
if [ -e "$FM_HOME/refuse-teardown" ]; then
  echo "REFUSED: the worktree holds work that has not landed" >&2
  exit 1
fi
rm -f "$FM_HOME/state/$1.meta"
echo "torn down"
SH
chmod +x "$FIXTURE_BIN/fm-pr-check.sh" "$FIXTURE_BIN/fm-teardown.sh"

PR7=https://github.com/acme/widget/pull/7
PR8=https://github.com/acme/widget/pull/8

new_home() {  # <name> -> home path
  local home="$TMP_ROOT/homes/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_cycle() {  # <home> [args...] -> sets OUT and RC
  local home=$1
  shift
  OUT=$(FM_HOME="$home" "$FIXTURE_BIN/fm-deliver-cycle.sh" "$@" 2>&1)
  RC=$?
}

calls() {  # <home>
  cat "$1/calls" 2>/dev/null || true
}

mark_merged() {  # <home> <id> <url>
  fm_pr_url_parse "$3" || fail "fixture URL did not parse: $3"
  fm_pr_poll_merge_mark_notified "$1/state" "$2" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    || fail "could not write the merge-notification marker for $2"
}

test_ready_direct_pr_is_armed_once() {
  local home
  home=$(new_home arm-direct)
  fm_write_meta "$home/state/t1.meta" kind=ship mode=direct-PR "worktree=$home/wt"
  printf 'done [at=100]: PR %s\n' "$PR7" > "$home/state/t1.status"
  run_cycle "$home"
  expect_code 0 "$RC" "arming pass"
  assert_equals "pr-check t1 $PR7" "$(calls "$home")" "a ready direct-PR task is armed with its one reported change"
  assert_contains "$OUT" "armed merge monitoring for t1 on $PR7" "the pass reports what it armed"
  run_cycle "$home"
  assert_equals "pr-check t1 $PR7" "$(calls "$home")" "an armed task is never armed twice"
  assert_equals "deliver: nothing to do" "$OUT" "a pass with nothing left says so"
  pass "a ready direct-PR task is armed exactly once"
}

test_no_mistakes_requires_the_ci_ready_report() {
  local home
  home=$(new_home arm-no-mistakes)
  fm_write_meta "$home/state/t2.meta" kind=ship mode=no-mistakes "worktree=$home/wt"
  printf 'done: PR %s\n' "$PR7" > "$home/state/t2.status"
  run_cycle "$home"
  assert_equals "" "$(calls "$home")" "a no-mistakes PR report without passing checks is not ready"
  printf 'done: PR %s checks green\n' "$PR7" >> "$home/state/t2.status"
  run_cycle "$home"
  assert_equals "pr-check t2 $PR7" "$(calls "$home")" "the CI-ready report arms merge monitoring"
  pass "a no-mistakes task is armed only on its CI-ready report"
}

test_ambiguous_or_unready_status_is_left_alone() {
  local home
  home=$(new_home arm-ambiguous)
  fm_write_meta "$home/state/two.meta" kind=ship mode=direct-PR
  printf 'done: PR %s superseded by %s\n' "$PR7" "$PR8" > "$home/state/two.status"
  fm_write_meta "$home/state/open.meta" kind=ship mode=direct-PR
  printf 'done: PR %s\nneeds-decision [key=scope]: which API?\n' "$PR7" > "$home/state/open.status"
  fm_write_meta "$home/state/busy.meta" kind=ship mode=direct-PR
  printf 'paused: waiting on CI capacity\n' > "$home/state/busy.status"
  fm_write_meta "$home/state/nolink.meta" kind=ship mode=direct-PR
  printf 'done: PR https://example.invalid/acme/widget/7\n' > "$home/state/nolink.status"
  fm_write_meta "$home/state/unknown.meta" kind=ship mode=some-future-mode
  printf 'done: PR %s\n' "$PR7" > "$home/state/unknown.status"
  fm_write_meta "$home/state/scout.meta" kind=scout mode=no-mistakes
  printf 'done: PR %s checks green\n' "$PR7" > "$home/state/scout.status"
  fm_write_meta "$home/state/mate.meta" kind=secondmate mode=secondmate
  printf 'done: PR %s\n' "$PR7" > "$home/state/mate.status"
  fm_write_meta "$home/state/nostatus.meta" kind=ship mode=direct-PR
  run_cycle "$home"
  expect_code 0 "$RC" "pass over unready tasks"
  assert_equals "" "$(calls "$home")" "no engine command runs for an ambiguous, unready, or non-ship task"
  assert_equals "deliver: nothing to do" "$OUT" "unready tasks are not reported as actions"
  pass "two links, an open decision, a wait, an unparseable link, an unknown mode, scouts, secondmates, and a missing status arm nothing"
}

test_poll_without_recorded_change_is_reported_not_armed() {
  local home
  home=$(new_home arm-orphan-poll)
  fm_write_meta "$home/state/t3.meta" kind=ship mode=direct-PR
  printf 'done: PR %s\n' "$PR7" > "$home/state/t3.status"
  : > "$home/state/t3.pr-poll"
  run_cycle "$home"
  assert_equals "" "$(calls "$home")" "an inconsistent poll record is not armed over"
  assert_contains "$OUT" "skipped t3" "the inconsistency is reported"
  pass "a merge poll with no recorded change is reported and left alone"
}

test_refused_arm_is_reported_and_retried_next_pass() {
  local home
  home=$(new_home arm-refused)
  fm_write_meta "$home/state/t4.meta" kind=ship mode=direct-PR
  printf 'done: PR %s\n' "$PR7" > "$home/state/t4.status"
  : > "$home/refuse-pr-check"
  run_cycle "$home"
  expect_code 0 "$RC" "a refused arm still completes the pass"
  assert_contains "$OUT" "could not arm merge monitoring for t4" "the refusal is reported"
  assert_contains "$OUT" "  error: refused by the engine" "the engine's own reason is shown beneath it"
  rm -f "$home/refuse-pr-check"
  run_cycle "$home"
  assert_contains "$OUT" "armed merge monitoring for t4" "the next pass tries again"
  pass "a refused arm is reported and retried on the next pass"
}

test_confirmed_merge_is_cleaned_up_without_force() {
  local home
  home=$(new_home cleanup)
  fm_write_meta "$home/state/t5.meta" kind=ship mode=direct-PR "pr=$PR7"
  printf 'done: PR %s\n' "$PR7" > "$home/state/t5.status"
  run_cycle "$home"
  assert_equals "" "$(calls "$home")" "a monitored change that has not merged is left to its poll"
  mark_merged "$home" t5 "$PR7"
  run_cycle "$home"
  expect_code 0 "$RC" "cleanup pass"
  assert_equals "teardown t5" "$(calls "$home")" "the merged task is cleaned up with its id alone, never --force"
  assert_contains "$OUT" "cleaned up t5 after $PR7 merged" "the cleanup is reported"
  run_cycle "$home"
  assert_equals "teardown t5" "$(calls "$home")" "a cleaned-up task is not visited again"
  pass "only a merge the monitor confirmed is cleaned up, once, without --force"
}

test_refused_cleanup_keeps_the_task() {
  local home
  home=$(new_home cleanup-refused)
  fm_write_meta "$home/state/t6.meta" kind=ship mode=direct-PR "pr=$PR7"
  mark_merged "$home" t6 "$PR7"
  : > "$home/refuse-teardown"
  run_cycle "$home"
  expect_code 0 "$RC" "a refused cleanup still completes the pass"
  assert_contains "$OUT" "cleanup of t6 refused or failed" "the refusal is reported"
  assert_contains "$OUT" "REFUSED: the worktree holds work that has not landed" "the engine's reason is shown"
  assert_present "$home/state/t6.meta" "the refused task keeps its record"
  assert_no_grep "--force" "$home/calls" "a refusal is never retried with --force"
  pass "a refused cleanup is reported and never forced"
}

test_merge_marker_must_match_the_recorded_change() {
  local home
  home=$(new_home cleanup-mismatch)
  fm_write_meta "$home/state/t7.meta" kind=ship mode=direct-PR "pr=$PR7"
  mark_merged "$home" t7 "$PR8"
  run_cycle "$home"
  assert_equals "" "$(calls "$home")" "a merge of a different change does not clean up this task"
  fm_write_meta "$home/state/t8.meta" kind=ship mode=direct-PR "pr=$PR7"
  mark_merged "$home" t8 "$PR7"
  printf 'done: PR %s\n' "$PR8" > "$home/state/t8.status"
  run_cycle "$home"
  assert_equals "" "$(calls "$home")" "a merged task now reporting a newer change is not cleaned up"
  assert_contains "$OUT" "skipped t8" "the ambiguity is reported"
  pass "cleanup requires the confirmed merge to be the task's one current change"
}

test_arguments_and_missing_state_are_refused() {
  local home
  home=$(new_home args)
  fm_write_meta "$home/state/t9.meta" kind=ship mode=direct-PR
  printf 'done: PR %s\n' "$PR7" > "$home/state/t9.status"
  run_cycle "$home" t9
  expect_code 2 "$RC" "any argument"
  assert_equals "" "$(calls "$home")" "an argument runs nothing"
  run_cycle "$TMP_ROOT/homes/absent"
  expect_code 1 "$RC" "missing state directory"
  pass "the pass takes no input and refuses a home it cannot read"
}

test_ready_direct_pr_is_armed_once
test_no_mistakes_requires_the_ci_ready_report
test_ambiguous_or_unready_status_is_left_alone
test_poll_without_recorded_change_is_reported_not_armed
test_refused_arm_is_reported_and_retried_next_pass
test_confirmed_merge_is_cleaned_up_without_force
test_refused_cleanup_keeps_the_task
test_merge_marker_must_match_the_recorded_change
test_arguments_and_missing_state_are_refused
