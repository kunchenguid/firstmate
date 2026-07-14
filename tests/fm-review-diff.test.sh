#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against the PR head, not a
# stale local branch left behind after no-mistakes fix rounds push to the PR.
# The base side is the repo default branch, unless the task declared a non-default
# intended base (fm-brief.sh --base, recorded as base= in meta).
#
# Matrix:
#   (a) pr= + reachable pr_head= -> diff uses PR head, not the lagging local branch
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) base= declared and still carrying unmerged work, branch under review rooted in
#       it -> diff against that base, not the repo default
#   (f) base= declared but gone from origin -> fall back to the default branch with a
#       warning, never a hard stop
#   (g) base= declared, its work has already LANDED in the default branch (it merged,
#       branch kept), and the branch under review was rebased onto the default branch ->
#       fall back to the default branch: the branch sits there now, so that is its real
#       fork point
#   (h) base= declared and unlanded, but the branch under review was rebased onto the
#       default branch (the pipeline always does) -> fall back to the default branch,
#       because diffing against the base would show every default-branch commit since
#       the base forked as part of the crewmate's change
#   (i) base= declared, its work has LANDED by a SQUASH merge, but the branch under
#       review is STILL ROOTED in the base's own pre-merge commits -> keep the base as
#       the diff base. A squash leaves those commits out of the default branch by commit
#       id, so falling back would take the old fork point as the merge base and present
#       the base's already-merged work as the crewmate's change. Landedness does not move
#       a branch; rootedness is what says where it sits, and it is asked first
#   (j) base= declared, its work has LANDED by a SQUASH merge, its branch has been DELETED
#       from origin, and the branch under review is still rooted in it -> diff against the
#       recorded spawn-time tip (base_sha=). The fork point is still real, there is just no
#       ref left to name it by, and bin/fm-pr-check.sh reasons from that very tip - so
#       falling back to the default branch would both inflate the diff and disagree with the
#       merge gate about the same PR
#   (k) base= declared but origin cannot be asked at all -> stop, do not guess
#   (l) base= absent -> unchanged default-branch diff base
#
# (e) through (k) are not decided here at all: they are fm_base_verdict's single verdict
# (bin/fm-base-lib.sh), the same one bin/fm-pr-check.sh's guard gates the merge on, so the
# review diff and the merge gate can never disagree about what a declared base means. The
# verdict matrix itself is pinned in tests/fm-base-lib.test.sh; these cases only show that
# the diff base honours it.
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

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when pr_head is reachable"
  pass "fm-review-diff uses recorded pr_head instead of the lagging local branch"
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

# A task whose intended base is a feature branch (fm-brief.sh --base, recorded as
# base= in meta) must be reviewed against THAT base. Diffing it against the repo
# default would present the entire feature base's unmerged history as if it were
# the crewmate's change - a misleading, potentially enormous diff at exactly the
# moment firstmate decides whether to relay the PR.
test_declared_base_is_the_diff_base() {
  local case_dir out
  case_dir=$(make_case declared-base)

  # A feature base carrying its own unmerged work, then the crewmate's branch
  # stacked on it carrying only the fix.
  git -C "$case_dir/wt" checkout -q -b feature/base origin/main
  printf 'feature-base-work\n' > "$case_dir/wt/base-only.txt"
  git -C "$case_dir/wt" add base-only.txt
  git -C "$case_dir/wt" commit -qm "feature base work"
  git -C "$case_dir/wt" push -q origin feature/base
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard feature/base
  printf 'crew-fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm "the crewmate's fix"

  write_task_meta "$case_dir" "base=feature/base"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/feature/base' \
    "declared-base: the review should state the declared base as its diff base"
  assert_contains "$out" '+crew-fix' "declared-base: diff should show the crewmate's own change"
  assert_not_contains "$out" 'feature-base-work' \
    "declared-base: diff must not present the feature base's unmerged history as the crewmate's change"
  pass "fm-review-diff diffs a based task against its declared base, not the repo default"
}

test_no_declared_base_still_diffs_against_default() {
  local case_dir out
  case_dir=$(make_case no-declared-base)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/main' \
    "no-declared-base: a task without base= must keep diffing against the repo default"
  pass "fm-review-diff without base= keeps the default-branch diff base"
}

