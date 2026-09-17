#!/usr/bin/env bash
# Behavioral coverage for the workspace release that bin/fm-pr-check.sh runs
# after a PR is registered: a refused release must never undo or skip the
# registration, a safe one reclaims the local workspace, an interrupted one is
# retried idempotently, and a legacy record keeps its until-merge workspace.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-workspace)
ID=task-x1
URL=https://github.com/example/repo/pull/7

# make_case <name> [legacy]: a secondmate home (remote parent route) holding one
# task whose real worktree is pushed to a real origin as the PR's head.
make_case() {
  local name=$1 legacy=${2:-} d home project origin wt fake head
  d="$TMP_ROOT/$name"
  home="$d/home"
  project="$d/project"
  origin="$d/origin.git"
  wt="$d/scoped/home-a/repo-pool/1/repo"
  fake="$d/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fake" "$d/root/bin" "$(dirname "$wt")"
  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$project" 2>/dev/null
  git -C "$project" commit -q --allow-empty -m base
  git -C "$project" push -q origin main
  git -C "$project" remote set-head origin main
  git -C "$project" worktree add -q -b "fm/$ID" "$wt" main
  printf 'feature\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" commit -q -m feature
  head=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push -q origin "HEAD:refs/heads/fm/$ID"
  git -C "$wt" push -q origin HEAD:refs/pull/7/head
  printf '{}\n' > "$d/scoped/home-a/repo-pool/treehouse-state.json"

  cat > "$d/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # One gh for both callers: fm-pr-check.sh asks for the bare head commit, and
  # fm-workspace.sh asks for the preservation row.
  cat > "$fake/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" state,headRefOid,headRefName,baseRefName,url "*)
    printf '%s\t%s\t%s\t%s\t%s\n' OPEN '$head' 'fm/$ID' 'main' '$URL'
    ;;
  *" headRefOid "*) cat "$fake/current-head" 2>/dev/null || printf '%s\n' '$head' ;;
esac
SH
  cat > "$fake/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --root ]; then shift 2; fi
case "${1:-}" in
  return)
    target=${@: -1}
    git -C "$target" checkout -q --detach main
    git -C "$target" reset -q --hard main
    git -C "$target" clean -q -fdx
    ;;
  destroy)
    target=$2
    if [ -n "${FM_TEST_DESTROY_FAIL_ONCE:-}" ] && [ ! -e "$FM_TEST_DESTROY_FAIL_ONCE" ]; then
      : > "$FM_TEST_DESTROY_FAIL_ONCE"
      exit 1
    fi
    [ ! -e "$target" ] || git -C "$FM_TEST_PROJECT" worktree remove --force "$target"
    ;;
esac
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '@pane\n' ;;
esac
exit 0
SH
  chmod +x "$d/root/bin/fm-guard.sh" "$fake/gh" "$fake/treehouse" "$fake/tmux"

  printf '%s\n' mate-x > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$home/.fm-secondmate-parent"

  {
    printf 'window=firstmate:fm-%s\n' "$ID"
    printf 'endpoint_task_id=%s\n' "$ID"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$project"
    printf 'harness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'spawn_gen=test-generation\n'
    [ "$legacy" = legacy ] \
      || printf 'workspace_state=active\nworkspace_root=%s\n' "$d/scoped/home-a"
  } > "$home/state/$ID.meta"
  chmod 0600 "$home/state/$ID.meta"
  printf '%s|%s|%s|%s|%s|%s\n' "$d" "$home" "$project" "$wt" "$fake" "$head"
}

read_case() { IFS='|' read -r D HOME_DIR PROJECT WT FAKEBIN HEAD <<EOF
$1
EOF
  META="$HOME_DIR/state/$ID.meta"
}

# Runs the real script; sets OUT (stdout+stderr) and RC.
run_pr_check() {
  RC=0
  OUT=$(FM_ROOT_OVERRIDE="$D/root" FM_HOME="$HOME_DIR" \
    FM_WORKSPACE_ROOT_BASE="$D/scoped-base" FM_TEST_PROJECT="$PROJECT" \
    PATH="$FAKEBIN:$PATH" "$PR_CHECK" "$ID" "$URL" 2>&1) || RC=$?
}

assert_registered() {  # <label>
  local label=$1
  assert_grep "pr=$URL" "$META" "$label: pr= was not recorded"
  assert_grep "pr_head=$HEAD" "$META" "$label: the forge head was not recorded"
  [ -f "$HOME_DIR/state/$ID.check.sh" ] || fail "$label: the PR poll was not published"
  assert_contains "$OUT" "armed: state/$ID.check.sh" "$label: the armed line was not printed"
  assert_grep "done [key=child-pr-$ID]: child $ID PR ready: $URL" \
    "$HOME_DIR/state/parent-replies.status" "$label: the ready line did not reach the parent channel"
}

