#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against a freshly fetched
# PR head, not a stale local branch or a stale recorded pr_head= left behind
# after no-mistakes fix rounds push to the PR.
#
# Matrix:
#   (a) pr= + reachable pr_head=, no remote pull ref -> offline fallback to recorded SHA
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) pr= + STALE recorded pr_head= + newer remote pull head -> must use fetched head
#       (this is the class that bit reviewers holding merges over "missing" fixes)
#   (f) mode=local-only on a project whose origin is frozen behind the local
#       default branch -> base is the local default, so the review shows the
#       task's own work and not every locally landed commit; a scout, which
#       records no mode, gets the same anchor
#   (g) the same repository state but a pull-request delivery -> base stays
#       origin/<default>, so the review shows everything that PR would carry
#   (h) a local-only branch rebased onto a default branch that advanced, which is
#       what that mode's definition of done orders -> the base follows the branch
#       to the default it caught up with and shows no other task's landing, even
#       after the default branch lands again and neither branch reaches the task
#   (i) a primary checkout whose default branch trails origin, with the task
#       planted on origin's tip -> the stale local branch must not become the
#       anchor, because it would drag origin's newer history into the review
#   (j) local default and origin diverged -> the review anchors on the branch the
#       task was planted on, read off the branch itself
#   (k) the default branch already fast-forwarded onto the branch -> the review
#       is empty and says why rather than passing silently
#   (l) a branch carrying merges from both diverged branches -> its two merge
#       bases are unrelated, which is reported rather than picked by accident
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

