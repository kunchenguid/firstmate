#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's backlog transition after metadata is durable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-backlog)

command -v tasks-axi >/dev/null 2>&1 || {
  echo "skip: tasks-axi not found (required for fm-spawn backlog transition tests)"
  exit 0
}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) : ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  wt="$case_dir/worktree"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$project|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

add_queued_row() {  # <home> <id> <repo>
  local home=$1 id=$2 repo=$3
  (cd "$home" && tasks-axi add "$id" "backlog transition regression" --kind ship --repo "$repo" --file "$home/data/backlog.md")
}

test_existing_row_moves_to_in_flight() {
  local rec id out status
  id=spawn-start-a1
  rec=$(make_case existing-row "$id")
  read_case "$rec"
  add_queued_row "$HOME_DIR" "$id" "$(basename "$PROJECT_DIR")"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "spawn with a queued backlog row should succeed"
  (cd "$HOME_DIR" && tasks-axi list --state in_flight --file "$HOME_DIR/data/backlog.md") | grep -F "$id" >/dev/null \
    || fail "spawn did not move the queued row to In flight"
  assert_not_contains "$out" "BACKLOG" "successful backlog start should not show a backlog warning"
  pass "ship spawn moves its queued backlog row to In flight"
}

test_missing_scout_row_warns_but_launch_succeeds() {
  local rec id out status repair
  id=spawn-missing-b2
  rec=$(make_case missing-row "$id")
  read_case "$rec"
  printf '%s\n' '# Backlog' '' '## Queued' '' '## In flight' '' '## Done' > "$HOME_DIR/data/backlog.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 0 "$status" "missing backlog row must not fail a launch"
  assert_present "$HOME_DIR/state/$id.meta" "missing-row launch did not preserve runtime metadata"
  assert_contains "$out" "BACKLOG ROW MISSING - $id WAS DISPATCHED WITHOUT A BACKLOG ITEM" \
    "missing-row launch did not show the high-visibility warning"
  repair="tasks-axi add '$id' '<task title>' --kind 'scout' --repo '$(basename "$PROJECT_DIR")' --start --file '$HOME_DIR/data/backlog.md'"
  assert_contains "$out" "$repair" "missing-row warning did not provide the exact repair command"
  pass "missing backlog row is loud and does not interrupt the launch"
}

test_backlog_write_failure_warns_but_launch_succeeds() {
  local rec id out status
  id=spawn-write-fails-c3
  rec=$(make_case write-failure "$id")
  read_case "$rec"
  add_queued_row "$HOME_DIR" "$id" "$(basename "$PROJECT_DIR")"
  cat > "$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'tasks-axi 0.2.2' ;;
  update) printf '%s\n' '--archive-body' ;;
  mv) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
  start) printf '%s\n' 'simulated write failure' >&2; exit 73 ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "backlog write failure must not fail a launch"
  assert_present "$HOME_DIR/state/$id.meta" "write-failure launch did not preserve runtime metadata"
  assert_contains "$out" "simulated write failure" "write failure was not surfaced"
  assert_contains "$out" "BACKLOG START FAILED - $id IS STILL NOT MARKED IN FLIGHT" \
    "write failure did not show the high-visibility warning"
  pass "backlog write failure is loud and does not interrupt the launch"
}

test_secondmate_spawn_never_touches_backlog() {
  local rec id secondmate out status calls
  id=spawn-secondmate-d4
  rec=$(make_case secondmate "$id")
  read_case "$rec"
  secondmate="$CASE_DIR/secondmate-home"
  mkdir -p "$secondmate/bin" "$secondmate/data"
  printf '# Firstmate\n' > "$secondmate/AGENTS.md"
  printf '%s\n' "$id" > "$secondmate/.fm-secondmate-home"
  printf 'charter\n' > "$secondmate/data/charter.md"
  calls="$CASE_DIR/tasks-axi.calls"
  cat > "$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TASKS_AXI_CALLS"
exit 99
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"

  out=$(FM_TASKS_AXI_CALLS="$calls" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$secondmate" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should not depend on the backlog backend"
  assert_present "$HOME_DIR/state/$id.meta" "secondmate spawn did not write runtime metadata"
  assert_absent "$calls" "secondmate spawn invoked tasks-axi"
  assert_not_contains "$out" "BACKLOG" "secondmate spawn emitted a backlog warning"
  pass "secondmate spawn does not touch the backlog"
}

test_existing_row_moves_to_in_flight
test_missing_scout_row_warns_but_launch_succeeds
test_backlog_write_failure_warns_but_launch_succeeds
test_secondmate_spawn_never_touches_backlog

echo "# all fm-spawn-backlog tests passed"
