#!/usr/bin/env bash
# Tests for bin/fm-herdr-outcome-publish.sh: the reusable publisher that
# turns a real work outcome firstmate has just learned into a herdr signal
# (report-signal) plus a durable metadata patch (report-metadata), targeting
# the workspace recorded in the task's own state/<id>.meta.
#
# Fake-herdr-CLI unit tests (mirrors tests/fm-backend-herdr.test.sh's
# fakebin/command-log convention): a `herdr` stub that logs every invocation
# and exits with a configurable code, so assertions are on what got called,
# never on the script's implementation bytes.
#
# Matrix:
#   (a) herdr task -> both report-signal and report-metadata called with the
#       resolved session/workspace, the mapped kind, and outcome+summary tokens
#   (b) no summary given -> report-metadata carries only the outcome token
#   (c) transfer kind addresses the workspace with --to, not --from
#   (d) non-herdr task (no backend= line) -> no herdr call, exit 0
#   (e) herdr task with backend= present but no herdr_session/workspace_id -> no call, exit 0
#   (f) missing task meta -> no call, exit 0
#   (g) invalid signal kind -> usage error, exit 2, no herdr call
#   (h) wrong argument count -> usage error, exit 2
#   (i) the herdr CLI itself failing never fails the publisher (exit 0)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

PUBLISH="$ROOT/bin/fm-herdr-outcome-publish.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-outcome-publish-tests)

# Build a fresh sandbox: a state dir and a fakebin with a herdr stub that logs
# every invocation ("HERDR_SESSION=<val> ARGS=<args>", one line per call) to
# $case_dir/herdr.log and exits 0 unless $case_dir/herdr-exit overrides it.
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'HERDR_SESSION=%s ARGS=%s\n' "${HERDR_SESSION:-}" "$*" >> "${FM_TEST_HERDR_LOG:?}"
exit "$(cat "${FM_TEST_HERDR_EXIT_FILE:?}" 2>/dev/null || echo 0)"
SH
  chmod +x "$fakebin/herdr"
  : > "$case_dir/herdr.log"
  printf '0\n' > "$case_dir/herdr-exit"
  printf '%s\n' "$case_dir"
}

write_herdr_meta() {
  local case_dir=$1
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fmtest:w1:p2" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "backend=herdr" \
    "herdr_session=fmtest" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" \
    "herdr_pane_id=w1:p2"
}

run_publish() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_HERDR_LOG="$case_dir/herdr.log" \
  FM_TEST_HERDR_EXIT_FILE="$case_dir/herdr-exit" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PUBLISH" "$@"
}

test_herdr_task_publishes_signal_and_metadata() {
  local case_dir rc
  case_dir=$(make_case herdr-task)
  write_herdr_meta "$case_dir"

  set +e
  run_publish "$case_dir" task-x1 completed pr_merged "PR #9 merged" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "herdr-task: publish should succeed"
  assert_grep 'HERDR_SESSION=fmtest ARGS=workspace report-signal --source firstmate --kind completed --from w1 --session fmtest' \
    "$case_dir/herdr.log" "herdr-task: report-signal was not called as expected"
  assert_grep 'HERDR_SESSION=fmtest ARGS=workspace report-metadata --source firstmate --token outcome=pr_merged --token summary=PR #9 merged w1 --session fmtest' \
    "$case_dir/herdr.log" "herdr-task: report-metadata was not called as expected"
  pass "fm-herdr-outcome-publish publishes both a signal and durable metadata for a herdr task"
}

test_no_summary_omits_summary_token() {
  local case_dir rc
  case_dir=$(make_case no-summary)
  write_herdr_meta "$case_dir"

  set +e
  run_publish "$case_dir" task-x1 failed validation_failed \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-summary: publish should succeed"
  assert_grep 'HERDR_SESSION=fmtest ARGS=workspace report-metadata --source firstmate --token outcome=validation_failed w1 --session fmtest' \
    "$case_dir/herdr.log" "no-summary: report-metadata should carry only the outcome token"
  assert_no_grep 'summary=' "$case_dir/herdr.log" \
    "no-summary: report-metadata should not carry a summary token when none was given"
  pass "fm-herdr-outcome-publish omits the summary token when no summary is given"
}

