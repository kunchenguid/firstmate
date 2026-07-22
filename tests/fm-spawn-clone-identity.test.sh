#!/usr/bin/env bash
# Regression coverage for fm-spawn's selected-clone identity boundary and the
# recovery verifier's post-resume live-cwd check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
RECOVERY_VERIFY="$ROOT/bin/fm-recovery-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-clone-identity)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_current_path*) printf '%s\n' "${FM_FAKE_ACTUAL_CWD:-}"; exit 0 ;;
      esac
    done
    printf 'firstmate\n'
    ;;
  list-windows|has-session|set-window-option|kill-window) ;;
  new-session) ;;
  new-window) printf '@71\n' ;;
  send-keys)
    for arg in "$@"; do
      case "$arg" in
        *claude*) : > "${FM_FAKE_AGENT_MARKER:?}" ;;
      esac
    done
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_fixture() {
  local seed remote home_a home_b project_a project_b pool
  seed="$TMP_ROOT/seed"
  remote="$TMP_ROOT/remote.git"
  home_a="$TMP_ROOT/home-a"
  home_b="$TMP_ROOT/home-b"
  project_a="$home_a/projects/shared"
  project_b="$home_b/projects/shared"
  pool="$TMP_ROOT/shared-pool"
  fm_git_init_commit "$seed"
  git clone --quiet --bare "$seed" "$remote"
  mkdir -p "$home_a/projects" "$home_b/projects" "$pool"
  git clone --quiet "file://$remote" "$project_a"
  git clone --quiet "file://$remote" "$project_b"
  git -C "$project_a" worktree add --quiet -b owned-task "$pool/owned-slot"
  git -C "$project_b" worktree add --quiet -b foreign-task "$pool/foreign-slot"
  printf '%s\n' "$home_a|$project_a|$pool/owned-slot|$project_b|$pool/foreign-slot"
}

IFS='|' read -r HOME_A PROJECT_A OWNED_WT PROJECT_B FOREIGN_WT <<EOF
$(make_fixture)
EOF
REMOTE_A=$(git -C "$PROJECT_A" remote get-url origin)
REMOTE_B=$(git -C "$PROJECT_B" remote get-url origin)
[ "$REMOTE_A" = "$REMOTE_B" ] || fail "fixture clones do not share one remote identity"
COMMON_A=$(git -C "$PROJECT_A" rev-parse --path-format=absolute --git-common-dir)
COMMON_B=$(git -C "$PROJECT_B" rev-parse --path-format=absolute --git-common-dir)
[ "$COMMON_A" != "$COMMON_B" ] || fail "fixture clones unexpectedly share one Git common directory"
FAKEBIN=$(make_fakebin "$TMP_ROOT/fake")
mkdir -p "$HOME_A/data" "$HOME_A/state" "$HOME_A/config"
printf 'claude\n' > "$HOME_A/config/crew-harness"
touch "$HOME_A/state/.last-watcher-beat"

run_spawn() {
  local id=$1 pane_path=$2 marker=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_A" \
    FM_STATE_OVERRIDE="$HOME_A/state" FM_DATA_OVERRIDE="$HOME_A/data" \
    FM_PROJECTS_OVERRIDE="$HOME_A/projects" FM_CONFIG_OVERRIDE="$HOME_A/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_ACTUAL_CWD="$pane_path" FM_FAKE_AGENT_MARKER="$marker" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJECT_A" 2>&1
}

