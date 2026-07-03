#!/usr/bin/env bash
# Behavior tests for the configurable base/merge-target branch of ship tasks
# (fm-spawn --base -> base= in meta -> fm-brief/fm-review-diff/fm-merge-local/
# fm-teardown honoring it).
#
# base= in state/<id>.meta is the single source of truth every consumer reads;
# a meta without base= must behave exactly as before the feature existed.
#
# Matrix:
#   spawn:    --base records base= in meta (single and batch); absent flag writes
#             no base= line; --scout/--secondmate + --base refuse fast.
#   brief:    --base rewrites the ship Setup branch step to start from the base
#             branch and points local-only landing text at it; no flag keeps the
#             plain default-branch step; --scout/--secondmate + --base refuse.
#   review:   base= diffs against the local base branch (no origin) or
#             origin/<base> (remote-backed); no base= keeps the default branch.
#   merge:    base= fast-forwards the base branch (default branch untouched),
#             refuses a checkout not on the base branch, refuses divergence with
#             the same rebase advice, refuses a missing base branch.
#   teardown: local-only work merged into the recorded base branch is landed;
#             work merged nowhere (or only into the default branch) still
#             refuses; the content-landed fallback checks origin/<base>, not
#             origin/<default>.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
REVIEW="$ROOT/bin/fm-review-diff.sh"
MERGE="$ROOT/bin/fm-merge-local.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-base-branch)

# --- fm-spawn harness (fake tmux + treehouse, real isolated worktree) --------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" FM_BACKEND=tmux \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_spawn_case() {
  # shellcheck disable=SC2034  # CASE_DIR is part of the record; not every test reads it
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_spawn_records_base_in_meta() {
  local rec id out status
  id='base-meta-z1'
  rec=$(make_spawn_case spawn-base "$id")
  read_spawn_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --base feature/train)
  status=$?
  expect_code 0 "$status" "ship spawn with --base should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "base=feature/train" "$HOME_DIR/state/$id.meta" "meta missing base=feature/train"
  pass "fm-spawn --base records base= in the task's meta"
}

test_spawn_without_base_writes_no_base_line() {
  local rec id out status
  id='base-absent-z2'
  rec=$(make_spawn_case spawn-no-base "$id")
  read_spawn_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "ship spawn without --base should succeed"
  assert_no_grep "base=" "$HOME_DIR/state/$id.meta" "meta unexpectedly has a base= line without --base"
  pass "fm-spawn without --base keeps meta byte-compatible (no base= line)"
}

test_spawn_batch_threads_base_to_every_pair() {
  local rec id1 id2 out status
  id1='base-batch-a-z3'
  id2='base-batch-b-z4'
  rec=$(make_spawn_case spawn-batch "$id1" "$id2")
  read_spawn_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --base feature/train)
  status=$?
  expect_code 0 "$status" "batch spawn with --base should succeed"
  assert_grep "base=feature/train" "$HOME_DIR/state/$id1.meta" "first pair's meta missing base="
  assert_grep "base=feature/train" "$HOME_DIR/state/$id2.meta" "second pair's meta missing base="
  pass "batch dispatch threads a shared --base into every pair's meta"
}

test_spawn_refuses_base_for_scout_and_secondmate() {
  local rec id out status kind
  id='base-refuse-z5'
  rec=$(make_spawn_case spawn-refuse "$id")
  read_spawn_case "$rec"

  for kind in scout secondmate; do
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "--$kind" --base feature/train)
    status=$?
    expect_code 1 "$status" "--$kind with --base should refuse"
    assert_contains "$out" "error: --base applies only to ship tasks; refusing for --$kind" \
      "--$kind refusal message missing"
    assert_absent "$HOME_DIR/state/$id.meta" "--$kind refusal should happen before meta is written"
  done
  pass "fm-spawn refuses --base for --scout and --secondmate before any side effect"
}

# --- fm-brief -----------------------------------------------------------------

run_brief() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" "$@" 2>&1
}

make_brief_home() {
  local name=$1 mode=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state"
  printf -- '- myrepo [%s] - test project (added 2026-07-03)\n' "$mode" > "$home/data/projects.md"
  printf '%s\n' "$home"
}

