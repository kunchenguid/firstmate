#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-target-lib.sh.
#
# fm_merge_target_branch is the shared landing-branch resolver used by
# bin/fm-merge-local.sh and bin/fm-teardown.sh. It must honour FM_MERGE_TARGET_BRANCH
# when set (and refuse a non-existent override), otherwise follow origin/HEAD,
# then fall back to a local main/master.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-merge-target-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-target-lib)
fm_git_identity fmtest fmtest@example.invalid

# Fresh git repo on `main` with one commit and origin/HEAD -> main. Echoes path.
make_repo_with_origin_head() {
  local dir=$1 bare=$2
  git init -q --bare "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone -q "$bare" "$dir"
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$dir" push -q origin main
  git -C "$dir" remote set-head origin main 2>/dev/null || true
  printf '%s\n' "$dir"
}

test_origin_head_default() {
  local repo out
  repo=$(make_repo_with_origin_head "$TMP_ROOT/origin-head" "$TMP_ROOT/origin-head.git")
  unset FM_MERGE_TARGET_BRANCH || true
  out=$(fm_merge_target_branch "$repo") || fail "origin/HEAD resolution returned non-zero"
  [ "$out" = main ] || fail "expected main from origin/HEAD, got '$out'"
  pass "fm_merge_target_branch: origin/HEAD default resolves to main"
}

test_main_master_fallback_without_origin_head() {
  local repo out
  repo="$TMP_ROOT/no-origin-head"
  git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  # No origin remote at all - fall back to local main.
  unset FM_MERGE_TARGET_BRANCH || true
  out=$(fm_merge_target_branch "$repo") || fail "local main fallback returned non-zero"
  [ "$out" = main ] || fail "expected main fallback, got '$out'"
  pass "fm_merge_target_branch: falls back to local main without origin/HEAD"
}

test_override_uses_existing_branch() {
  local repo out
  repo=$(make_repo_with_origin_head "$TMP_ROOT/override-ok" "$TMP_ROOT/override-ok.git")
  git -C "$repo" checkout -q -B feat/gitea-pr-adapter
  # origin/HEAD still points at main; override must win.
  out=$(FM_MERGE_TARGET_BRANCH=feat/gitea-pr-adapter fm_merge_target_branch "$repo") \
    || fail "override of an existing branch returned non-zero"
  [ "$out" = feat/gitea-pr-adapter ] || fail "expected override branch, got '$out'"
  pass "fm_merge_target_branch: FM_MERGE_TARGET_BRANCH overrides origin/HEAD"
}

test_override_missing_branch_refuses() {
  local repo rc
  repo=$(make_repo_with_origin_head "$TMP_ROOT/override-missing" "$TMP_ROOT/override-missing.git")
  set +e
  FM_MERGE_TARGET_BRANCH=does-not-exist fm_merge_target_branch "$repo" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing override branch must refuse"
  pass "fm_merge_target_branch: missing FM_MERGE_TARGET_BRANCH refuses"
}

test_merge_local_honours_override() {
  local case_dir id=merge-ov project wt state out rc before after
  case_dir="$TMP_ROOT/merge-local-override"
  project="$case_dir/project"
  wt="$case_dir/wt"
  state="$case_dir/state"
  mkdir -p "$state" "$case_dir/fakebin"

  # Project lives on a long-lived fork branch while origin/HEAD stays on main.
  make_repo_with_origin_head "$project" "$case_dir/origin.git" >/dev/null
  git -C "$project" checkout -q -B feat/gitea-pr-adapter
  git -C "$project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fork baseline"
  git -C "$project" worktree add -q -b "fm/$id" "$wt" feat/gitea-pr-adapter
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "crew work"

  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" \
    "worktree=$wt" \
    "project=$project" \
    "kind=ship" \
    "mode=local-only"
  touch "$state/.last-watcher-beat"

  # Without the override, merge must refuse (project is not on main).
  set +e
  FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-merge-local.sh" "$id" >"$case_dir/stdout-no" 2>"$case_dir/stderr-no"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge-local without override should refuse a non-default checkout"
  grep -q "expected default branch 'main'" "$case_dir/stderr-no" \
    || fail "merge-local without override did not name main: $(cat "$case_dir/stderr-no")"

  before=$(git -C "$project" rev-parse feat/gitea-pr-adapter)
  set +e
  FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_MERGE_TARGET_BRANCH=feat/gitea-pr-adapter \
    "$ROOT/bin/fm-merge-local.sh" "$id" >"$case_dir/stdout-yes" 2>"$case_dir/stderr-yes"
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-local with override should succeed"$'\n'"$(cat "$case_dir/stderr-yes")"
  after=$(git -C "$project" rev-parse feat/gitea-pr-adapter)
  [ "$before" != "$after" ] || fail "merge-local override did not advance the fork branch"
  git -C "$project" merge-base --is-ancestor "fm/$id" feat/gitea-pr-adapter \
    || fail "crew branch is not an ancestor of the landing branch after merge"
  pass "fm-merge-local.sh: FM_MERGE_TARGET_BRANCH lands on a non-default working branch"
}

test_teardown_honours_override() {
  local case_dir id=task-x1 project wt state fakebin rc
  case_dir="$TMP_ROOT/teardown-override"
  project="$case_dir/project"
  wt="$case_dir/wt"
  state="$case_dir/state"
  fakebin="$case_dir/fakebin"
  mkdir -p "$state" "$fakebin"

  make_repo_with_origin_head "$project" "$case_dir/origin.git" >/dev/null
  git -C "$project" checkout -q -B feat/gitea-pr-adapter
  git -C "$project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fork baseline"
  git -C "$project" worktree add -q -b "fm/$id" "$wt" feat/gitea-pr-adapter
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "crew work"

  # Land the crew commit on the fork branch only (not main).
  git -C "$project" update-ref refs/heads/feat/gitea-pr-adapter "$(git -C "$wt" rev-parse HEAD)"

  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" \
    "worktree=$wt" \
    "project=$project" \
    "kind=ship" \
    "mode=local-only"
  touch "$state/.last-watcher-beat"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
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
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  # Without override: commits are on feat/*, not main -> REFUSE.
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-teardown.sh" "$id" >"$case_dir/stdout-no" 2>"$case_dir/stderr-no"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown without override should refuse work only on the fork branch"
  grep -q REFUSED "$case_dir/stderr-no" || fail "teardown without override printed no REFUSED line"

  # With override pointing at the fork branch the work landed on -> ALLOW.
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_MERGE_TARGET_BRANCH=feat/gitea-pr-adapter \
    "$ROOT/bin/fm-teardown.sh" "$id" >"$case_dir/stdout-yes" 2>"$case_dir/stderr-yes"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown with override should succeed"$'\n'"$(cat "$case_dir/stderr-yes")"
  ! grep -q REFUSED "$case_dir/stderr-yes" || fail "teardown with override printed a REFUSED line"
  [ ! -f "$state/$id.meta" ] || fail "successful teardown did not remove meta"
  pass "fm-teardown.sh: FM_MERGE_TARGET_BRANCH treats the fork branch as landed"
}

test_origin_head_default
test_main_master_fallback_without_origin_head
test_override_uses_existing_branch
test_override_missing_branch_refuses
test_merge_local_honours_override
test_teardown_honours_override
