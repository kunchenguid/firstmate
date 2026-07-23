#!/usr/bin/env bash
# Behavior tests for safe same-worktree quota-wall rehome.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REHOME="$ROOT/bin/fm-rehome-quota-wall.sh"
TMP_ROOT=$(fm_test_tmproot fm-rehome-quota-wall)

make_rehome_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:-/dev/null}
printf '%s\n' "$*" >> "$log"

if [ "${1:-}" = display-message ]; then
  case "$*" in
    *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_OLD_COMMAND:-zsh}"; exit 0 ;;
    *"#{pane_id}"*)
      printf '%%pane\n'
      exit 0
      ;;
    *"#S"*) printf 'firstmate\n'; exit 0 ;;
  esac
fi

case "${1:-}" in
  has-session|set-window-option) exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_OLD_EXISTS:-}" ] && [ -f "$FM_FAKE_OLD_EXISTS" ]; then
      printf 'other-window\n'
    fi
    exit 0
    ;;
  new-window)
    printf '@new\n'
    exit 0
    ;;
  kill-window)
    [ -n "${FM_FAKE_OLD_EXISTS:-}" ] && rm -f "$FM_FAKE_OLD_EXISTS"
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 case_dir home proj wt fakebin launchlog tmuxlog oldexists id
  id=${2:-task-x1}
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_rehome_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  tmuxlog="$case_dir/tmux.log"
  oldexists="$case_dir/old-exists"
  mkdir -p "$home/data/$id" "$home/state" "$home/config"
  printf 'original brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$oldexists"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=$case_dir/tasktmp" \
    "model=gpt-5.5" \
    "effort=xhigh" \
    "pr=https://github.com/example/repo/pull/7" \
    "pr_head=$(git -C "$wt" rev-parse HEAD)"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$tmuxlog" "$oldexists"
}

read_case() {
  IFS='|' read -r _ HOME_DIR _ WT_DIR FAKEBIN_DIR LAUNCH_LOG TMUX_LOG OLD_EXISTS <<EOF
$1
EOF
}

run_rehome() {
  local home=$1 fakebin=$2 launchlog=$3 tmuxlog=$4 oldexists=$5
  shift 5
  : > "$launchlog"
  : > "$tmuxlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_TMUX_LOG="$tmuxlog" FM_FAKE_OLD_EXISTS="$oldexists" \
    FM_FAKE_OLD_COMMAND="${FM_FAKE_OLD_COMMAND:-zsh}" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" "$REHOME" "$@" 2>&1
}

