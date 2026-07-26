#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's automatic role disclaimer on firstmate-repo scouts.
#
# These tests use a fake firstmate repo and fake tmux/treehouse binaries so they
# pin the delivered brief path without creating a real terminal or task window.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-scout-role)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
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
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

install_fake_firstmate_bins() {
  local root=$1
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-project-mode.sh" <<'SH'
#!/usr/bin/env bash
printf 'direct-PR off\n'
SH
  chmod +x "$root/bin/fm-project-mode.sh"
}

make_case() {
  local name=$1 relation=$2 id=$3 note=${4:-plain}
  local case_dir home fm_root firstmate_project project_repo project agent fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fm_root="$case_dir/firstmate-root"
  firstmate_project="$case_dir/firstmate-project"
  project_repo="$case_dir/other-project"
  project=
  agent=
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"

  case "$relation" in
    firstmate-root)
      fm_git_init_commit "$fm_root"
      agent="$case_dir/agent-wt"
      git -C "$fm_root" worktree add --quiet -b "agent-$name" "$agent"
      project="$fm_root"
      ;;
    firstmate-worktree)
      fm_git_worktree "$fm_root" "$firstmate_project" "project-$name"
      agent="$case_dir/agent-wt"
      git -C "$fm_root" worktree add --quiet -b "agent-$name" "$agent"
      project="$firstmate_project"
      ;;
    other-project)
      fm_git_init_commit "$fm_root"
      fm_git_worktree "$project_repo" "$firstmate_project" "project-$name"
      agent="$case_dir/agent-wt"
      git -C "$project_repo" worktree add --quiet -b "agent-$name" "$agent"
      project="$firstmate_project"
      ;;
    *) fail "unknown relation $relation" ;;
  esac
  install_fake_firstmate_bins "$fm_root"

  if [ "$note" = role-note ]; then
    printf 'ROLE NOTE: existing scout role note.\n\nbrief for %s\n' "$id" > "$home/data/$id/brief.md"
  else
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fi
  printf '%s\n' "$case_dir|$home|$fm_root|$project|$agent|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r _CASE_DIR HOME_DIR FM_ROOT_DIR PROJECT_DIR AGENT_WT FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local id=$1 kind=${2:-scout}
  : > "$LAUNCH_LOG"
  if [ "$kind" = scout ]; then
    FM_ROOT_OVERRIDE="$FM_ROOT_DIR" FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$AGENT_WT" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJECT_DIR" --scout --harness claude 2>&1
  else
    FM_ROOT_OVERRIDE="$FM_ROOT_DIR" FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$AGENT_WT" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJECT_DIR" --harness claude 2>&1
  fi
}

last_typed_launch() {
  tail -n 1 "$LAUNCH_LOG"
}

test_firstmate_root_scout_gets_generated_role_brief() {
  local rec id out status generated launch
  id=scout-role-root-z1
  rec=$(make_case firstmate-root firstmate-root "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" scout)
  status=$?
  expect_code 0 "$status" "firstmate-root scout spawn should succeed"
  generated="$HOME_DIR/data/$id/brief.with-scout-role-note.md"
  assert_present "$generated" "firstmate-root scout should get a generated delivered brief"
  assert_grep "ROLE NOTE: You are a scout, not the firstmate supervisor." "$generated" \
    "generated brief is missing the scout role note"
  assert_grep "Do not run bin/fm-session-start.sh, arm watchers, or touch state/." "$generated" \
    "generated brief is missing the operational refusals"
  assert_grep "brief for $id" "$generated" "generated brief did not preserve the source brief body"
  assert_no_grep "ROLE NOTE:" "$HOME_DIR/data/$id/brief.md" "source brief should not be rewritten"
  launch=$(last_typed_launch)
  assert_contains "$launch" "$generated" "launch did not use the generated role-note brief"
  pass "firstmate-root scout receives the automatic role disclaimer"
}

test_firstmate_worktree_existing_role_note_is_not_duplicated() {
  local rec id out status generated launch
  id=scout-role-existing-z2
  rec=$(make_case firstmate-worktree firstmate-worktree "$id" role-note)
  read_case_record "$rec"

  out=$(run_spawn "$id" scout)
  status=$?
  expect_code 0 "$status" "firstmate-worktree scout with ROLE NOTE should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  generated="$HOME_DIR/data/$id/brief.with-scout-role-note.md"
  assert_absent "$generated" "existing ROLE NOTE should not create a generated duplicate brief"
  launch=$(last_typed_launch)
  assert_contains "$launch" "$HOME_DIR/data/$id/brief.md" "launch should use the source brief with its existing role note"
  pass "existing ROLE NOTE prevents duplicate scout-role injection"
}

test_firstmate_ship_uses_source_brief() {
  local rec id out status generated launch
  id=scout-role-ship-z3
  rec=$(make_case firstmate-ship firstmate-root "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" ship)
  status=$?
  expect_code 0 "$status" "firstmate ship spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  generated="$HOME_DIR/data/$id/brief.with-scout-role-note.md"
  assert_absent "$generated" "non-scout firstmate spawn should not create a generated role brief"
  launch=$(last_typed_launch)
  assert_contains "$launch" "$HOME_DIR/data/$id/brief.md" "non-scout launch should use the source brief"
  pass "non-scout firstmate spawns keep the source brief"
}

test_non_firstmate_scout_uses_source_brief() {
  local rec id out status generated launch
  id=scout-role-other-z4
  rec=$(make_case other-project other-project "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" scout)
  status=$?
  expect_code 0 "$status" "non-firstmate scout spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  generated="$HOME_DIR/data/$id/brief.with-scout-role-note.md"
  assert_absent "$generated" "non-firstmate scout should not create a generated role brief"
  launch=$(last_typed_launch)
  assert_contains "$launch" "$HOME_DIR/data/$id/brief.md" "non-firstmate scout launch should use the source brief"
  pass "non-firstmate scout spawns keep the source brief"
}

test_firstmate_root_scout_gets_generated_role_brief
test_firstmate_worktree_existing_role_note_is_not_duplicated
test_firstmate_ship_uses_source_brief
test_non_firstmate_scout_uses_source_brief

echo "# all fm-spawn-scout-role tests passed"
