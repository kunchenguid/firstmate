#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against a freshly fetched
# PR head, not a stale local branch or a stale recorded pr_head= left behind
# after no-mistakes fix rounds push to the PR. The base side is equally
# authoritative: it is the task's recorded delivery target branch when it has
# one, so a task stacked on a feature branch is not reviewed against a
# merge-base that predates it.
#
# Matrix:
#   (a) pr= + reachable pr_head=, no remote pull ref -> offline fallback to recorded SHA
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) pr= + STALE recorded pr_head= + newer remote pull head -> must use fetched head
#       (this is the class that bit reviewers holding merges over "missing" fixes)
#   (f) base= recorded -> diff against that branch, not the repo default branch
#   (g) base= recorded but never pushed, remote reachable -> local ref + warning
#   (h) origin carries mirror/<base> but not <base> -> still absent, not present
#   (i) origin unreachable -> refuse; a base that cannot be confirmed is never guessed
#   (j) base= recorded and resolving nowhere -> refuse, naming the branch and its source
#   (k) a tag shares the base branch name -> measure the branch, never the tag
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$@"
}

# Git resolves a bare `<name>` through refs/tags/<name> BEFORE refs/heads/<name>,
# so a repo that also carries a tag named like the delivery target branch would
# have the review silently taken against the tag - an arbitrary old point in
# history presented as the branch the task lands on. Naming the full ref is what
# makes the measured base the one the comment claims.
test_tag_named_like_the_base_does_not_shadow_the_branch() {
  local case_dir out err
  case_dir=$(make_case tag-shadow)

  git -C "$case_dir/wt" checkout -q -b feat/local-stack
  printf 'local-stack-only\n' > "$case_dir/wt/stack.txt"
  git -C "$case_dir/wt" add stack.txt
  git -C "$case_dir/wt" commit -qm "commit only the unpushed local stack carries"
  # A tag pinned to the older origin baseline, named exactly like the branch. A
  # bare-name base resolves to THIS, dragging the branch's own commit into the
  # diff as the task's work.
  git -C "$case_dir/wt" tag feat/local-stack main
  git -C "$case_dir/wt" checkout -q -B fm/task-x1 refs/heads/feat/local-stack
  printf 'task-change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "the task's own change"

  write_task_meta "$case_dir" "mode=local-only" "base=feat/local-stack"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  err=$(cat "$case_dir/stderr")

  assert_contains "$out" 'diff base: refs/heads/feat/local-stack' \
    "tag-shadow: the base must name the branch ref, not a bare name a tag can win"
  assert_contains "$out" '+task-change' \
    "tag-shadow: the task's own change must be in the diff"
  assert_not_contains "$out" 'local-stack-only' \
    "tag-shadow: a same-named tag must not drag the branch's own commits into the diff"
  assert_contains "$err" 'origin has no feat/local-stack' \
    "tag-shadow: the classifier must still report the branch as absent from origin"
  pass "fm-review-diff measures the branch ref when a tag shares the base branch name"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  # No remote pull ref: fetch fails, recorded pr_head is the offline fallback.
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when recorded pr_head is reachable offline"
  pass "fm-review-diff falls back to recorded pr_head when pull head cannot be fetched"
}

test_stale_recorded_pr_head_loses_to_fetched_pull_head() {
  local case_dir out stale_sha
  case_dir=$(make_case stale-recorded)
  stale_and_pr_commits "$case_dir"
  stale_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)
  # Remote PR head is newer (pipeline fix); meta still points at the older local tip.
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$stale_sha"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' \
    "stale-recorded: diff must show the fetched PR head, not the recorded stale SHA"
  assert_not_contains "$out" 'stale-local' \
    "stale-recorded: diff must not use the stale local/recorded content"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "stale-recorded: fetch of refs/pull/<n>/head should succeed"
  # Pre-fix behavior preferred reachable recorded pr_head= and would show stale-local.
  [ "$stale_sha" != "$PR_SHA" ] || fail "stale-recorded: fixture did not diverge recorded vs PR head"
  pass "fm-review-diff prefers freshly fetched PR head over a stale recorded pr_head="
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}

# A task's delivery target branch is part of its contract. Reviewing a task
# stacked on a long-lived feature branch against the repo default branch drags
# every commit that branch carries beyond the default into the diff, so the
# review that gates the merge describes work the crewmate never did.
test_recorded_base_is_the_review_base() {
  local case_dir out
  case_dir=$(make_case recorded-base)

  git -C "$case_dir/wt" checkout -q -b feat/stack
  printf 'feature-branch-only\n' > "$case_dir/wt/stack.txt"
  git -C "$case_dir/wt" add stack.txt
  git -C "$case_dir/wt" commit -qm "commit that only feat/stack carries"
  git -C "$case_dir/wt" push -q origin feat/stack
  git -C "$case_dir/wt" checkout -q -B fm/task-x1 feat/stack
  printf 'task-change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "the task's own change"

  write_task_meta "$case_dir" "base=feat/stack"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/feat/stack' \
    "recorded-base: review must resolve the recorded delivery target branch"
  assert_contains "$out" '+task-change' \
    "recorded-base: the task's own change must be in the diff"
  assert_not_contains "$out" 'feature-branch-only' \
    "recorded-base: commits feat/stack already carries must not read as the task's work"
  pass "fm-review-diff reviews against the recorded delivery target branch"
}