test_rehome_reuses_task_identity_and_worktree() {
  local rec out status meta continuation launch meta_count
  rec=$(make_case happy task-x1)
  read_case "$rec"

  out=$(run_rehome "$HOME_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TMUX_LOG" "$OLD_EXISTS" \
    task-x1 --harness claude --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "happy rehome should succeed"
  assert_contains "$out" "rehomed task-x1 from codex to claude" "rehome summary should name old and new harness"
  assert_absent "$OLD_EXISTS" "old endpoint marker should be killed before relaunch"

  meta="$HOME_DIR/state/task-x1.meta"
  assert_grep "worktree=$WT_DIR" "$meta" "rehome must preserve the same worktree"
  assert_grep "pr=https://github.com/example/repo/pull/7" "$meta" "rehome must preserve recorded PR URL"
  assert_grep "harness=claude" "$meta" "meta should record new harness"
  assert_grep "model=sonnet" "$meta" "meta should record new model"
  assert_grep "effort=high" "$meta" "meta should record new effort"
  [ "$(grep -c '^window=' "$meta")" = 1 ] || fail "rehome should rewrite meta to one window= owner"
  meta_count=$(find "$HOME_DIR/state" -maxdepth 1 -name 'task-x1*.meta' -print | wc -l | tr -d ' ')
  [ "$meta_count" = 1 ] || fail "rehome should not create duplicate task meta records"

  continuation=$(sed -n 's/^rehome_continuation=//p' "$meta" | tail -1)
  assert_present "$continuation" "rehome should write a continuation brief"
  assert_grep "This is the same firstmate task" "$continuation" "continuation should preserve task identity"
  assert_grep "Recorded PR: https://github.com/example/repo/pull/7" "$continuation" "continuation should carry PR identity"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "rehome launch should use the requested harness profile"
  pass "rehome preserves task/PR identity while relaunching the same worktree"
}

test_dirty_worktree_refuses_without_override() {
  local rec out status
  rec=$(make_case dirty task-dirty)
  read_case "$rec"
  printf '%s\n' dirty > "$WT_DIR/dirty.txt"

  set +e
  out=$(run_rehome "$HOME_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TMUX_LOG" "$OLD_EXISTS" \
    task-dirty --harness claude)
  status=$?
  set -e

  expect_code 1 "$status" "dirty worktree should refuse"
  assert_contains "$out" "REFUSED: worktree" "dirty refusal should be explicit"
  assert_present "$OLD_EXISTS" "dirty refusal must not kill the old endpoint"
  pass "rehome refuses dirty uncommitted work unless explicitly overridden"
}

test_dispatch_profile_requires_approval_flag() {
  local rec out status
  rec=$(make_case dispatch task-dispatch)
  read_case "$rec"
  printf '{"rules":[{"when":"reviews","use":{"harness":"claude"}}]}\n' > "$HOME_DIR/config/crew-dispatch.json"

  set +e
  out=$(run_rehome "$HOME_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TMUX_LOG" "$OLD_EXISTS" \
    task-dispatch --harness claude)
  status=$?
  set -e

  expect_code 1 "$status" "active dispatch profile should require explicit approval"
  assert_contains "$out" "consult it first" "dispatch-profile refusal should explain the backstop"
  assert_present "$OLD_EXISTS" "dispatch-profile refusal must not kill the old endpoint"
  pass "rehome refuses to bypass active crew-dispatch rules"
}

test_opposite_harness_constraint_refuses_same_harness() {
  local rec out status
  rec=$(make_case opposite task-opposite)
  read_case "$rec"
  printf '%s\n' 'opposite_harness_must_differ_from=codex' >> "$HOME_DIR/state/task-opposite.meta"

  set +e
  out=$(run_rehome "$HOME_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TMUX_LOG" "$OLD_EXISTS" \
    task-opposite --harness codex)
  status=$?
  set -e

  expect_code 1 "$status" "opposite-harness violation should refuse"
  assert_contains "$out" "violates opposite_harness_must_differ_from=codex" \
    "opposite-harness refusal should cite the constraint"
  assert_present "$OLD_EXISTS" "opposite-harness refusal must not kill the old endpoint"
  pass "rehome preserves adversarial-review opposite-harness constraints"
}

test_alive_old_endpoint_refuses_duplicate_owner() {
  local rec out status
  rec=$(make_case alive task-alive)
  read_case "$rec"

  set +e
  out=$(FM_FAKE_OLD_COMMAND=codex run_rehome "$HOME_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TMUX_LOG" "$OLD_EXISTS" \
    task-alive --harness claude)
  status=$?
  set -e

  expect_code 1 "$status" "alive old endpoint should refuse duplicate ownership"
  assert_contains "$out" "old endpoint still reports agent_alive=alive" \
    "alive refusal should cite duplicate ownership"
  assert_present "$OLD_EXISTS" "alive refusal must not kill the old endpoint"
  pass "rehome refuses to duplicate ownership when the old agent is still alive"
}

test_rehome_reuses_task_identity_and_worktree
test_dirty_worktree_refuses_without_override
test_dispatch_profile_requires_approval_flag
test_opposite_harness_constraint_refuses_same_harness
test_alive_old_endpoint_refuses_duplicate_owner

echo "# all fm-rehome-quota-wall tests passed"