# The normal END-STATE of a stacked PR: the intended base merged and its branch was
# deleted from origin (GitHub does this by default). Erroring out on the missing
# branch would leave firstmate unable to review a PR that is now perfectly ordinary,
# so the diff falls back to the default branch and says why.
test_deleted_base_falls_back_to_default_with_warning() {
  local case_dir out rc
  case_dir=$(make_case deleted-base)

  git -C "$case_dir/wt" checkout -q -b feature/base origin/main
  printf 'feature-base-work\n' > "$case_dir/wt/base-only.txt"
  git -C "$case_dir/wt" add base-only.txt
  git -C "$case_dir/wt" commit -qm "feature base work"
  git -C "$case_dir/wt" push -q origin feature/base
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard feature/base
  printf 'crew-fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm "the crewmate's fix"

  # feature/base merges into main and origin deletes the branch.
  git -C "$case_dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  git -C "$case_dir/origin.git" update-ref -d refs/heads/feature/base

  write_task_meta "$case_dir" "base=feature/base"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  rc=$?
  set -e

  expect_code 0 "$rc" "deleted-base: a gone base must not make the pre-merge review impossible"
  assert_contains "$out" 'diff base: origin/main' \
    "deleted-base: a base that no longer exists on origin must fall back to the default branch"
  assert_grep 'no longer exists on origin' "$case_dir/stderr" \
    "deleted-base: the fallback must say why it is not using the declared base"
  assert_contains "$out" '+crew-fix' "deleted-base: the crewmate's own change should still be shown"
  pass "fm-review-diff falls back to the default branch when the declared base is gone from origin"
}

# The declared base merged but its branch was KEPT on origin (GitHub's delete-on-merge
# is off by default), and the pipeline has left the branch under review rebased onto the
# default branch. THAT is what makes the base the wrong diff base: the branch is not
# rooted in it any more, so diffing against it would take the old fork point as the merge
# base and dress every default-branch commit since then up as the crewmate's change.
# Branch existence is not the question, and neither is landedness on its own - the
# companion case below keeps a merged base as the diff base when the branch is still
# rooted in it.
test_landed_base_falls_back_to_default_with_warning() {
  local case_dir out rc
  case_dir=$(make_case landed-base)

  git -C "$case_dir/wt" checkout -q -b feature/base origin/main
  printf 'feature-base-work\n' > "$case_dir/wt/base-only.txt"
  git -C "$case_dir/wt" add base-only.txt
  git -C "$case_dir/wt" commit -qm "feature base work"
  git -C "$case_dir/wt" push -q origin feature/base

  # feature/base is squash-merged into main; the branch stays on origin. The crewmate's
  # branch is what the pipeline leaves behind: its fix, rebased onto main.
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard origin/main
  git -C "$case_dir/wt" merge -q --squash feature/base >/dev/null
  git -C "$case_dir/wt" commit -qm "squash feature/base"
  git -C "$case_dir/wt" push -q origin "fm/task-x1:main"
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" reset -q --hard origin/main
  printf 'crew-fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm "the crewmate's fix"

  write_task_meta "$case_dir" "base=feature/base"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  rc=$?
  set -e

  expect_code 0 "$rc" "landed-base: a merged base must not break the pre-merge review"
  assert_contains "$out" 'diff base: origin/main' \
    "landed-base: a base whose work is already in the default branch must not be the diff base"
  assert_grep 'already merged' "$case_dir/stderr" \
    "landed-base: the fallback must say why the declared base was not used"
  assert_contains "$out" '+crew-fix' "landed-base: the crewmate's own change should still be shown"
  assert_not_contains "$out" 'feature-base-work' \
    "landed-base: the merged base's work is in main already and must not reappear as the crewmate's change"
  pass "fm-review-diff falls back to the default branch when the declared base has already merged"
}