# A local-only task stacks on a branch its own Rule 1 forbids pushing, so the
# remote cannot carry it and the local ref is the authority - the same ref
# bin/fm-merge-local.sh lands from. Refusing here would leave the operator unable
# to review a branch fm-merge-local.sh will happily merge.
test_unpushed_recorded_base_uses_the_local_ref() {
  local case_dir out err
  case_dir=$(make_case local-base)

  git -C "$case_dir/wt" checkout -q -b feat/local-stack
  printf 'local-stack-only\n' > "$case_dir/wt/stack.txt"
  git -C "$case_dir/wt" add stack.txt
  git -C "$case_dir/wt" commit -qm "commit only the unpushed local stack carries"
  git -C "$case_dir/wt" checkout -q -B fm/task-x1 feat/local-stack
  printf 'task-change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "the task's own change"

  write_task_meta "$case_dir" "mode=local-only" "base=feat/local-stack"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  err=$(cat "$case_dir/stderr")

  assert_contains "$out" 'diff base: refs/heads/feat/local-stack' \
    "local-base: an unpushed delivery target branch must review against its local ref"
  assert_contains "$out" '+task-change' \
    "local-base: the task's own change must be in the diff"
  assert_not_contains "$out" 'local-stack-only' \
    "local-base: commits the local stack already carries must not read as the task's work"
  assert_contains "$err" 'origin has no feat/local-stack' \
    "local-base: the local-ref fallback must say the remote does not carry the branch"
  pass "fm-review-diff reviews an unpushed delivery target branch against its local ref"
}

# "Does origin carry the target?" must ask about the exact ref the fetch will
# request. ls-remote matches a pattern against the TAIL of each ref on a
# path-component boundary, so a bare branch name also matches a remote
# `mirror/<target>` - classifying an unpushed base as present and sending the
# review down a fetch that cannot succeed.
test_suffix_colliding_remote_branch_is_not_the_target() {
  local case_dir out err
  case_dir=$(make_case suffix-collision)

  git -C "$case_dir/wt" checkout -q -b feat/local-stack
  printf 'local-stack-only\n' > "$case_dir/wt/stack.txt"
  git -C "$case_dir/wt" add stack.txt
  git -C "$case_dir/wt" commit -qm "commit only the unpushed local stack carries"
  # origin carries mirror/feat/local-stack but never feat/local-stack itself.
  git -C "$case_dir/wt" push -q origin "feat/local-stack:refs/heads/mirror/feat/local-stack"
  git -C "$case_dir/wt" checkout -q -B fm/task-x1 feat/local-stack
  printf 'task-change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "the task's own change"

  write_task_meta "$case_dir" "mode=local-only" "base=feat/local-stack"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  err=$(cat "$case_dir/stderr")

  assert_contains "$out" 'diff base: refs/heads/feat/local-stack' \
    "suffix-collision: a remote mirror/<base> must not read as origin carrying <base>"
  assert_contains "$out" '+task-change' \
    "suffix-collision: the task's own change must be in the diff"
  assert_contains "$err" 'origin has no feat/local-stack' \
    "suffix-collision: the classifier must report the exact ref as absent"
  pass "fm-review-diff does not mistake a remote mirror/<base> for the delivery target branch"
}

# An unreachable remote is a STOP, not a fallback. It cannot be told apart from a
# ref-absent remote by `git fetch`'s exit status alone, and guessing wrong means
# reviewing against a local base that lags origin - which presents commits the
# crewmate never wrote as its work, on the tool that gates the merge.
test_unreachable_remote_refuses_rather_than_guessing() {
  local case_dir status out err
  case_dir=$(make_case unreachable-remote)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"
  git -C "$case_dir/project" remote set-url origin "$case_dir/does-not-exist.git"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  status=$?
  set -e
  err=$(cat "$case_dir/stderr")

  expect_code 1 "$status" "unreachable-remote: an unreachable origin must stop the review"
  assert_not_contains "$out" 'diff base:' \
    "unreachable-remote: must not review against a base it could not confirm"
  assert_contains "$err" 'cannot reach origin' \
    "unreachable-remote: the refusal must say the remote could not be reached"
  assert_contains "$err" "$case_dir/does-not-exist.git" \
    "unreachable-remote: git's own reason must survive on stderr, not be discarded"
  pass "fm-review-diff refuses to review when origin cannot be reached"
}

# A base that resolves NEITHER on the remote NOR locally is refused rather than
# reviewed against a guessed branch: a review against the wrong base is the
# failure this resolution exists to prevent.
test_unresolvable_recorded_base_is_refused() {
  local case_dir status err
  case_dir=$(make_case missing-base)
  write_task_meta "$case_dir" "base=feat/never-existed"

  set +e
  run_review_diff "$case_dir" task-x1 >/dev/null 2> "$case_dir/stderr"
  status=$?
  set -e
  err=$(cat "$case_dir/stderr")

  expect_code 1 "$status" "missing-base: an unresolvable delivery target branch must refuse"
  assert_contains "$err" 'base refs/heads/feat/never-existed does not exist' \
    "missing-base: the refusal must name the branch it could not resolve"
  assert_contains "$err" "this task's recorded delivery target branch" \
    "missing-base: the refusal must say where the measured branch came from"
  pass "fm-review-diff refuses when the recorded delivery target branch resolves nowhere"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_recorded_base_is_the_review_base
test_unpushed_recorded_base_uses_the_local_ref
test_suffix_colliding_remote_branch_is_not_the_target
test_unreachable_remote_refuses_rather_than_guessing
test_unresolvable_recorded_base_is_refused
test_tag_named_like_the_base_does_not_shadow_the_branch
