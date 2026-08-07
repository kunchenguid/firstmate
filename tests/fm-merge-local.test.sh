#!/usr/bin/env bash
# Public-interface regressions for immutable local-only readiness and merge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  git init -q -b main "$dir/project"
  printf 'base\n' > "$dir/project/file.txt"
  git -C "$dir/project" add file.txt
  git -C "$dir/project" commit -qm base
  git -C "$dir/project" worktree add -q -b fm/task-x1 "$dir/wt" main
  printf 'ready\n' > "$dir/wt/file.txt"
  git -C "$dir/wt" add file.txt
  git -C "$dir/wt" commit -qm ready
  fm_write_meta "$dir/state/task-x1.meta" \
    'window=firstmate:fm-task-x1' \
    'endpoint_task_id=task-x1' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only' \
    'yolo=off'
  printf '%s\n' "$dir"
}

run_local() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$dir/state" \
    "$MERGE_LOCAL" task-x1 "$@"
}

test_merge_requires_prepared_revision() {
  local dir rc
  dir=$(make_case absent-binding)
  set +e
  run_local "$dir" > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "local merge without readiness binding must refuse"
  assert_grep 'no exact local readiness binding' "$dir/err" "missing local binding diagnostic was not actionable"
  [ "$(git -C "$dir/project" show HEAD:file.txt)" = base ] || fail "unprepared local work landed"
  pass "local merge refuses absent revision identity"
}

test_moved_revision_refuses_until_fresh_prepare() {
  local dir first second rc
  dir=$(make_case moved-binding)
  run_local "$dir" --prepare > "$dir/prepare-1.out" || fail "first local preparation failed"
  first=$(grep '^ready_head=' "$dir/state/task-x1.meta" | cut -d= -f2-)
  printf 'later\n' > "$dir/wt/later.txt"
  git -C "$dir/wt" add later.txt
  git -C "$dir/wt" commit -qm later
  second=$(git -C "$dir/wt" rev-parse HEAD)
  [ "$first" != "$second" ] || fail "moved local fixture did not move"
  set +e
  run_local "$dir" > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "moved local revision must refuse merge"
  assert_grep "moved after review from $first to $second" "$dir/err" "moved local diagnostic omitted exact revisions"
  [ "$(git -C "$dir/project" show HEAD:file.txt)" = base ] || fail "moved local work landed under stale approval"

  run_local "$dir" --prepare > "$dir/prepare-2.out" || fail "fresh local preparation failed"
  [ "$(grep '^ready_head=' "$dir/state/task-x1.meta" | cut -d= -f2-)" = "$second" ] \
    || fail "fresh preparation did not replace the old immutable revision"
  run_local "$dir" > "$dir/merge.out" || fail "merge of freshly prepared revision failed"
  [ "$(git -C "$dir/project" rev-parse HEAD)" = "$second" ] || fail "local merge did not land the exact prepared commit"
  pass "local rebase or fix requires a fresh binding and then lands only that commit"
}

test_dirty_prepare_refuses() {
  local dir rc
  dir=$(make_case dirty-prepare)
  printf 'dirty\n' >> "$dir/wt/file.txt"
  set +e
  run_local "$dir" --prepare > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "dirty local work must not become review-ready"
  assert_no_grep '^ready_head=' "$dir/state/task-x1.meta" "dirty preparation wrote approval identity"
  pass "local readiness refuses uncommitted work"
}

test_duplicate_custody_refuses_prepare() {
  local dir rc
  dir=$(make_case duplicate-custody)
  fm_write_meta "$dir/state/other.meta" \
    'window=firstmate:fm-other' \
    'endpoint_task_id=other' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only'
  set +e
  run_local "$dir" --prepare > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "two task records on one isolated copy must refuse readiness"
  assert_grep 'still owned by task other' "$dir/err" "custody refusal did not name the conflicting task"
  assert_no_grep '^ready_head=' "$dir/state/task-x1.meta" "conflicting task became review-ready"
  pass "delivery refuses a second task record on the same isolated copy"
}

test_merge_requires_prepared_revision
test_moved_revision_refuses_until_fresh_prepare
test_dirty_prepare_refuses
test_duplicate_custody_refuses_prepare
