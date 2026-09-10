#!/usr/bin/env bash
# tests/fm-spawn-issue.test.sh - dispatching a task from a GitLab issue.
#
# bin/fm-spawn.sh records the issue a task was split out of as `issue=` in that
# task's own record, which is the durable link between one issue and every task
# belonging to it. These tests drive the real spawn against a fake tmux pane and
# a real isolated git worktree, so the recorded value is read back from the task
# record the spawn actually published rather than from the flag it was given.
#
# Covered: the canonical issue URL is what lands in the record however the
# caller spelled it; a task with no --issue records nothing; a batch shares one
# issue across every pair; the brief's recorded issue and the spawn's flag must
# agree; and --issue is refused where a task cannot come from an issue
# (--scout, --secondmate, --relaunch) or where the URL is not an issue URL.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-issue)

ISSUE_URL='https://gitlab.example.test/grp/sub/proj/-/issues/42'

# make_case <name> <task-id>...: a spawn world with a fake tmux pane, a real
# worktree, and one brief per task id. Echoes "<home>|<proj>|<wt>|<fakebin>".
make_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# record_brief_issue <home> <id> <url>: the fixed line bin/fm-brief.sh --issue
# writes into an issue-sourced brief.
record_brief_issue() {
  printf '\n# GitLab issue\nIssue contract: issue=%s\n' "$3" >> "$1/data/$2/brief.md"
}

run_spawn() {  # <home> <pane-path> <fakebin> <spawn args...>
  local home=$1 pane=$2 fakebin=$3
  shift 3
  CLAUDE_CONFIG_DIR='' fm_test_run_spawn "$home" "$pane" "$fakebin" "$@"
}

# The task record is what a later step reads to find every task of one issue, so
# it must hold the canonical URL no matter how the caller spelled the flag: a
# "#note_" fragment, a trailing slash, and an upper-case host all name the same
# issue. A task dispatched with no issue records no issue= line at all.
test_the_task_record_holds_the_canonical_issue() {
  local rec out status meta spelling n=0
  rec=$(make_case record issue-rec-a1 issue-rec-a2 issue-rec-a3 issue-rec-a4)
  read_case "$rec"

  for spelling in \
    "$ISSUE_URL" \
    "$ISSUE_URL#note_991" \
    "$ISSUE_URL/" \
    'https://GitLab.Example.TEST/grp/sub/proj/-/issues/42'; do
    n=$((n + 1))
    record_brief_issue "$HOME_DIR" "issue-rec-a$n" "$ISSUE_URL"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "issue-rec-a$n" "$PROJ_DIR" claude --mode direct-PR --yolo off --issue "$spelling")
    status=$?
    expect_code 0 "$status" "an issue-sourced spawn should succeed for '$spelling': $out"
    meta="$HOME_DIR/state/issue-rec-a$n.meta"
    assert_grep "issue=$ISSUE_URL" "$meta" "'$spelling' was not recorded as the canonical issue"
    [ "$(grep -c '^issue=' "$meta")" = 1 ] || fail "'$spelling' left more than one issue= line in the task record"
  done
  pass "fm-spawn: every accepted spelling of one issue records the same canonical issue="
}

test_a_task_without_an_issue_records_none() {
  local rec out status
  rec=$(make_case no-issue issue-none-b1)
  read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    issue-none-b1 "$PROJ_DIR" claude --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "an ordinary spawn should still succeed: $out"
  assert_no_grep 'issue=' "$HOME_DIR/state/issue-none-b1.meta" \
    "a task that did not come from an issue recorded one"
  pass "fm-spawn: an absent --issue leaves the task record unchanged"
}

# One issue is normally split into several tasks, so the shared flag of a batch
# has to reach every pair's own record.
test_a_batch_shares_one_issue_across_every_pair() {
  local rec out status id
  rec=$(make_case batch issue-batch-c1 issue-batch-c2)
  read_case "$rec"
  for id in issue-batch-c1 issue-batch-c2; do
    record_brief_issue "$HOME_DIR" "$id" "$ISSUE_URL"
  done
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "issue-batch-c1=$PROJ_DIR" "issue-batch-c2=$PROJ_DIR" \
    --mode direct-PR --yolo off --issue "$ISSUE_URL")
  status=$?
  expect_code 0 "$status" "a batch of issue subtasks should succeed: $out"
  for id in issue-batch-c1 issue-batch-c2; do
    assert_grep "issue=$ISSUE_URL" "$HOME_DIR/state/$id.meta" "batch pair $id lost the shared issue"
  done
  pass "fm-spawn: a batch records the shared issue on every pair"
}