test_refused_release_keeps_the_registration() {
  local rec
  rec=$(make_case refused)
  read_case "$rec"
  printf 'secret=keep\n' > "$WT/.env"
  run_pr_check
  [ "$RC" -ne 0 ] || fail "a refused workspace release exited zero: $OUT"
  assert_registered refused
  assert_contains "$OUT" "dirty or untracked" "the preservation refusal was not reported"
  assert_contains "$OUT" "PR $URL is registered and armed, but its local workspace could not be safely released" \
    "the refusal did not say the registration stands"
  [ -d "$WT" ] || fail "a refused release removed the worktree"
  [ -f "$WT/.env" ] || fail "a refused release removed the untracked file"
  assert_grep 'workspace_state=active' "$META" "a refused release rewrote lifecycle state"
  pass "a refused workspace release fails fm-pr-check only after the PR is recorded, polled, armed, and reported upward"
}

test_clean_preserved_workspace_is_released() {
  local rec
  rec=$(make_case clean)
  read_case "$rec"
  run_pr_check
  [ "$RC" -eq 0 ] || fail "a clean remotely preserved registration failed ($RC): $OUT"
  assert_registered clean
  [ ! -d "$WT" ] || fail "the released worktree still exists"
  assert_grep 'workspace_state=released' "$META" "release state was not durable"
  assert_no_grep 'workspace_state=active' "$META" "the active lifecycle line survived release"
  bash -c '. "$1"; fm_pr_metadata_identity_parse "$2"' _ "$ROOT/bin/fm-pr-lib.sh" "$META" \
    || fail "release left a task record the PR merge monitor can no longer validate"
  pass "a clean remotely preserved workspace is released as soon as its PR is registered"
}

test_rerun_on_a_released_record_keeps_pr_head_current() {
  local rec moved=0123456789abcdef0123456789abcdef01234567
  rec=$(make_case released-rerun)
  read_case "$rec"
  run_pr_check
  [ "$RC" -eq 0 ] || fail "the releasing registration failed ($RC): $OUT"
  assert_grep 'workspace_state=released' "$META" "fixture error: the first run should release"
  [ -z "$(sed -n 's/^worktree=//p' "$META")" ] || fail "fixture error: a released record names no worktree"
  assert_grep "pr_head=$HEAD" "$META" "the first run did not record the forge head"

  run_pr_check
  [ "$RC" -eq 0 ] || fail "rerunning on a released record failed ($RC): $OUT"
  assert_grep "pr_head=$HEAD" "$META" "a rerun on a released record dropped pr_head"

  printf '%s\n' "$moved" > "$FAKEBIN/current-head"
  run_pr_check
  [ "$RC" -eq 0 ] || fail "rerunning after the PR head moved failed ($RC): $OUT"
  assert_grep "pr_head=$moved" "$META" "a rerun on a released record did not record the forge's current head"
  assert_no_grep "pr_head=$HEAD" "$META" "a stale pr_head survived the rerun"
  assert_grep 'workspace_state=released' "$META" "a rerun disturbed the released lifecycle state"
  pass "rerunning fm-pr-check on a released record records the forge's current head instead of dropping it"
}

test_interrupted_release_is_retried_by_rerunning() {
  local rec
  rec=$(make_case retry)
  read_case "$rec"
  export FM_TEST_DESTROY_FAIL_ONCE="$D/destroy-failed-once"
  run_pr_check
  unset FM_TEST_DESTROY_FAIL_ONCE
  [ "$RC" -ne 0 ] || fail "a failed exact cleanup exited zero: $OUT"
  assert_registered retry-first-run
  assert_grep 'workspace_state=reclaim-pending' "$META" "the failed cleanup did not retain its retry state"
  [ -d "$WT" ] || fail "the failed cleanup lost the idle worktree"

  run_pr_check
  [ "$RC" -eq 0 ] || fail "rerunning fm-pr-check did not reclaim the workspace ($RC): $OUT"
  assert_registered retry-second-run
  [ ! -d "$WT" ] || fail "the retry left the idle worktree behind"
  assert_grep 'workspace_state=released' "$META" "the retry did not publish completion"
  [ "$(grep -Fxc "done [key=child-pr-$ID]: child $ID PR ready: $URL mode=no-mistakes yolo=off" \
    "$HOME_DIR/state/parent-replies.status")" = 1 ] || fail "the retry duplicated the parent ready line"
  pass "rerunning fm-pr-check reclaims a reclaim-pending workspace idempotently"
}

test_legacy_record_keeps_its_workspace() {
  local rec
  rec=$(make_case legacy legacy)
  read_case "$rec"
  printf 'scratch\n' > "$WT/untracked.txt"
  run_pr_check
  [ "$RC" -eq 0 ] || fail "a legacy registration failed ($RC): $OUT"
  assert_registered legacy
  [ -d "$WT" ] || fail "a legacy record's worktree was removed"
  [ -f "$WT/untracked.txt" ] || fail "a legacy record's worktree was cleaned"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD" ] || fail "a legacy record's worktree HEAD moved"
  [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "fm/$ID" ] || fail "a legacy record's branch was detached"
  assert_no_grep 'workspace_state=' "$META" "a legacy record gained a lifecycle state"
  pass "a legacy record without workspace_state registers its PR and keeps its workspace untouched"
}

test_refused_release_keeps_the_registration
test_clean_preserved_workspace_is_released
test_rerun_on_a_released_record_keeps_pr_head_current
test_interrupted_release_is_retried_by_rerunning
test_legacy_record_keeps_its_workspace
printf '# all fm-pr-check-workspace tests passed\n'