test_foreign_pooled_worktree_is_rejected_before_launch_or_meta() {
  local id marker out rc
  id=foreign-clone-reject
  marker="$TMP_ROOT/$id-agent-started"
  mkdir -p "$HOME_A/data/$id"
  printf 'brief\n' > "$HOME_A/data/$id/brief.md"

  out=$(run_spawn "$id" "$FOREIGN_WT" "$marker")
  rc=$?

  [ "$rc" -ne 0 ] || fail "foreign pooled worktree should be rejected"
  assert_contains "$out" "owned by clone" "foreign-clone refusal did not name the ownership mismatch"
  assert_contains "$out" "before hooks, agent launch, or metadata publication" "foreign-clone refusal was not actionable about the safety boundary"
  assert_absent "$marker" "agent launch occurred before foreign-clone rejection"
  assert_absent "$HOME_A/state/$id.meta" "metadata was published before foreign-clone rejection"
  assert_absent "$FOREIGN_WT/.claude/settings.local.json" "worktree hook was installed before foreign-clone rejection"
  assert_absent "/tmp/fm-$id" "task temp state was created before foreign-clone rejection"
  pass "a foreign worktree from the same remote and shared pool namespace is rejected before hooks, launch, or metadata"
}

test_owned_worktree_records_selected_clone_identity() {
  local id marker out rc expected_common
  id=owned-clone-accept
  marker="$TMP_ROOT/$id-agent-started"
  mkdir -p "$HOME_A/data/$id"
  printf 'brief\n' > "$HOME_A/data/$id/brief.md"

  out=$(run_spawn "$id" "$OWNED_WT" "$marker")
  rc=$?

  expect_code 0 "$rc" "owned pooled worktree spawn should succeed: $out"
  expected_common=$(git -C "$PROJECT_A" rev-parse --path-format=absolute --git-common-dir)
  expected_common=$(cd "$expected_common" && pwd -P)
  assert_present "$marker" "owned worktree did not reach agent launch"
  assert_grep "project_git_common_dir=$expected_common" "$HOME_A/state/$id.meta" "task metadata did not record selected clone identity"
  rm -rf "/tmp/fm-$id"
  pass "an owned pooled worktree records the selected clone identity in metadata"
}

write_recovery_meta() {
  local id=$1 common
  common=$(git -C "$PROJECT_A" rev-parse --path-format=absolute --git-common-dir)
  common=$(cd "$common" && pwd -P)
  fm_write_meta "$HOME_A/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$OWNED_WT" \
    "project=$PROJECT_A" \
    "project_git_common_dir=$common" \
    "harness=grok" \
    "kind=ship"
}

run_recovery_verify() {
  local id=$1 actual=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_A" FM_STATE_OVERRIDE="$HOME_A/state" \
    FM_CONFIG_OVERRIDE="$HOME_A/config" TMUX="fake,1,0" \
    FM_FAKE_ACTUAL_CWD="$actual" PATH="$FAKEBIN:$PATH" \
    "$RECOVERY_VERIFY" "$id" 2>&1
}

test_resume_historical_foreign_cwd_is_rejected() {
  local id out rc
  id=resume-foreign-cwd
  write_recovery_meta "$id"

  out=$(run_recovery_verify "$id" "$FOREIGN_WT")
  rc=$?

  [ "$rc" -ne 0 ] || fail "recovery verifier should reject a resumed historical foreign cwd"
  assert_contains "$out" "exit this resumed agent and relaunch fresh" "resume refusal did not provide the safe recovery action"
  assert_contains "$out" "$FOREIGN_WT" "resume refusal did not identify the actual historical cwd"
  pass "recovery refuses a resumed agent whose historical cwd crosses the selected clone boundary"
}

test_resume_recorded_worktree_is_accepted() {
  local id out rc
  id=resume-owned-cwd
  write_recovery_meta "$id"

  out=$(run_recovery_verify "$id" "$OWNED_WT")
  rc=$?

  expect_code 0 "$rc" "recovery verifier should accept the recorded worktree: $out"
  assert_contains "$out" "verified task $id" "successful recovery verification did not report the task"
  pass "recovery accepts a resumed agent only in its recorded worktree and selected clone"
}

test_foreign_pooled_worktree_is_rejected_before_launch_or_meta
test_owned_worktree_records_selected_clone_identity
test_resume_historical_foreign_cwd_is_rejected
test_resume_recorded_worktree_is_accepted

echo "# all fm-spawn-clone-identity tests passed"