# The pre-retarget state firstmate actually reviews in, and the one every refusal from
# fm-pr-check.sh sends the reader here to inspect: the base is live and unmerged, but
# the no-mistakes pipeline has rebased the branch onto the default branch. The merge base
# with the declared base is then the old fork point, so diffing against it would present
# the whole default branch's history since the fork as the crewmate's change - exactly
# the misleading diff a declared base exists to prevent, in the other direction. Firstmate
# relays a summary of this diff to the captain, so the wrong content would reach them.
test_unrooted_branch_falls_back_to_default_with_warning() {
  local case_dir out rc
  case_dir=$(make_case unrooted-branch)

  git -C "$case_dir/wt" checkout -q -b feature/base origin/main
  printf 'feature-base-work\n' > "$case_dir/wt/base-only.txt"
  git -C "$case_dir/wt" add base-only.txt
  git -C "$case_dir/wt" commit -qm "feature base work"
  git -C "$case_dir/wt" push -q origin feature/base

  # main moves on after the base forked, and the pipeline rebases the crewmate's branch
  # onto main - carrying none of feature/base's unmerged history.
  git -C "$case_dir/wt" checkout -q -b main-work origin/main
  printf 'unrelated-main-work\n' > "$case_dir/wt/main-only.txt"
  git -C "$case_dir/wt" add main-only.txt
  git -C "$case_dir/wt" commit -qm "unrelated work on main"
  git -C "$case_dir/wt" push -q origin main-work:main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard origin/main
  printf 'crew-fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm "the crewmate's fix"

  write_task_meta "$case_dir" "base=feature/base"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  rc=$?
  set -e

  expect_code 0 "$rc" "unrooted-branch: a rebased branch must not break the pre-merge review"
  assert_contains "$out" 'diff base: origin/main' \
    "unrooted-branch: a branch not rooted in the base's unmerged history must not be diffed against that base"
  assert_grep 'not rooted' "$case_dir/stderr" \
    "unrooted-branch: the fallback must say why the declared base was not used"
  assert_contains "$out" '+crew-fix' "unrooted-branch: the crewmate's own change should be shown"
  assert_not_contains "$out" 'unrelated-main-work' \
    "unrooted-branch: the default branch's own history must not be dressed up as the crewmate's change"
  pass "fm-review-diff falls back to the default branch when the branch under review was rebased off the declared base"
}

# The base SQUASH-merged - firstmate's own default merge method, and GitHub's most
# common setting - and the branch under review is still stacked on it, which is the
# ordinary direct-PR shape (the crewmate owns its branch and never rebases it). A squash
# leaves the base's own commits out of the default branch by commit id, so the merge base
# with the default branch is still the OLD fork point: falling back to the default branch
# here would dress every one of the base's already-merged changes up as the crewmate's,
# and firstmate relays a summary of this diff to the captain. Landedness does not make a
# branch stop being rooted where it is rooted; rootedness is asked first, and it keeps the
# base as the honest fork point.
test_landed_base_still_rooted_keeps_the_base_as_diff_base() {
  local case_dir out rc
  case_dir=$(make_case landed-base-rooted)

  git -C "$case_dir/wt" checkout -q -b feature/base origin/main
  printf 'feature-base-work\n' > "$case_dir/wt/base-only.txt"
  git -C "$case_dir/wt" add base-only.txt
  git -C "$case_dir/wt" commit -qm "feature base work"
  git -C "$case_dir/wt" push -q origin feature/base

  # The crewmate's branch stays stacked on feature/base, carrying the base's own commit.
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard feature/base
  printf 'crew-fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm "the crewmate's fix"

  # feature/base is then SQUASH-merged into main and its branch is kept on origin.
  git -C "$case_dir/wt" checkout -q -b squash-main origin/main
  git -C "$case_dir/wt" merge -q --squash feature/base >/dev/null
  git -C "$case_dir/wt" commit -qm "squash feature/base"
  git -C "$case_dir/wt" push -q origin squash-main:main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" checkout -q fm/task-x1

  write_task_meta "$case_dir" "base=feature/base"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  rc=$?
  set -e

  expect_code 0 "$rc" "landed-base-rooted: a merged base must not break the pre-merge review"
  assert_contains "$out" 'diff base: origin/feature/base' \
    "landed-base-rooted: a branch still rooted in the base must be diffed against that base, merged or not"
  assert_contains "$out" '+crew-fix' "landed-base-rooted: the crewmate's own change should be shown"
  assert_not_contains "$out" 'feature-base-work' \
    "landed-base-rooted: the base's already-merged work was dressed up as part of the crewmate's change"
  assert_grep 'still rooted' "$case_dir/stderr" \
    "landed-base-rooted: the review must say the base merged while the branch still sits on its pre-merge commits"
  pass "fm-review-diff keeps the declared base when the branch is still rooted in it, even after that base merged"
}

