#!/usr/bin/env bash
# Behavior tests for bin/fm-resume-worktree.sh (data/fleet-constitution.md
# item 21): resuming a task in an EXISTING worktree after its runtime
# session-provider endpoint (the tmux window) is gone, without provisioning a
# fresh worktree via `treehouse get`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

RESUME="$ROOT/bin/fm-resume-worktree.sh"
TMP_ROOT=$(fm_test_tmproot fm-resume-worktree)

# make_resume_fakebin <dir> [dead|alive]
# Fake tmux that answers the target_exists probe (`display-message -p -t
# <target> '#{pane_id}'`) as dead (exit 1, the default - simulating the
# post-restart case this script exists for) or alive (exit 0, for the
# already-alive refusal test). Logs every send-keys call.
make_resume_fakebin() {
  local dir=$1 liveness=${2:-dead} fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_id}"*) [ "$liveness" = alive ] && { printf '%0\n'; exit 0; } || exit 1 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "\${FM_FAKE_SEND_LOG:-}" ]; then
      { printf -- '--- send-keys ---\n'; for a in "\$@"; do printf '%s\n' "\$a"; done; } >> "\$FM_FAKE_SEND_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# make_resume_case <name> -> "<case_dir>|<state>|<data>|<proj>|<wt>|<fakebin>"
# Sets up a real (non-treehouse) git worktree and a hand-written meta/brief,
# exactly what an already-provisioned task looks like on disk.
make_resume_case() {
  local name=$1 liveness=${2:-dead} case_dir state data proj wt fb id old_window
  case_dir="$TMP_ROOT/$name"
  state="$case_dir/state"; data="$case_dir/data"
  proj="$case_dir/project"; wt="$case_dir/wt"
  id="resume-$name"
  mkdir -p "$state" "$data/$id"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_resume_fakebin "$case_dir/fake" "$liveness")
  printf 'test brief content\n' > "$data/$id/brief.md"
  old_window="firstmate:fm-$id"
  cat > "$state/$id.meta" <<EOF
window=$old_window
worktree=$wt
project=$proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$case_dir/tasktmp
model=claude-sonnet-5
effort=default
tier=default
EOF
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$case_dir" "$state" "$data" "$proj" "$wt" "$fb" "$id" "$old_window"
}

read_resume_case() {
  IFS='|' read -r CASE_DIR STATE_DIR DATA_DIR PROJ_DIR WT_DIR FAKEBIN_DIR ID OLD_WINDOW <<EOF
$1
EOF
}

run_resume() {
  local sendlog="$CASE_DIR/send.log"
  : > "$sendlog"
  env FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
    TMUX="fake,1,0" FM_FAKE_SEND_LOG="$sendlog" PATH="$FAKEBIN_DIR:$PATH" \
    HTTP_PROXY= http_proxy= HTTPS_PROXY= https_proxy= ALL_PROXY= all_proxy= NO_PROXY= no_proxy= \
    "$RESUME" "$@" 2>&1
}

test_resumes_into_existing_worktree_with_no_treehouse_call() {
  local rec out status sendlog meta
  rec=$(make_resume_case basic dead)
  read_resume_case "$rec"

  out=$(run_resume "$ID")
  status=$?
  expect_code 0 "$status" "resume should succeed for a dead-endpoint task"$'\n'"$out"
  assert_contains "$out" "resumed $ID harness=claude kind=ship window=firstmate:fm-$ID worktree=$WT_DIR" \
    "resume did not report the expected summary line"

  sendlog="$CASE_DIR/send.log"
  # The launch must carry the recorded model (claude-sonnet-5) and point at
  # the EXISTING worktree's brief, never having sent 'treehouse get'.
  assert_not_contains "$(cat "$sendlog")" "treehouse get" "resume must never send treehouse get"
  assert_contains "$(cat "$sendlog")" "--model 'claude-sonnet-5'" "resume launch missing the recorded model"
  assert_contains "$(cat "$sendlog")" "\$(cat '$DATA_DIR/$ID/brief.md')" "resume launch missing the brief path"

  meta="$STATE_DIR/$ID.meta"
  assert_grep "worktree=$WT_DIR" "$meta" "resume must not change worktree= in meta"
  assert_grep "harness=claude" "$meta" "resume must not change harness= in meta"
  assert_grep "model=claude-sonnet-5" "$meta" "resume must not change model= in meta"
  pass "resume launches directly in the existing worktree, never calling treehouse, preserving the recorded model/harness"
}

test_refuses_when_endpoint_still_alive() {
  local rec out status
  rec=$(make_resume_case alive-endpoint alive)
  read_resume_case "$rec"

  out=$(run_resume "$ID")
  status=$?
  expect_code 1 "$status" "resume should refuse when the recorded window is still alive"
  assert_contains "$out" "still alive; nothing to resume" "refusal did not explain the still-alive endpoint"
  pass "resume refuses to double-provision a task whose endpoint is still alive"
}

test_refuses_missing_worktree() {
  local rec out status
  rec=$(make_resume_case missing-wt dead)
  read_resume_case "$rec"
  rm -rf "$WT_DIR"

  out=$(run_resume "$ID")
  status=$?
  expect_code 1 "$status" "resume should refuse when the worktree is gone"
  assert_contains "$out" "no longer exists on disk" "refusal did not explain the missing worktree"
  pass "resume refuses when the recorded worktree no longer exists on disk"
}

test_refuses_secondmate_kind() {
  local rec out status
  rec=$(make_resume_case secondmate-kind dead)
  read_resume_case "$rec"
  sed -i.bak 's/^kind=ship/kind=secondmate/' "$STATE_DIR/$ID.meta"
  rm -f "$STATE_DIR/$ID.meta.bak"

  out=$(run_resume "$ID")
  status=$?
  expect_code 1 "$status" "resume should refuse a kind=secondmate task"
  assert_contains "$out" "fm-spawn.sh $ID --secondmate" "refusal did not point at the secondmate recovery path"
  pass "resume refuses kind=secondmate and points at fm-spawn.sh --secondmate instead"
}

test_refuses_unknown_task() {
  local case_dir state data out status
  case_dir="$TMP_ROOT/unknown"
  state="$case_dir/state"; data="$case_dir/data"
  mkdir -p "$state" "$data"
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$RESUME" no-such-task 2>&1)
  status=$?
  expect_code 1 "$status" "resume should refuse an unknown task id"
  assert_contains "$out" "nothing to resume" "refusal did not explain the missing meta"
  pass "resume refuses a task id with no recorded meta"
}

test_resumes_into_existing_worktree_with_no_treehouse_call
test_refuses_when_endpoint_still_alive
test_refuses_missing_worktree
test_refuses_secondmate_kind
test_refuses_unknown_task

echo "# all fm-resume-worktree tests passed"
