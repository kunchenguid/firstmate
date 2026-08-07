#!/usr/bin/env bash
# Public-interface regressions for revision-bound review diffs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" commit -qm baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf 'reviewed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm reviewed
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "$@"
}

mock_gh_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in *headRefOid*) printf '%s\n' '$head' ;; *) exit 1 ;; esac
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_review() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$REVIEW_DIFF" task-x1 "$@"
}

reviewed_head() { git -C "$1/wt" rev-parse HEAD; }

register_pr() {
  local case_dir=$1 url=$2
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2>/dev/null \
    || fail "PR readiness registration failed for $url"
}

test_registered_pr_revision_is_reviewed() {
  local case_dir out head
  case_dir=$(make_case exact-pr)
  head=$(reviewed_head "$case_dir")
  git -C "$case_dir/wt" push -q origin "HEAD:refs/pull/9/head"
  write_meta "$case_dir" mode=no-mistakes
  mock_gh_head "$case_dir" "$head"
  register_pr "$case_dir" https://github.com/example/repo/pull/9
  out=$(run_review "$case_dir") || fail "exact registered PR review failed"
  assert_contains "$out" "diff head: $head" "review did not name the immutable revision"
  assert_contains "$out" '+reviewed' "review did not show registered revision content"
  pass "review diff uses the exact registered PR revision"
}

test_moved_pr_revision_refuses() {
  local case_dir moved rc head
  case_dir=$(make_case moved-pr)
  head=$(reviewed_head "$case_dir")
  write_meta "$case_dir" mode=no-mistakes
  mock_gh_head "$case_dir" "$head"
  register_pr "$case_dir" https://github.com/example/repo/pull/9
  printf 'moved\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm moved
  moved=$(git -C "$case_dir/wt" rev-parse HEAD)
  mock_gh_head "$case_dir" "$moved"
  set +e
  run_review "$case_dir" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "moved PR head must refuse review"
  assert_grep "PR head moved from registered revision $head to $moved" "$case_dir/err" \
    "moved PR refusal did not name both revisions"
  pass "review diff refuses a PR head that moved after readiness registration"
}

test_absent_ready_revision_refuses() {
  local case_dir rc
  case_dir=$(make_case absent-ready)
  write_meta "$case_dir" mode=local-only
  set +e
  run_review "$case_dir" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "absent review-ready identity must refuse"
  assert_grep 'no exact review-ready revision' "$case_dir/err" "absent binding diagnostic was not actionable"
  pass "review diff refuses absent revision identity"
}

test_exact_local_revision_is_reviewed() {
  local case_dir out head
  case_dir=$(make_case exact-local)
  head=$(reviewed_head "$case_dir")
  write_meta "$case_dir" mode=local-only "ready_head=$head"
  out=$(run_review "$case_dir") || fail "exact local review failed"
  assert_contains "$out" '+reviewed' "local review did not show bound content"
  pass "review diff uses the exact prepared local revision"
}

test_moved_local_revision_refuses() {
  local case_dir old rc
  case_dir=$(make_case moved-local)
  old=$(reviewed_head "$case_dir")
  write_meta "$case_dir" mode=local-only "ready_head=$old"
  printf 'later\n' > "$case_dir/wt/later.txt"
  git -C "$case_dir/wt" add later.txt
  git -C "$case_dir/wt" commit -qm later
  set +e
  run_review "$case_dir" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "moved local branch must refuse review"
  assert_grep 'local branch moved after readiness' "$case_dir/err" "moved local refusal was not actionable"
  pass "review diff refuses a local branch that moved after preparation"
}

test_registered_pr_revision_is_reviewed
test_moved_pr_revision_refuses
test_absent_ready_revision_refuses
test_exact_local_revision_is_reviewed
test_moved_local_revision_refuses
