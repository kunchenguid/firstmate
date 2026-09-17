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
#   (f) workspace_state=released (no worktree) -> no-checkout review in the project
#       clone from the forge's current head and actual (possibly stacked or
#       retargeted) base, refreshing the durable proof and refusing unavailable
#       identity, forge, fetch, or hash proof
#       (this is the class that bit reviewers holding merges over "missing" fixes)
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

# make_released_case <name>: a stacked PR (#9, head fm/task-x1 on base
# fm/lower, itself on main) whose workspace is gone. A fake gh answers
# `gh pr view` from $case/forge.tsv, the forge row the test controls.
make_released_case() {
  local case_dir
  case_dir=$(make_case "$1")
  git -C "$case_dir/wt" checkout -q -b fm/lower
  printf 'lower-layer\n' > "$case_dir/wt/lower.txt"
  git -C "$case_dir/wt" add lower.txt
  git -C "$case_dir/wt" commit -qm "lower stack layer"
  git -C "$case_dir/wt" push -q origin fm/lower
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard fm/lower
  printf 'upper-layer\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "upper stack layer"
  git -C "$case_dir/wt" push -q origin HEAD:refs/pull/9/head
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git -C "$case_dir/project" branch -q -D fm/task-x1 fm/lower
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
[ -f "$case_dir/forge.tsv" ] || exit 1
cat "$case_dir/forge.tsv"
SH
  chmod +x "$case_dir/fakebin/gh"
  printf '%s\n' "$case_dir"
}

origin_sha() { git -C "$1/origin.git" rev-parse "$2"; }

forge_row() {  # <case-dir> <head> <base-branch> <base-oid> [url]
  printf '%s\t%s\t%s\t%s\t%s\n' OPEN "$2" "$3" "$4" \
    "${5:-https://github.com/example/repo/pull/9}" > "$1/forge.tsv"
}

write_released_meta() {  # <case-dir> [extra kv...]
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=" \
    "project=$case_dir/project" \
    "workspace_state=released" \
    "$@"
}

run_released_review() {
  local case_dir=$1
  shift
  PATH="$case_dir/fakebin:$PATH" run_review_diff "$case_dir" "$@"
}

meta_line() { sed -n "s/^$2=//p" "$1/state/task-x1.meta" | tail -1; }

pr_identity_readable() {
  bash -c '. "$1"; fm_pr_metadata_identity_parse "$2"' _ "$ROOT/bin/fm-pr-lib.sh" "$1/state/task-x1.meta"
}

test_released_task_reviews_original_stack_without_a_checkout() {
  local case_dir out pr_sha lower_sha before_head before_worktrees
  case_dir=$(make_released_case released-stacked)
  pr_sha=$(origin_sha "$case_dir" refs/pull/9/head)
  lower_sha=$(origin_sha "$case_dir" refs/heads/fm/lower)
  forge_row "$case_dir" "$pr_sha" fm/lower "$lower_sha"
  write_released_meta "$case_dir" "workspace_base=fm/lower" \
    "pr=https://github.com/example/repo/pull/9" "pr_head=$pr_sha"
  before_head=$(git -C "$case_dir/project" rev-parse HEAD)
  before_worktrees=$(git -C "$case_dir/project" worktree list --porcelain)

  out=$(run_released_review "$case_dir" task-x1) || fail "released stacked review failed: $out"
  assert_contains "$out" '+upper-layer' "released: the PR's own layer must be shown"
  assert_not_contains "$out" 'lower-layer' "released: a stacked PR must diff against its actual base, not trunk"
  assert_contains "$out" 'fm/lower' "released: the diff base line should name the actual PR base"
  assert_not_contains "$out" 'changed:' "released: an unchanged PR must report no change"
  assert_equals "$before_head" "$(git -C "$case_dir/project" rev-parse HEAD)" "released: review moved the project clone's HEAD"
  assert_equals "$before_worktrees" "$(git -C "$case_dir/project" worktree list --porcelain)" \
    "released: review reconstructed a workspace merely to read"
  [ -z "$(git -C "$case_dir/project" status --porcelain)" ] || fail "released: review dirtied the project clone"
  assert_equals "$pr_sha" "$(git -C "$case_dir/project" rev-parse refs/fm-review/task-x1/head)" \
    "released: the head must be fetched into the task's own ref namespace"

  out=$(run_released_review "$case_dir" task-x1 --stat) || fail "released --stat review failed: $out"
  assert_contains "$out" 'feature.txt' "released --stat: should summarize the changed file"
  assert_not_contains "$out" '+upper-layer' "released --stat: must not print the full diff"
  pass "fm-review-diff reviews a released stacked PR from the forge's head and base with no checkout"
}

