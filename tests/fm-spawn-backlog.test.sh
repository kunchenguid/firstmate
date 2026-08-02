#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's new-task backlog-row gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-backlog)

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
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_LAUNCH_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_TREEHOUSE_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
fi
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WORKTREE:?}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home project worktree fakebin launch_log id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  launch_log="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$home/treehouse-pools"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '# Backlog\n\n## In flight\n' > "$home/data/backlog.md"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  git -C "$worktree" checkout --quiet --detach HEAD
  git -C "$project" branch --quiet -D "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
    printf -- '- [ ] %s - backlog gate test (repo: project)\n' "$id" >> "$home/data/backlog.md"
  done
  printf '\n## Queued\n\n## Done\n' >> "$home/data/backlog.md"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin|$launch_log"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 worktree=$2 fakebin=$3 launch_log=$4
  shift 4
  : > "$launch_log"
  : > "$home/treehouse.log"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TREEHOUSE_ROOT="$home/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$home/checkout-refresh-state" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_WORKTREE="$worktree" FM_FAKE_TREEHOUSE_LOG="$home/treehouse.log" \
    FM_FAKE_LAUNCH_LOG="$launch_log" \
    PATH="${FM_TEST_PATH_OVERRIDE:-$fakebin:$PATH}" "$SPAWN" "$@" 2>&1
}

empty_backlog() {
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

test_new_ship_without_row_is_refused_with_fix() {
  local record id out status expected_fix
  id=backlog-missing-z1
  record=$(make_spawn_case missing "$id")
  read_spawn_case "$record"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n- [x] %s - historical task\n' \
    "$id" > "$HOME_DIR/data/backlog.md"

  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "new ship without a backlog row should be refused"
  assert_contains "$out" "new ship task $id has no In flight or Queued row in $HOME_DIR/data/backlog.md" \
    "refusal did not name the task and home backlog"
  expected_fix="tasks-axi add '$id' '<one line>' --kind 'ship' --repo 'project' --start --backend markdown --file '$HOME_DIR/data/backlog.md'"
  assert_contains "$out" "$expected_fix" "refusal did not print the exact tasks-axi repair command"
  assert_absent "$HOME_DIR/state/$id.meta" "backlog refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "backlog refusal created an endpoint launch"
  assert_not_contains "$(cat "$HOME_DIR/treehouse.log")" "get " \
    "backlog refusal acquired a Treehouse lease before validation"
  pass "new ship without a backlog row is refused before endpoint creation with a scoped fix"
}

test_rows_in_manual_backlog_allow_ship_and_scout() {
  local record ship_id scout_id out status
  ship_id=backlog-ship-z2
  record=$(make_spawn_case manual-ship "$ship_id")
  read_spawn_case "$record"
  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$ship_id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "new ship with an In flight row should proceed"
  assert_contains "$out" "spawned $ship_id" "ship with a row did not reach endpoint creation"

  scout_id=backlog-scout-z3
  record=$(make_spawn_case manual-scout "$scout_id")
  read_spawn_case "$record"
  printf '# Backlog\n\n## In flight\n\n## Queued\n- **%s** - queued scout\n\n## Done\n' \
    "$scout_id" > "$HOME_DIR/data/backlog.md"
  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$scout_id" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 0 "$status" "new scout with a Queued row should proceed"
  assert_contains "$out" "spawned $scout_id" "scout with a row did not reach endpoint creation"
  assert_grep 'kind=scout' "$HOME_DIR/state/$scout_id.meta" "scout spawn recorded the wrong kind"
  pass "manual-backend In flight and Queued rows allow ship and scout spawns"
}

test_missing_tasks_axi_falls_back_to_manual_read() {
  local record id out status node_path
  id=backlog-no-axi-z3b
  record=$(make_spawn_case no-tasks-axi "$id")
  read_spawn_case "$record"
  rm -f "$HOME_DIR/config/backlog-backend"
  node_path=$(command -v node)
  ln -s "$node_path" "$FAKEBIN_DIR/node"
  export FM_TEST_PATH_OVERRIDE="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  if PATH="$FM_TEST_PATH_OVERRIDE" command -v tasks-axi >/dev/null 2>&1; then
    fail "tasks-axi absence fixture still resolves tasks-axi"
  fi

  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJECT_DIR")
  status=$?
  unset FM_TEST_PATH_OVERRIDE
  expect_code 0 "$status" "missing tasks-axi should fall back to the manual backlog read: $out"
  assert_contains "$out" "spawned $id" "manual fallback did not reach endpoint creation"
  pass "missing tasks-axi falls back to the home's manual backlog read"
}

test_bounded_exemption_is_validated_and_recorded() {
  local record id out status invalid_id
  id=backlog-exempt-z4
  record=$(make_spawn_case exemption "$id")
  read_spawn_case "$record"
  empty_backlog "$HOME_DIR/data/backlog.md"

  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJECT_DIR" --backlog-row-exemption test-fixture)
  status=$?
  expect_code 0 "$status" "sanctioned backlog exemption should allow the spawn"
  assert_contains "$out" "backlog row exemption 'test-fixture' is active" \
    "sanctioned exemption was not surfaced"
  assert_grep 'backlog_row_exemption=test-fixture' "$HOME_DIR/state/$id.meta" \
    "sanctioned exemption was not recorded in metadata"

  invalid_id=backlog-invalid-z5
  record=$(make_spawn_case invalid-exemption "$invalid_id")
  read_spawn_case "$record"
  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$invalid_id" "$PROJECT_DIR" --backlog-row-exemption routine-dispatch)
  status=$?
  expect_code 1 "$status" "unlisted backlog exemption should be refused"
  assert_contains "$out" "must be one of test-fixture, tracking-backend-repair" \
    "invalid exemption did not print the closed set"
  assert_absent "$HOME_DIR/state/$invalid_id.meta" "invalid exemption wrote task metadata"
  pass "backlog exemptions are closed-set, explicit, and recorded"
}

test_tasks_axi_read_is_pinned_to_home_backlog() {
  local record id out status expected_call
  id=backlog-home-z6
  record=$(make_spawn_case tasks-axi-home "$id")
  read_spawn_case "$record"
  rm -f "$HOME_DIR/config/backlog-backend"
  cat > "$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}:${2:-}" in
  --version:*) printf 'tasks-axi 0.2.2\n'; exit 0 ;;
  update:--help) printf '%s\n' '--archive-body'; exit 0 ;;
  mv:--help) printf '%s\n' '[<id>...]'; exit 0 ;;