# The brief is what the worker follows and the record is what the issue is
# tracked by, so the two must name the same issue - the same agreement the
# delivery mode already carries.
test_the_brief_and_the_spawn_must_name_the_same_issue() {
  local rec out status
  rec=$(make_case agreement issue-agree-d1 issue-agree-d2 issue-agree-d3)
  read_case "$rec"

  record_brief_issue "$HOME_DIR" issue-agree-d1 "$ISSUE_URL"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    issue-agree-d1 "$PROJ_DIR" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an issue-sourced brief spawned without --issue should exit non-zero"
  assert_contains "$out" "was briefed from GitLab issue $ISSUE_URL but this spawn recorded no issue" \
    "the refusal did not name the issue the brief came from"
  assert_absent "$HOME_DIR/state/issue-agree-d1.meta" "a refused spawn published a task record"

  record_brief_issue "$HOME_DIR" issue-agree-d2 "$ISSUE_URL"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    issue-agree-d2 "$PROJ_DIR" claude --mode direct-PR --yolo off \
    --issue 'https://gitlab.example.test/grp/sub/proj/-/issues/43')
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn issue mismatch should exit non-zero"
  assert_contains "$out" "issue mismatch for issue-agree-d2" "the mismatch refusal did not name the task"
  assert_absent "$HOME_DIR/state/issue-agree-d2.meta" "a mismatched spawn published a task record"

  # A brief that names no issue is not a refusal - firstmate may have written it
  # by hand - but the worker then has no issue text, so it is never silent.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    issue-agree-d3 "$PROJ_DIR" claude --mode direct-PR --yolo off --issue "$ISSUE_URL")
  status=$?
  expect_code 0 "$status" "a hand-written brief with an issue flag should still spawn: $out"
  assert_contains "$out" "its brief was not scaffolded from that issue" \
    "an unbriefed issue was recorded without a warning"
  assert_grep "issue=$ISSUE_URL" "$HOME_DIR/state/issue-agree-d3.meta" "the warned spawn did not record the issue"
  pass "fm-spawn: the brief's issue and the spawn's issue must agree, and a flag-only issue warns"
}

# A relaunch reuses the task's own record, so the recorded issue survives a
# replacement worker and the flag is refused rather than silently ignored.
test_a_relaunch_keeps_the_recorded_issue() {
  local rec out status meta
  rec=$(make_case relaunch issue-relaunch-e1)
  read_case "$rec"
  record_brief_issue "$HOME_DIR" issue-relaunch-e1 "$ISSUE_URL"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    issue-relaunch-e1 "$PROJ_DIR" claude --mode direct-PR --yolo off --issue "$ISSUE_URL")
  status=$?
  expect_code 0 "$status" "the first spawn should succeed: $out"
  meta="$HOME_DIR/state/issue-relaunch-e1.meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    issue-relaunch-e1 --relaunch --issue "$ISSUE_URL")
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch carrying --issue should exit non-zero"
  assert_contains "$out" "--relaunch reuses the task's recorded issue" \
    "the relaunch refusal did not explain where the issue comes from"
  assert_grep "issue=$ISSUE_URL" "$meta" "the refused relaunch disturbed the recorded issue"
  pass "fm-spawn: a relaunch reuses the recorded issue and refuses to be told another one"
}

# Refusals that happen before anything exists: a URL that is not a GitLab issue
# URL (the rules bin/fm-gitlab-issue-lib.sh owns), and the two kinds that cannot
# come from an issue - a scout, which delivers a report and no merge request,
# and a persistent secondmate.
test_issue_scope_and_url_refusals_create_nothing() {
  local rec out status bad
  rec=$(make_case refusals issue-bad-f1)
  read_case "$rec"
  for bad in \
    'https://gitlab.example.test/grp/proj/-/merge_requests/3' \
    'https://gitlab.example.test/grp/proj/-/issues/0' \
    'https://gitlab.example.test/proj/-/issues/3' \
    'https://gitlab.example.test:8443/grp/proj/-/issues/3' \
    'http://gitlab.example.test/grp/proj/-/issues/3'; do
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      issue-bad-f1 "$PROJ_DIR" claude --mode direct-PR --yolo off --issue "$bad")
    status=$?
    [ "$status" -ne 0 ] || fail "--issue accepted '$bad'"
    assert_contains "$out" "not a GitLab issue URL" "the refusal did not name the URL shape: $bad"
    assert_absent "$HOME_DIR/state/issue-bad-f1.meta" "a refused URL published a task record: $bad"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    issue-sm-f2 "$HOME_DIR" --secondmate --issue "$ISSUE_URL")
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying --issue should exit non-zero"
  assert_contains "$out" "--issue applies only to ship spawns" \
    "the secondmate refusal did not explain the scope"
  assert_absent "$HOME_DIR/state/issue-sm-f2.meta" "a refused secondmate spawn published a task record"

  # A scout delivers a report and no merge request, so it is not issue work.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    issue-bad-f1 "$PROJ_DIR" claude --scout --issue "$ISSUE_URL")
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --issue should exit non-zero"
  assert_contains "$out" "--issue applies only to ship spawns" \
    "the scout refusal did not explain the scope"
  assert_absent "$HOME_DIR/state/issue-bad-f1.meta" "a refused scout spawn published a task record"
  pass "fm-spawn: a non-issue URL, a scout, and a secondmate spawn are refused before any task exists"
}

test_the_task_record_holds_the_canonical_issue
test_a_task_without_an_issue_records_none
test_a_batch_shares_one_issue_across_every_pair
test_the_brief_and_the_spawn_must_name_the_same_issue
test_a_relaunch_keeps_the_recorded_issue
test_issue_scope_and_url_refusals_create_nothing

echo "# all fm-spawn-issue tests passed"