test_released_task_follows_a_retargeted_stack() {
  local case_dir out pr_sha main_sha
  case_dir=$(make_released_case released-retargeted)
  pr_sha=$(origin_sha "$case_dir" refs/pull/9/head)
  # The lower PR merged and its branch was deleted; GitHub retargeted #9 to trunk.
  git -C "$case_dir/origin.git" update-ref refs/heads/main refs/heads/fm/lower
  git -C "$case_dir/origin.git" update-ref -d refs/heads/fm/lower
  main_sha=$(origin_sha "$case_dir" refs/heads/main)
  forge_row "$case_dir" "$pr_sha" main "$main_sha"
  write_released_meta "$case_dir" "workspace_base=fm/lower" \
    "pr=https://github.com/example/repo/pull/9" "pr_head=$pr_sha"

  out=$(run_released_review "$case_dir" task-x1) || fail "retargeted stack review failed: $out"
  assert_contains "$out" 'changed: PR #9 base was retargeted from fm/lower to main' "retarget must be surfaced"
  assert_contains "$out" '+upper-layer' "retargeted: the upper layer must still be reviewable"
  assert_not_contains "$out" 'lower-layer' "retargeted: the merged lower layer is now part of the base"
  assert_equals main "$(meta_line "$case_dir" workspace_base)" "retargeted: the durable base proof was not refreshed"
  pr_identity_readable "$case_dir" || fail "retargeted: the refreshed record is unreadable to the PR merge monitor"
  pass "fm-review-diff follows GitHub's retarget of an upper stacked PR without restoring a workspace"
}

test_released_task_follows_an_advanced_head() {
  local case_dir out old_sha new_sha lower_sha
  case_dir=$(make_released_case released-advanced)
  old_sha=$(origin_sha "$case_dir" refs/pull/9/head)
  lower_sha=$(origin_sha "$case_dir" refs/heads/fm/lower)
  git clone -q "$case_dir/origin.git" "$case_dir/pusher" 2>/dev/null
  git -C "$case_dir/pusher" fetch -q origin refs/pull/9/head
  git -C "$case_dir/pusher" checkout -q FETCH_HEAD
  printf 'later-fix\n' > "$case_dir/pusher/later.txt"
  git -C "$case_dir/pusher" add later.txt
  git -C "$case_dir/pusher" commit -qm "later push to the PR"
  git -C "$case_dir/pusher" push -q origin HEAD:refs/pull/9/head
  new_sha=$(origin_sha "$case_dir" refs/pull/9/head)
  forge_row "$case_dir" "$new_sha" fm/lower "$lower_sha"
  write_released_meta "$case_dir" "workspace_base=fm/lower" "workspace_head=$old_sha" \
    "pr=https://github.com/example/repo/pull/9" "pr_head=$old_sha"

  out=$(run_released_review "$case_dir" task-x1) || fail "advanced head review failed: $out"
  assert_contains "$out" "changed: PR #9 head advanced from $old_sha to $new_sha" "head advance must be surfaced"
  assert_contains "$out" '+later-fix' "advanced: the review must show the current head, not the recorded one"
  assert_equals "$new_sha" "$(meta_line "$case_dir" pr_head)" "advanced: the durable head proof was not refreshed"
  pr_identity_readable "$case_dir" || fail "advanced: the refreshed record is unreadable to the PR merge monitor"

  out=$(run_released_review "$case_dir" task-x1) || fail "second review failed: $out"
  assert_not_contains "$out" 'changed:' "a refreshed record must converge and report no further change"
  pass "fm-review-diff follows an advanced PR head, refreshes its durable proof, and converges"
}

test_released_task_refuses_unavailable_or_mismatched_proof() {
  local case_dir out rc pr_sha lower_sha main_sha before
  case_dir=$(make_released_case released-refusals)
  pr_sha=$(origin_sha "$case_dir" refs/pull/9/head)
  lower_sha=$(origin_sha "$case_dir" refs/heads/fm/lower)
  main_sha=$(origin_sha "$case_dir" refs/heads/main)
  refused() {  # <expected-text> <label>
    before=$(cat "$case_dir/state/task-x1.meta")
    rc=0; out=$(run_released_review "$case_dir" task-x1 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$2: must refuse"
    assert_contains "$out" "$1" "$2: refusal was not explicit"
    assert_not_contains "$out" 'upper-layer' "$2: a refused review must print no diff"
    assert_equals "$before" "$(cat "$case_dir/state/task-x1.meta")" "$2: a refused review rewrote the record"
  }

  write_released_meta "$case_dir" "workspace_base=fm/lower" "pr_head=$pr_sha"
  forge_row "$case_dir" "$pr_sha" fm/lower "$lower_sha"
  refused 'no canonical GitHub pull-request URL' "missing PR identity"

  write_released_meta "$case_dir" "workspace_base=fm/lower" \
    "pr=https://github.com/example/repo/pull/9" "pr_head=$pr_sha"
  rm -f "$case_dir/forge.tsv"
  refused 'could not read PR #9 from the forge' "inaccessible forge"

  forge_row "$case_dir" "$pr_sha" fm/lower "$lower_sha" https://github.com/example/other/pull/9
  refused 'not task task-x1'"'"'s recorded' "forge answering for another repository"

  forge_row "$case_dir" "$lower_sha" fm/lower "$lower_sha"
  refused "does not match the forge's head" "fetched head hash mismatch"

  forge_row "$case_dir" "$pr_sha" main "$pr_sha"
  refused 'is not on the fetched base branch main' "base hash not on the base branch"

  forge_row "$case_dir" "$pr_sha" fm/lower "$lower_sha"
  git -C "$case_dir/project" remote set-url origin "$case_dir/no-such-origin.git"
  refused 'remote proof is unavailable' "unfetchable remote"
  pass "fm-review-diff refuses a released task whose identity, forge, fetch, or hash proof is unavailable"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_released_task_reviews_original_stack_without_a_checkout
test_released_task_follows_a_retargeted_stack
test_released_task_follows_an_advanced_head
test_released_task_refuses_unavailable_or_mismatched_proof