esac
if [ "${1:-}" = show ]; then
  printf '%s\n' "$*" >> "${FM_FAKE_TASKS_AXI_LOG:?}"
  file=
  previous=
  for argument in "$@"; do
    if [ "$previous" = --file ]; then
      file=$argument
    fi
    previous=$argument
  done
  [ "$file" = "${FM_EXPECTED_BACKLOG_FILE:?}" ] || exit 1
  printf 'task:\n  id: %s\n  state: in_flight\n' "${2:-unknown}"
  exit 0
fi
exit 1
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"
  export FM_FAKE_TASKS_AXI_LOG="$CASE_DIR/tasks-axi.log"
  export FM_EXPECTED_BACKLOG_FILE="$HOME_DIR/data/backlog.md"

  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "tasks-axi-backed row in the home backlog should allow spawn: $out"
  expected_call="show $id --backend markdown --file $HOME_DIR/data/backlog.md"
  assert_grep "$expected_call" "$FM_FAKE_TASKS_AXI_LOG" \
    "tasks-axi read was not pinned to the home's backlog file"
  assert_not_contains "$(cat "$FM_FAKE_TASKS_AXI_LOG")" "$ROOT/data/backlog.md" \
    "tasks-axi read leaked to the repo-root backlog"
  unset FM_FAKE_TASKS_AXI_LOG FM_EXPECTED_BACKLOG_FILE
  pass "tasks-axi backlog reads are explicitly pinned to the active home"
}

test_batch_checks_each_pair_and_continues() {
  local record missing_id present_id out status
  missing_id=backlog-batch-missing-z7
  present_id=backlog-batch-present-z8
  record=$(make_spawn_case batch "$missing_id" "$present_id")
  read_spawn_case "$record"
  printf '# Backlog\n\n## In flight\n- [ ] %s - tracked batch task (repo: project)\n\n## Queued\n\n## Done\n' \
    "$present_id" > "$HOME_DIR/data/backlog.md"

  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$missing_id=$PROJECT_DIR" "$present_id=$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "batch with one missing backlog row should report partial failure"
  assert_contains "$out" "new ship task $missing_id has no In flight or Queued row" \
    "batch did not check the missing pair"
  assert_contains "$out" "batch: FAILED to spawn $missing_id ($PROJECT_DIR)" \
    "batch did not report the refused pair"
  assert_contains "$out" "spawned $present_id" "batch stopped before the tracked pair"
  assert_absent "$HOME_DIR/state/$missing_id.meta" "refused batch pair wrote metadata"
  [ -f "$HOME_DIR/state/$present_id.meta" ] || fail "tracked batch pair did not write metadata"
  pass "batch dispatch checks every pair and continues after a backlog refusal"
}

test_new_ship_without_row_is_refused_with_fix
test_rows_in_manual_backlog_allow_ship_and_scout
test_missing_tasks_axi_falls_back_to_manual_read
test_bounded_exemption_is_validated_and_recorded
test_tasks_axi_read_is_pinned_to_home_backlog
test_batch_checks_each_pair_and_continues

echo "# all fm-spawn-backlog tests passed"