test_brief_base_rewrites_ship_setup() {
  local home id brief
  home=$(make_brief_home brief-base local-only)
  id='brief-base-z6'
  run_brief "$home" "$id" myrepo --base feature/train >/dev/null || fail "brief --base scaffold failed"
  brief="$home/data/$id/brief.md"
  assert_grep 'git checkout -b fm/'"$id"' feature/train' "$brief" "Setup does not branch from the base branch"
  assert_grep 'git rev-parse --verify feature/train' "$brief" "Setup does not verify the base branch exists"
  assert_grep 'git fetch origin feature/train:feature/train' "$brief" "Setup does not offer the origin fetch fallback"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal backticks in the brief
  assert_grep 'firstmate merges it into local `feature/train`' "$brief" "local-only landing text does not target the base branch"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal backticks in the brief
  assert_no_grep 'into local `main`' "$brief" "local-only landing text still mentions main despite --base"
  pass "fm-brief --base starts the ship branch from the base branch and lands into it"
}

test_brief_without_base_keeps_default_step() {
  local home id brief
  home=$(make_brief_home brief-plain local-only)
  id='brief-plain-z7'
  run_brief "$home" "$id" myrepo >/dev/null || fail "plain brief scaffold failed"
  brief="$home/data/$id/brief.md"
  assert_grep '1. First action: create your branch: `git checkout -b fm/'"$id"'`' "$brief" \
    "plain scaffold lost the original branch step"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal backticks in the brief
  assert_grep 'firstmate merges it into local `main`' "$brief" "plain local-only landing text changed"
  assert_no_grep 'base branch' "$brief" "plain scaffold unexpectedly mentions a base branch"
  pass "fm-brief without --base keeps the default-branch scaffold wording"
}

test_brief_refuses_base_for_scout_and_secondmate() {
  local home out status
  home=$(make_brief_home brief-refuse no-mistakes)
  out=$(run_brief "$home" brief-refuse-z8 myrepo --scout --base feature/train)
  status=$?
  expect_code 1 "$status" "brief --scout with --base should refuse"
  assert_contains "$out" "error: --base applies only to ship briefs; refusing for --scout" \
    "scout brief refusal message missing"
  out=$(run_brief "$home" brief-refuse-z9 --secondmate alpha --base feature/train)
  status=$?
  expect_code 1 "$status" "brief --secondmate with --base should refuse"
  assert_contains "$out" "error: --base applies only to ship briefs; refusing for --secondmate" \
    "secondmate brief refusal message missing"
  pass "fm-brief refuses --base for --scout and --secondmate"
}

# --- fm-review-diff / fm-merge-local / fm-teardown fixtures -------------------

# Build a project with a default branch, a feature base branch holding one
# base-only commit, and a task worktree branched from the base branch with one
# task commit. Echoes "<case_dir>|<default-branch>".
make_base_project_case() {
  local name=$1 case_dir proj wt default
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$case_dir/state" "$case_dir/config"
  touch "$case_dir/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  default=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" branch feature
  git -C "$proj" checkout -q feature
  printf 'base work\n' > "$proj/base-only.txt"
  git -C "$proj" add base-only.txt
  git -C "$proj" commit -qm "base-only commit"
  git -C "$proj" worktree add -q -b fm/task-x1 "$wt" feature
  printf 'task work\n' > "$wt/task.txt"
  git -C "$wt" add task.txt
  git -C "$wt" commit -qm "task commit"
  printf '%s\n' "$case_dir|$default"
}

write_task_meta() {
  local case_dir=$1 mode=$2 base=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=$mode"
  [ -z "$base" ] || printf 'base=%s\n' "$base" >> "$case_dir/state/task-x1.meta"
}

run_with_state() {
  local case_dir=$1 script=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$script" "$@"
}

# --- fm-review-diff ------------------------------------------------------------

test_review_diff_uses_recorded_base_locally() {
  local rec case_dir default out
  rec=$(make_base_project_case review-local)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  write_task_meta "$case_dir" local-only feature

  out=$(run_with_state "$case_dir" "$REVIEW" task-x1 --stat 2>&1) || fail "review-diff with base= failed: $out"
  assert_contains "$out" "diff base: feature" "review did not diff against the recorded base branch"
  assert_contains "$out" "task.txt" "review diff missing the task's change"
  assert_not_contains "$out" "base-only.txt" "review diff leaked the base branch's own commits"
  pass "fm-review-diff diffs against the recorded local base branch"
}