test_transfer_kind_addresses_receiver() {
  local case_dir rc
  case_dir=$(make_case transfer-kind)
  write_herdr_meta "$case_dir"

  set +e
  run_publish "$case_dir" task-x1 transfer handoff "handed off" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transfer-kind: publish should succeed"
  assert_grep 'ARGS=workspace report-signal --source firstmate --kind transfer --to w1 --session fmtest' \
    "$case_dir/herdr.log" "transfer-kind: report-signal should address the workspace with --to"
  assert_no_grep '--from w1' "$case_dir/herdr.log" \
    "transfer-kind: report-signal should not use --from for a transfer"
  pass "fm-herdr-outcome-publish addresses a transfer signal with --to, not --from"
}

test_non_herdr_task_publishes_nothing() {
  local case_dir rc
  case_dir=$(make_case non-herdr)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  run_publish "$case_dir" task-x1 completed pr_merged "PR merged" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-herdr: publish should succeed quietly"
  [ ! -s "$case_dir/herdr.log" ] || fail "non-herdr: herdr was called for a non-herdr task"
  pass "fm-herdr-outcome-publish is a silent no-op for a non-herdr task"
}

test_herdr_task_missing_session_fields_publishes_nothing() {
  local case_dir rc
  case_dir=$(make_case missing-fields)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fmtest:w1:p2" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "backend=herdr"

  set +e
  run_publish "$case_dir" task-x1 completed pr_merged "PR merged" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-fields: publish should succeed quietly"
  [ ! -s "$case_dir/herdr.log" ] || fail "missing-fields: herdr was called with no resolvable session/workspace"
  pass "fm-herdr-outcome-publish is a silent no-op when herdr session/workspace fields are absent"
}

test_missing_meta_publishes_nothing() {
  local case_dir rc
  case_dir=$(make_case missing-meta)

  set +e
  run_publish "$case_dir" task-x1 completed pr_merged "PR merged" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-meta: publish should succeed quietly"
  [ ! -s "$case_dir/herdr.log" ] || fail "missing-meta: herdr was called for a task with no meta"
  pass "fm-herdr-outcome-publish is a silent no-op when the task has no meta"
}

test_invalid_kind_is_a_usage_error() {
  local case_dir rc
  case_dir=$(make_case invalid-kind)
  write_herdr_meta "$case_dir"

  set +e
  run_publish "$case_dir" task-x1 bogus pr_merged "PR merged" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "invalid-kind: an unknown signal kind should be refused"
  assert_grep 'usage:' "$case_dir/stderr" "invalid-kind: refusal did not explain usage"
  [ ! -s "$case_dir/herdr.log" ] || fail "invalid-kind: herdr was called despite an invalid kind"
  pass "fm-herdr-outcome-publish refuses a signal kind outside the four WorkspaceSignalKind values"
}

test_wrong_arg_count_is_a_usage_error() {
  local case_dir rc
  case_dir=$(make_case wrong-arg-count)
  write_herdr_meta "$case_dir"

  set +e
  run_publish "$case_dir" task-x1 completed \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "wrong-arg-count: a missing outcome argument should be refused"
  assert_grep 'usage:' "$case_dir/stderr" "wrong-arg-count: refusal did not explain usage"
  [ ! -s "$case_dir/herdr.log" ] || fail "wrong-arg-count: herdr was called despite a missing argument"
  pass "fm-herdr-outcome-publish refuses a call with too few arguments"
}

test_herdr_cli_failure_never_fails_the_publisher() {
  local case_dir rc
  case_dir=$(make_case cli-failure)
  write_herdr_meta "$case_dir"
  printf '1\n' > "$case_dir/herdr-exit"

  set +e
  run_publish "$case_dir" task-x1 completed pr_merged "PR merged" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "cli-failure: a failing herdr CLI call should never fail the publisher"
  assert_grep 'report-signal' "$case_dir/herdr.log" "cli-failure: report-signal was not attempted"
  pass "fm-herdr-outcome-publish never fails when the underlying herdr CLI call fails"
}

test_herdr_task_publishes_signal_and_metadata
test_no_summary_omits_summary_token
test_transfer_kind_addresses_receiver
test_non_herdr_task_publishes_nothing
test_herdr_task_missing_session_fields_publishes_nothing
test_missing_meta_publishes_nothing
test_invalid_kind_is_a_usage_error
test_wrong_arg_count_is_a_usage_error
test_herdr_cli_failure_never_fails_the_publisher
