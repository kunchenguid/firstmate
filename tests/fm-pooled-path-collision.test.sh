#!/usr/bin/env bash
# Regression tests for the pooled-path collision guard introduced to prevent
# a completed or failed worker from mutating a treehouse slot that has been
# reassigned to a new task.
#
# Three behaviors are exercised:
#   1. fm_backend_worktree_canonical_owner detects when another task's meta
#      records the same canonical physical path, excluding the task under test.
#   2. fm-teardown skips the worktree return when a collision is found but
#      still retires the old task's volatile records, leaving the new owner intact.
#   3. fm-send refuses input delivery when the target task's status log ends
#      on a done: or failed: verb.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-pooled-path-collision)

# --------------------------------------------------------------------------
# Shared fixture helpers
# --------------------------------------------------------------------------

make_teardown_home() {  # <dir>: create a minimal fm home skeleton for teardown tests
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  printf 'tmux\n' > "$dir/config/crew-harness"
}

make_fakebin_log() {  # <dir>: create fakebin with logging tmux+treehouse stubs
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_teardown() {  # <home> <fakebin> <log> <id> [extra-args...]
  local home=$1 fakebin=$2 log=$3 id=$4
  shift 4
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$log" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

# --------------------------------------------------------------------------
# 1. fm_backend_worktree_canonical_owner: collision detection unit test
# --------------------------------------------------------------------------

test_worktree_canonical_owner_detects_collision() {
  local state wt other_task excluded_task meta_other

  state="$TMP_ROOT/unit-collision/state"
  mkdir -p "$state"
  wt="$TMP_ROOT/unit-collision/wt"
  mkdir -p "$wt"

  other_task=owner-abc
  excluded_task=stale-xyz

  meta_other="$state/$other_task.meta"
  fm_write_meta "$meta_other" \
    "window=isolated:fm-$other_task" \
    "endpoint_task_id=$other_task" \
    "worktree=$wt" \
    "project=$TMP_ROOT/unit-collision/proj" \
    "kind=scout"

  # Source fm-backend.sh to get access to fm_backend_worktree_canonical_owner.
  # shellcheck source=/dev/null
  FM_HOME="$TMP_ROOT/unit-collision/home" . "$ROOT/bin/fm-backend.sh"

  wt_real=$(CDPATH='' cd -- "$wt" && pwd -P)

  FM_WORKTREE_COLLISION_OWNER=
  fm_backend_worktree_canonical_owner "$state" "$wt_real" "$excluded_task"
  [ "$FM_WORKTREE_COLLISION_OWNER" = "$other_task" ] \
    || fail "collision owner should be $other_task, got '$FM_WORKTREE_COLLISION_OWNER'"

  pass "fm_backend_worktree_canonical_owner: reports collision owner when another task records the same canonical path"
}

test_worktree_canonical_owner_excludes_self() {
  local state wt task meta_self

  state="$TMP_ROOT/unit-self-exclude/state"
  mkdir -p "$state"
  wt="$TMP_ROOT/unit-self-exclude/wt"
  mkdir -p "$wt"
  task=self-task

  meta_self="$state/$task.meta"
  fm_write_meta "$meta_self" \
    "window=isolated:fm-$task" \
    "endpoint_task_id=$task" \
    "worktree=$wt" \
    "project=$TMP_ROOT/unit-self-exclude/proj" \
    "kind=scout"

  # shellcheck source=/dev/null
  FM_HOME="$TMP_ROOT/unit-self-exclude/home" . "$ROOT/bin/fm-backend.sh"

  wt_real=$(CDPATH='' cd -- "$wt" && pwd -P)

  FM_WORKTREE_COLLISION_OWNER=
  fm_backend_worktree_canonical_owner "$state" "$wt_real" "$task"
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "should not report a collision when the only matching meta is the excluded task itself"

  pass "fm_backend_worktree_canonical_owner: self-exclusion prevents false collision against own meta"
}

test_worktree_canonical_owner_no_collision() {
  local state wt_a wt_b task_b meta_b

  state="$TMP_ROOT/unit-no-collision/state"
  mkdir -p "$state"
  wt_a="$TMP_ROOT/unit-no-collision/wt-a"
  wt_b="$TMP_ROOT/unit-no-collision/wt-b"
  mkdir -p "$wt_a" "$wt_b"
  task_b=other-b

  meta_b="$state/$task_b.meta"
  fm_write_meta "$meta_b" \
    "window=isolated:fm-$task_b" \
    "endpoint_task_id=$task_b" \
    "worktree=$wt_b" \
    "project=$TMP_ROOT/unit-no-collision/proj" \
    "kind=scout"

  # shellcheck source=/dev/null
  FM_HOME="$TMP_ROOT/unit-no-collision/home" . "$ROOT/bin/fm-backend.sh"

  wt_a_real=$(CDPATH='' cd -- "$wt_a" && pwd -P)

  FM_WORKTREE_COLLISION_OWNER=
  fm_backend_worktree_canonical_owner "$state" "$wt_a_real" "task-a"
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "should return 1 when no other task records the queried path"

  pass "fm_backend_worktree_canonical_owner: returns 1 when no other task owns the path"
}

# --------------------------------------------------------------------------
# 2. Teardown: collision skips worktree return but retires volatile records
# --------------------------------------------------------------------------

test_teardown_collision_skips_worktree_return() {
  local case_dir home fakebin log wt proj stale_id new_id rc

  case_dir="$TMP_ROOT/td-collision"
  home="$case_dir/home"
  log="$case_dir/runtime.log"
  wt="$case_dir/wt"
  proj="$case_dir/proj"
  stale_id=stale-task
  new_id=new-owner-task

  mkdir -p "$wt" "$proj"
  : > "$log"
  make_teardown_home "$home"

  dir="$case_dir"
  fakebin=$(make_fakebin_log "$case_dir")

  # Stale task: the task being torn down.
  fm_write_meta "$home/state/$stale_id.meta" \
    "window=isolated:fm-$stale_id" \
    "endpoint_task_id=$stale_id" \
    "worktree=$wt" \
    "project=$proj" \
    "kind=scout" \
    "backend=tmux" \
    "harness=claude" \
    "yolo=off"

  # New owner: another live task recorded against the same physical path.
  fm_write_meta "$home/state/$new_id.meta" \
    "window=isolated:fm-$new_id" \
    "endpoint_task_id=$new_id" \
    "worktree=$wt" \
    "project=$proj" \
    "kind=scout" \
    "backend=tmux" \
    "harness=claude" \
    "yolo=off"

  set +e
  run_teardown "$home" "$fakebin" "$log" "$stale_id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "teardown with collision should succeed (retire volatile records for the stale task)"
  assert_absent "$home/state/$stale_id.meta" "stale task meta should be removed after collision teardown"
  assert_present "$home/state/$new_id.meta" "new owner meta must not be touched by collision teardown"
  if grep -qF 'treehouse' "$log" 2>/dev/null; then
    fail "teardown with collision must not call treehouse (would return the new owner's slot): $(cat "$log")"
  fi

  pass "fm-teardown: collision skips worktree return but retires stale task volatile records"
}

test_teardown_no_collision_returns_worktree() {
  local case_dir home fakebin log wt proj task_id rc

  case_dir="$TMP_ROOT/td-no-collision"
  home="$case_dir/home"
  log="$case_dir/runtime.log"
  wt="$case_dir/wt"
  proj="$case_dir/proj"
  task_id=solo-task

  mkdir -p "$wt" "$proj"
  : > "$log"
  make_teardown_home "$home"

  dir="$case_dir"
  fakebin=$(make_fakebin_log "$case_dir")

  fm_write_meta "$home/state/$task_id.meta" \
    "window=isolated:fm-$task_id" \
    "endpoint_task_id=$task_id" \
    "worktree=$wt" \
    "project=$proj" \
    "kind=scout" \
    "backend=tmux" \
    "harness=claude" \
    "yolo=off"

  set +e
  run_teardown "$home" "$fakebin" "$log" "$task_id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "teardown without collision should succeed"
  assert_absent "$home/state/$task_id.meta" "task meta should be removed after successful teardown"
  grep -qF 'treehouse' "$log" 2>/dev/null \
    || fail "teardown without collision must call treehouse to return the worktree slot: $(cat "$log")"

  pass "fm-teardown: no collision means treehouse return runs normally"
}

test_teardown_collision_new_owner_survives_retry() {
  local case_dir home fakebin log wt proj stale_id new_id rc

  case_dir="$TMP_ROOT/td-retry"
  home="$case_dir/home"
  log="$case_dir/runtime.log"
  wt="$case_dir/wt"
  proj="$case_dir/proj"
  stale_id=stale-retry
  new_id=new-owner-retry

  mkdir -p "$wt" "$proj"
  : > "$log"
  make_teardown_home "$home"

  dir="$case_dir"
  fakebin=$(make_fakebin_log "$case_dir")

  fm_write_meta "$home/state/$stale_id.meta" \
    "window=isolated:fm-$stale_id" \
    "endpoint_task_id=$stale_id" \
    "worktree=$wt" \
    "project=$proj" \
    "kind=scout" \
    "backend=tmux" \
    "harness=claude" \
    "yolo=off"

  fm_write_meta "$home/state/$new_id.meta" \
    "window=isolated:fm-$new_id" \
    "endpoint_task_id=$new_id" \
    "worktree=$wt" \
    "project=$proj" \
    "kind=scout" \
    "backend=tmux" \
    "harness=claude" \
    "yolo=off"

  # First teardown attempt under collision.
  set +e
  run_teardown "$home" "$fakebin" "$log" "$stale_id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "first collision teardown should succeed"

  # New owner must still be intact after the stale task's retirement.
  assert_present "$home/state/$new_id.meta" "new owner meta must survive the stale task's teardown"
  assert_present "$wt" "new owner worktree directory must not be removed by the stale task's teardown"

  pass "fm-teardown: new owner's records and worktree survive stale task teardown under collision"
}

# --------------------------------------------------------------------------
# 3. fm-send: terminal task denial
# --------------------------------------------------------------------------

make_send_home() {  # <dir> <id>: create a home with a task meta and fakebin
  local base=$1 id=$2 home fakebin
  home="$base/home"
  mkdir -p "$home/state" "$home/config"
  printf 'tmux\n' > "$home/config/crew-harness"
  fm_write_meta "$home/state/$id.meta" \
    "window=isolated:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$base/wt" \
    "project=$base/proj" \
    "kind=ship" \
    "backend=tmux" \
    "harness=claude" \
    "yolo=off"
  fakebin=$(fm_fakebin "$base")
  fm_fake_exit0 "$fakebin" tmux
  printf '%s\n' "$home|$fakebin"
}

run_send() {  # <home> <fakebin> <id> <msg>
  local home=$1 fakebin=$2 id=$3 msg=$4
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    "$SEND" "$id" "$msg"
}

test_send_refuses_done_task() {
  local base id home fakebin rec rc

  base="$TMP_ROOT/send-done"
  id=done-task
  mkdir -p "$base"
  rec=$(make_send_home "$base" "$id")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  printf 'done: task completed successfully\n' > "$home/state/$id.status"

  set +e
  run_send "$home" "$fakebin" "$id" "hello world" > "$base/stdout" 2> "$base/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "fm-send should refuse to deliver to a done task"
  assert_contains "$(cat "$base/stderr")" "terminal" \
    "refusal message should describe the task as terminal"
  assert_contains "$(cat "$base/stderr")" "done" \
    "refusal message should name the terminal verb"

  pass "fm-send: refuses input delivery to a task whose status is done"
}

test_send_refuses_failed_task() {
  local base id home fakebin rec rc

  base="$TMP_ROOT/send-failed"
  id=failed-task
  mkdir -p "$base"
  rec=$(make_send_home "$base" "$id")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  printf 'failed: validation did not pass\n' > "$home/state/$id.status"

  set +e
  run_send "$home" "$fakebin" "$id" "retry please" > "$base/stdout" 2> "$base/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "fm-send should refuse to deliver to a failed task"
  assert_contains "$(cat "$base/stderr")" "terminal" \
    "refusal message should describe the task as terminal"
  assert_contains "$(cat "$base/stderr")" "failed" \
    "refusal message should name the terminal verb"

  pass "fm-send: refuses input delivery to a task whose status is failed"
}

test_send_allows_needs_decision_task() {
  local base id home fakebin rec stderr_out

  base="$TMP_ROOT/send-needs-decision"
  id=needs-decision-task
  mkdir -p "$base"
  rec=$(make_send_home "$base" "$id")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  printf 'needs-decision[key=approve-scope]: should the scope expand\n' \
    > "$home/state/$id.status"

  set +e
  run_send "$home" "$fakebin" "$id" "yes, proceed with the expanded scope" \
    > "$base/stdout" 2> "$base/stderr"
  set -e

  stderr_out=$(cat "$base/stderr")
  # Our guard must NOT fire for needs-decision: that state still needs a
  # decision answer delivered. The send may fail for other reasons in the
  # test environment (no live pane to confirm), but the refusal must not
  # come from the terminal-task check.
  assert_not_contains "$stderr_out" "terminal task" \
    "needs-decision task must not trigger the terminal-task guard"

  pass "fm-send: does not apply the terminal guard to a needs-decision task"
}

test_send_allows_no_status_log() {
  local base id home fakebin rec stderr_out

  base="$TMP_ROOT/send-no-log"
  id=no-log-task
  mkdir -p "$base"
  rec=$(make_send_home "$base" "$id")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  # No status log written: task is freshly spawned.

  set +e
  run_send "$home" "$fakebin" "$id" "first instructions" \
    > "$base/stdout" 2> "$base/stderr"
  set -e

  stderr_out=$(cat "$base/stderr")
  # Our guard must not fire when there is no status log at all.
  assert_not_contains "$stderr_out" "terminal task" \
    "a task with no status log must not trigger the terminal-task guard"

  pass "fm-send: does not apply the terminal guard when the task has no status log"
}

# --------------------------------------------------------------------------
# Run all tests
# --------------------------------------------------------------------------

test_worktree_canonical_owner_detects_collision
test_worktree_canonical_owner_excludes_self
test_worktree_canonical_owner_no_collision
test_teardown_collision_skips_worktree_return
test_teardown_no_collision_returns_worktree
test_teardown_collision_new_owner_survives_retry
test_send_refuses_done_task
test_send_refuses_failed_task
test_send_allows_needs_decision_task
test_send_allows_no_status_log

echo "# all fm-pooled-path-collision tests passed"