test_review_diff_uses_origin_base_when_remote_backed() {
  local rec case_dir default out
  rec=$(make_base_project_case review-remote)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  fm_git_add_origin "$case_dir/project" "$case_dir/origin.git"
  git -C "$case_dir/project" push -q origin feature
  write_task_meta "$case_dir" no-mistakes feature

  out=$(run_with_state "$case_dir" "$REVIEW" task-x1 --stat 2>&1) || fail "remote review-diff with base= failed: $out"
  assert_contains "$out" "diff base: origin/feature" "remote-backed review did not fetch and use origin/<base>"
  assert_contains "$out" "task.txt" "remote-backed review diff missing the task's change"
  pass "fm-review-diff fetches and diffs against origin/<base> for remote-backed projects"
}

test_review_diff_without_base_keeps_default_branch() {
  local rec case_dir default out
  rec=$(make_base_project_case review-default)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  write_task_meta "$case_dir" local-only ""

  out=$(run_with_state "$case_dir" "$REVIEW" task-x1 --stat 2>&1) || fail "review-diff without base= failed: $out"
  assert_contains "$out" "diff base: $default" "review without base= did not use the default branch"
  pass "fm-review-diff without base= keeps the default-branch comparison"
}

# --- fm-merge-local ------------------------------------------------------------

test_merge_local_fast_forwards_base_branch() {
  local rec case_dir default out wt_head feature_head default_before default_after
  rec=$(make_base_project_case merge-ff)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  write_task_meta "$case_dir" local-only feature
  default_before=$(git -C "$case_dir/project" rev-parse "$default")

  out=$(run_with_state "$case_dir" "$MERGE" task-x1 2>&1) || fail "merge-local with base= failed: $out"
  assert_contains "$out" "merged fm/task-x1 into local feature" "merge did not report the base branch as target"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  feature_head=$(git -C "$case_dir/project" rev-parse feature)
  [ "$feature_head" = "$wt_head" ] || fail "feature was not fast-forwarded to the task branch head"
  default_after=$(git -C "$case_dir/project" rev-parse "$default")
  [ "$default_after" = "$default_before" ] || fail "default branch moved during a base-branch merge"
  pass "fm-merge-local fast-forwards the recorded base branch and leaves the default branch alone"
}