# The same branch, the same squash-merged base - but now GitHub auto-deleted the base
# branch when it merged, which it does by default. The branch under review has not moved,
# so it is still rooted in the base's pre-squash commits and the base is still its honest
# fork point; there is simply no ref left to name it by. The recorded spawn-time tip
# (base_sha=) IS that fork point, and it is reachable from the branch under review, so it
# is the diff base. Falling back to the default branch here would take the old fork point
# as the merge base and present the base's already-merged work as the crewmate's change -
# and it would also disagree with bin/fm-pr-check.sh, which reasons from that very tip and
# refuses this PR pending a rebase. Review and the merge gate must tell one story.
test_gone_squash_merged_base_still_rooted_diffs_against_the_recorded_tip() {
  local case_dir out rc base_sha
  case_dir=$(make_case gone-base-rooted)

  git -C "$case_dir/wt" checkout -q -b feature/base origin/main
  printf 'feature-base-work\n' > "$case_dir/wt/base-only.txt"
  git -C "$case_dir/wt" add base-only.txt
  git -C "$case_dir/wt" commit -qm "feature base work"
  git -C "$case_dir/wt" push -q origin feature/base
  base_sha=$(git -C "$case_dir/wt" rev-parse feature/base)

  # The crewmate's branch stays stacked on feature/base.
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard feature/base
  printf 'crew-fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm "the crewmate's fix"

  # feature/base is SQUASH-merged into main and origin deletes the branch.
  git -C "$case_dir/wt" checkout -q -b squash-main origin/main
  git -C "$case_dir/wt" merge -q --squash feature/base >/dev/null
  git -C "$case_dir/wt" commit -qm "squash feature/base"
  git -C "$case_dir/wt" push -q origin squash-main:main
  git -C "$case_dir/wt" push -q origin --delete feature/base
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" checkout -q fm/task-x1

  write_task_meta "$case_dir" "base=feature/base" "base_sha=$base_sha"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  rc=$?
  set -e

  expect_code 0 "$rc" "gone-base-rooted: a gone base must not break the pre-merge review"
  assert_contains "$out" "diff base: $base_sha" \
    "gone-base-rooted: the branch is still rooted in the deleted base, so its recorded spawn-time tip is the honest diff base"
  assert_contains "$out" '+crew-fix' "gone-base-rooted: the crewmate's own change should be shown"
  assert_not_contains "$out" 'feature-base-work' \
    "gone-base-rooted: the deleted base's already-merged work was dressed up as part of the crewmate's change"
  assert_grep 'still rooted' "$case_dir/stderr" \
    "gone-base-rooted: the review must say the head still sits on the merged base's pre-squash commits"
  pass "fm-review-diff diffs against the recorded base tip when the declared base is gone but the branch still sits on it"
}

# A probe origin cannot ANSWER is not the same as a base that is gone: reviewing
# against the wrong base silently would be worse than stopping.
test_unreachable_origin_stops_instead_of_guessing() {
  local case_dir rc
  case_dir=$(make_case unreachable-origin)
  write_task_meta "$case_dir" "base=feature/base"
  git -C "$case_dir/project" remote set-url origin "$case_dir/no-such-origin.git"

  set +e
  run_review_diff "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreachable-origin: an unanswerable base probe must not silently pick a base"
  assert_grep 'could not be asked' "$case_dir/stderr" \
    "unreachable-origin: the error did not name the failed probe"
  pass "fm-review-diff stops when origin cannot be asked whether the declared base exists"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_declared_base_is_the_diff_base
test_deleted_base_falls_back_to_default_with_warning
test_landed_base_falls_back_to_default_with_warning
test_landed_base_still_rooted_keeps_the_base_as_diff_base
test_gone_squash_merged_base_still_rooted_diffs_against_the_recorded_tip
test_unrooted_branch_falls_back_to_default_with_warning
test_unreachable_origin_stops_instead_of_guessing
test_no_declared_base_still_diffs_against_default