# origin.git with a baseline commit and a project clone of it, with no task
# branch yet: the base cases below plant the task on the branch each one needs.
seed_case() {  # <name>
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Land commits on the primary checkout's default branch that origin never
# receives - what bin/fm-merge-local.sh does for a local-only project.
land_locally() {  # <case-dir> <n>...
  local case_dir=$1 n
  shift
  for n in "$@"; do
    printf 'landed %s\n' "$n" > "$case_dir/project/landed-$n.txt"
    git -C "$case_dir/project" add "landed-$n.txt"
    git -C "$case_dir/project" commit -qm "local landing $n"
  done
}

# Push commits to origin that the primary checkout fetches but never pulls.
push_to_origin_only() {  # <case-dir> <n>...
  local case_dir=$1 n
  shift
  git clone -q "$case_dir/origin.git" "$case_dir/_publisher" 2>/dev/null
  for n in "$@"; do
    printf 'upstream %s\n' "$n" > "$case_dir/_publisher/upstream-$n.txt"
    git -C "$case_dir/_publisher" add "upstream-$n.txt"
    git -C "$case_dir/_publisher" commit -qm "upstream $n"
  done
  git -C "$case_dir/_publisher" push -q origin main
  rm -rf "$case_dir/_publisher"
  git -C "$case_dir/project" fetch -q origin
}

# Plant the task worktree on <ref> and give it one commit of its own.
plant_task_branch() {  # <case-dir> <ref>
  local case_dir=$1 ref=$2
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" "$ref"
  printf 'task work\n' > "$case_dir/wt/task-change.txt"
  git -C "$case_dir/wt" add task-change.txt
  git -C "$case_dir/wt" commit -qm "task work"
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

test_frozen_origin_loses_to_the_local_default_branch() {
  local case_dir out contract
  for contract in local-only scout; do
    case_dir=$(seed_case "local-only-base-$contract")
    land_locally "$case_dir" 1 2 3
    plant_task_branch "$case_dir" main
    if [ "$contract" = scout ]; then
      write_task_meta "$case_dir" "kind=scout"
    else
      write_task_meta "$case_dir" "mode=local-only"
    fi
    [ "$(git -C "$case_dir/project" rev-parse origin/main)" != "$(git -C "$case_dir/project" rev-parse main)" ] \
      || fail "$contract: fixture did not leave origin/main behind the local main"

    out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

    assert_contains "$out" 'diff base: main' \
      "$contract: base must be the local default branch that carries the landed work"
    assert_contains "$out" 'task-change.txt' "$contract: the task's own change must be in the diff"
    assert_not_contains "$out" 'landed-' "$contract: locally landed work must not enter the review diff"
  done
  pass "fm-review-diff anchors a delivery that lands locally on the local default branch, not a frozen origin"
}

test_pull_request_delivery_stays_on_the_frozen_origin() {
  local case_dir out
  case_dir=$(seed_case pr-delivery-base)
  land_locally "$case_dir" 1 2 3
  # bin/fm-spawn.sh plants a pull-request delivery on origin's tip; a worker that
  # rebased onto the local default anyway is exactly what the captain has to see
  # before that PR goes out.
  plant_task_branch "$case_dir" main
  write_task_meta "$case_dir" "mode=direct-PR"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/main' \
    "pr-delivery-base: a pull-request delivery must be reviewed against the branch its PR targets"
  assert_contains "$out" 'task-change.txt' "pr-delivery-base: the task's own change must be in the diff"
  assert_contains "$out" 'landed-1.txt' \
    "pr-delivery-base: commits the PR would carry must stay visible to the captain"
  pass "fm-review-diff anchors a pull-request delivery on origin, showing everything its PR would carry"
}

# The local-only definition of done orders the worker to rebase onto the default
# branch whenever it advances, and bin/fm-merge-local.sh refuses anything that is
# not a fast-forward, so this is the normal path rather than a corner case.
test_a_rebased_local_only_branch_reviews_only_its_own_work() {
  local case_dir out
  case_dir=$(seed_case rebased-local-only)
  land_locally "$case_dir" 1 2 3
  plant_task_branch "$case_dir" main
  write_task_meta "$case_dir" "mode=local-only"
  land_locally "$case_dir" 4
  git -C "$case_dir/wt" rebase --quiet main >/dev/null 2>&1 \
    || fail "rebased-local-only: the fixture could not perform the rebase the mode mandates"
  git -C "$case_dir/wt" merge-base --is-ancestor main fm/task-x1 \
    || fail "rebased-local-only: the fixture did not leave the branch on top of the advanced default"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: main' \
    "rebased-local-only: a branch that caught up must be reviewed against the branch it caught up with"
  assert_contains "$out" 'task-change.txt' "rebased-local-only: the task's own change must be in the diff"
  assert_not_contains "$out" 'landed-4.txt' \
    "rebased-local-only: another task's landing must not be attributed to this review"
  pass "fm-review-diff follows a rebased local-only branch to the default it caught up with"
}

# After that rebase the default branch can land again before the captain reviews,
# so NEITHER branch reaches the task branch. Any rule that required a candidate to
# be an ancestor of the branch fell through here and kept a stale anchor.
test_neither_branch_reaching_the_task_still_reviews_only_its_own_work() {
  local case_dir out
  case_dir=$(seed_case moved-on-twice)
  land_locally "$case_dir" 1 2 3
  plant_task_branch "$case_dir" main
  write_task_meta "$case_dir" "mode=local-only"
  land_locally "$case_dir" 4
  git -C "$case_dir/wt" rebase --quiet main >/dev/null 2>&1 \
    || fail "moved-on-twice: the fixture could not perform the rebase the mode mandates"
  land_locally "$case_dir" 5
  git -C "$case_dir/wt" merge-base --is-ancestor main fm/task-x1 2>/dev/null \
    && fail "moved-on-twice: the fixture left the default branch reachable from the task branch"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: main' \
    "moved-on-twice: the default branch meets the task branch later than origin does"
  assert_contains "$out" 'task-change.txt' "moved-on-twice: the task's own change must be in the diff"
  assert_not_contains "$out" 'landed-4.txt' \
    "moved-on-twice: a landing the branch rebased onto must not be attributed to this review"
  assert_not_contains "$out" 'landed-5.txt' \
    "moved-on-twice: a later landing must not be attributed to this review"
  pass "fm-review-diff reviews only the task's work when neither default branch reaches the branch"
}

# The mirror image: origin advanced and the primary checkout never pulled, so its
# local default trails the origin tip the task was planted on. Anchoring on the
# stale local branch would drag every commit origin gained into the review.
test_a_stale_local_default_does_not_loosen_the_review() {
  local case_dir out
  case_dir=$(seed_case stale-primary)
  push_to_origin_only "$case_dir" 1 2 3
  plant_task_branch "$case_dir" origin/main
  write_task_meta "$case_dir" "mode=local-only"
  git -C "$case_dir/project" merge-base --is-ancestor main origin/main \
    || fail "stale-primary: the fixture did not leave the local default behind origin"
  [ "$(git -C "$case_dir/project" rev-parse main)" != "$(git -C "$case_dir/project" rev-parse origin/main)" ] \
    || fail "stale-primary: the fixture left the local default at origin's tip"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/main' \
    "stale-primary: a local default behind the planted base must not become the anchor"
  assert_contains "$out" 'task-change.txt' "stale-primary: the task's own change must be in the diff"
  assert_not_contains "$out" 'upstream-' \
    "stale-primary: origin's commits the crewmate never authored must stay out of the review"
  pass "fm-review-diff keeps origin as the anchor when the local default branch trails it"
}

# Diverged default branches: the primary landed work origin never received AND
# origin received a commit the primary never pulled. Which anchor is right depends
# on where the task was planted, and the merge-base rule reads that off the branch
# itself instead of guessing from the two branches alone.
test_diverged_default_branches_anchor_where_the_task_was_planted() {
  local case_dir out planted expected foreign
  for planted in main origin/main; do
    case_dir=$(seed_case "diverged-${planted//\//-}")
    land_locally "$case_dir" 1 2
    push_to_origin_only "$case_dir" 1
    plant_task_branch "$case_dir" "$planted"
    write_task_meta "$case_dir" "mode=local-only"
    git -C "$case_dir/project" merge-base --is-ancestor main origin/main 2>/dev/null \
      && fail "diverged-$planted: the fixture left the local default contained by origin"
    git -C "$case_dir/project" merge-base --is-ancestor origin/main main 2>/dev/null \
      && fail "diverged-$planted: the fixture left origin contained by the local default"
    if [ "$planted" = main ]; then
      expected=main
      foreign=upstream-1.txt
    else
      expected=origin/main
      foreign=landed-1.txt
    fi

    out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

    assert_contains "$out" "diff base: $expected" \
      "diverged-$planted: the review must anchor on the branch the task was planted on"
    assert_contains "$out" 'task-change.txt' "diverged-$planted: the task's own change must be in the diff"
    assert_not_contains "$out" "$foreign" \
      "diverged-$planted: a commit only the other branch carries must not enter the review"
  done
  pass "fm-review-diff anchors diverged default branches on the one the task was planted on"
}

# Reviewing after bin/fm-merge-local.sh fast-forwarded the default branch onto the
# branch: nothing is left to review against it, and the review says so instead of
# printing an empty diff that merely looks reviewed.
test_a_landed_branch_reports_an_empty_review_and_says_why() {
  local case_dir out
  case_dir=$(seed_case already-landed)
  land_locally "$case_dir" 1 2 3
  plant_task_branch "$case_dir" main
  write_task_meta "$case_dir" "mode=local-only"
  git -C "$case_dir/project" merge --ff-only -q fm/task-x1 >/dev/null 2>&1 \
    || fail "already-landed: the fixture could not fast-forward the default branch onto the branch"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: main' "already-landed: the anchor stays on the branch the task landed on"
  assert_contains "$out" 'no changes vs main' "already-landed: a landed branch has nothing left to review"
  assert_contains "$(cat "$case_dir/stderr")" 'already contains fm/task-x1' \
    "already-landed: an empty review must say why it is empty"
  pass "fm-review-diff says why a landed branch reviews as empty"
}

# A branch that merged BOTH diverged default branches meets each of them at a
# different commit, and neither merge base descends from the other. There is no
# tighter anchor to pick, so the review says so and takes the local default.
test_unrelated_merge_bases_are_reported_not_guessed() {
  local case_dir out
  case_dir=$(seed_case unrelated-bases)
  land_locally "$case_dir" 1
  push_to_origin_only "$case_dir" 1
  plant_task_branch "$case_dir" main
  write_task_meta "$case_dir" "mode=local-only"
  git -C "$case_dir/wt" merge --no-ff -q -m "merge origin" origin/main >/dev/null 2>&1 \
    || fail "unrelated-bases: the fixture could not merge origin into the branch"
  git -C "$case_dir/wt" merge-base --is-ancestor main origin/main 2>/dev/null \
    && fail "unrelated-bases: the fixture left the two default branches comparable"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: main' \
    "unrelated-bases: with no tighter anchor the review takes the local default"
  assert_contains "$(cat "$case_dir/stderr")" 'unrelated commits' \
    "unrelated-bases: an undecidable pair must be reported, never picked by accident"
  assert_contains "$out" 'task-change.txt' "unrelated-bases: the task's own change must be in the diff"
  pass "fm-review-diff reports unrelated merge bases instead of choosing one by accident"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_frozen_origin_loses_to_the_local_default_branch
test_pull_request_delivery_stays_on_the_frozen_origin
test_a_rebased_local_only_branch_reviews_only_its_own_work
test_neither_branch_reaching_the_task_still_reviews_only_its_own_work
test_a_stale_local_default_does_not_loosen_the_review
test_diverged_default_branches_anchor_where_the_task_was_planted
test_a_landed_branch_reports_an_empty_review_and_says_why
test_unrelated_merge_bases_are_reported_not_guessed