test_merge_local_refuses_checkout_not_on_base() {
  local rec case_dir default out status
  rec=$(make_base_project_case merge-wrong-checkout)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  write_task_meta "$case_dir" local-only feature
  git -C "$case_dir/project" checkout -q "$default"

  set +e
  out=$(run_with_state "$case_dir" "$MERGE" task-x1 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "merge should refuse when the checkout is not on the base branch"
  assert_contains "$out" "expected base branch 'feature'" "refusal did not name the base branch"
  pass "fm-merge-local refuses when the project checkout is not on the base branch"
}

test_merge_local_refuses_diverged_base() {
  local rec case_dir default out status
  rec=$(make_base_project_case merge-diverged)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  write_task_meta "$case_dir" local-only feature
  # Advance feature past the task branch's fork point so the merge is no longer
  # a fast-forward.
  printf 'diverged\n' > "$case_dir/project/diverge.txt"
  git -C "$case_dir/project" add diverge.txt
  git -C "$case_dir/project" commit -qm "feature diverges"

  set +e
  out=$(run_with_state "$case_dir" "$MERGE" task-x1 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "merge should refuse a diverged base branch"
  assert_contains "$out" "REFUSED: fm/task-x1 is not a fast-forward of feature" "divergence refusal missing"
  assert_contains "$out" "rebase fm/task-x1 onto feature" "divergence refusal lost the rebase advice"
  pass "fm-merge-local refuses divergence against the base branch with rebase advice"
}

test_merge_local_refuses_missing_base_branch() {
  local rec case_dir default out status
  rec=$(make_base_project_case merge-missing-base)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  write_task_meta "$case_dir" local-only nonexistent-base

  set +e
  out=$(run_with_state "$case_dir" "$MERGE" task-x1 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "merge should refuse a recorded base branch that does not exist"
  assert_contains "$out" "recorded base branch 'nonexistent-base' does not exist" "missing-base refusal missing"
  pass "fm-merge-local refuses a recorded base branch missing from the project"
}

# --- fm-teardown ---------------------------------------------------------------

add_teardown_mocks() {
  local case_dir=$1 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  fm_fake_exit0 "$fakebin" treehouse tmux
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

run_teardown() {
  local case_dir=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_teardown_accepts_local_only_work_merged_into_base() {
  local rec case_dir default fakebin rc wt_head
  rec=$(make_base_project_case td-base-merged)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  fakebin=$(add_teardown_mocks "$case_dir")
  write_task_meta "$case_dir" local-only feature
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/feature "$wt_head"

  set +e
  run_teardown "$case_dir" "$fakebin" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown should accept local-only work merged into the recorded base branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "td-base-merged: teardown printed a REFUSED line"
  pass "teardown accepts local-only work merged into the recorded base branch"
}

test_teardown_refuses_local_only_work_not_merged_into_base() {
  local rec case_dir default fakebin rc wt_head
  rec=$(make_base_project_case td-base-unmerged)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  fakebin=$(add_teardown_mocks "$case_dir")
  write_task_meta "$case_dir" local-only feature
  # Land the work on the DEFAULT branch only: with base= recorded that is not
  # the landing target, so teardown must still refuse.
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref "refs/heads/$default" "$wt_head"

  set +e
  run_teardown "$case_dir" "$fakebin" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "teardown should refuse local-only work not merged into the recorded base branch"
  grep -q REFUSED "$case_dir/stderr" || fail "td-base-unmerged: no REFUSED line in stderr"
  grep -q "not yet merged into feature" "$case_dir/stderr" \
    || fail "td-base-unmerged: refusal did not name the base branch as the landing target"
  pass "teardown still refuses base-branch work merged only into the default branch"
}

# Land <file>=<content> as a squash-style commit on origin's <branch> via a
# separate clone, so the task branch's own commits stay unreachable.
land_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q "$branch"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" commit -qm "squash $file onto $branch"
  git -C "$tmp" push -q origin "HEAD:$branch"
  rm -rf -- "$tmp"
}

test_teardown_content_fallback_checks_base_not_default() {
  local rec case_dir default fakebin rc
  # Content landed on origin/<base> -> ALLOW; content landed only on
  # origin/<default> -> REFUSE. Both with base= recorded and no PR anywhere.
  rec=$(make_base_project_case td-content-base)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  fakebin=$(add_teardown_mocks "$case_dir")
  fm_git_add_origin "$case_dir/project" "$case_dir/origin.git"
  git -C "$case_dir/project" push -q origin feature "$default"
  write_task_meta "$case_dir" no-mistakes feature
  land_on_origin_branch "$case_dir" feature task.txt "task work"

  set +e
  run_teardown "$case_dir" "$fakebin" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown should accept content already landed on origin/<base>"
  ! grep -q REFUSED "$case_dir/stderr" || fail "td-content-base: teardown printed a REFUSED line"

  rec=$(make_base_project_case td-content-default-only)
  IFS='|' read -r case_dir default <<EOF
$rec
EOF
  fakebin=$(add_teardown_mocks "$case_dir")
  fm_git_add_origin "$case_dir/project" "$case_dir/origin.git"
  git -C "$case_dir/project" push -q origin feature "$default"
  write_task_meta "$case_dir" no-mistakes feature
  land_on_origin_branch "$case_dir" "$default" task.txt "task work"

  set +e
  run_teardown "$case_dir" "$fakebin" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "teardown should refuse when content landed only on origin/<default> but base= is recorded"
  grep -q REFUSED "$case_dir/stderr" || fail "td-content-default-only: no REFUSED line in stderr"
  pass "teardown's content-landed fallback targets origin/<base>, not origin/<default>, when base= is recorded"
}

test_spawn_records_base_in_meta
test_spawn_without_base_writes_no_base_line
test_spawn_batch_threads_base_to_every_pair
test_spawn_refuses_base_for_scout_and_secondmate
test_brief_base_rewrites_ship_setup
test_brief_without_base_keeps_default_step
test_brief_refuses_base_for_scout_and_secondmate
test_review_diff_uses_recorded_base_locally
test_review_diff_uses_origin_base_when_remote_backed
test_review_diff_without_base_keeps_default_branch
test_merge_local_fast_forwards_base_branch
test_merge_local_refuses_checkout_not_on_base
test_merge_local_refuses_diverged_base
test_merge_local_refuses_missing_base_branch
test_teardown_accepts_local_only_work_merged_into_base
test_teardown_refuses_local_only_work_not_merged_into_base
test_teardown_content_fallback_checks_base_not_default
