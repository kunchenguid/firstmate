#!/usr/bin/env bash
# Optional work-item link: spawn records it, relaunch keeps it, and the fleet
# snapshot publishes it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-work-item)
ITEM='https://example.com/cards/abc?id=42'

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# make_case <name> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>".
make_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_case_spawn() {
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

meta_line_count() {  # <file> <prefix>
  grep -c "^$2" "$1" 2>/dev/null || true
}

test_help_names_the_flag() {
  local help
  help=$("$SPAWN" --help)
  assert_contains "$help" "--work-item <url-or-id>" \
    "spawn help should name the optional work-item flag"
  assert_contains "$help" "work_item=" \
    "spawn help should name the task-record field"
  pass "spawn help documents --work-item"
}

test_ship_and_scout_record_the_work_item() {
  local rec out status snap
  rec=$(make_case record ship-a1 scout-a1 plain-a1)
  read_case "$rec"

  out=$(run_case_spawn ship-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --work-item "$ITEM")
  status=$?
  expect_code 0 "$status" "a ship spawn with --work-item should launch"$'\n'"$out"
  assert_grep "work_item=$ITEM" "$HOME_DIR/state/ship-a1.meta" \
    "the ship record should keep the identifier, including its query"
  [ "$(meta_line_count "$HOME_DIR/state/ship-a1.meta" 'work_item=')" = 1 ] \
    || fail "the ship record should carry one work_item line"

  out=$(run_case_spawn scout-a1 "$PROJ_DIR" --scout --work-item "$ITEM")
  status=$?
  expect_code 0 "$status" "a scout spawn with --work-item should launch"$'\n'"$out"
  assert_grep "work_item=$ITEM" "$HOME_DIR/state/scout-a1.meta" \
    "the scout record should keep the identifier"

  out=$(run_case_spawn plain-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a ship spawn without --work-item should launch"$'\n'"$out"
  assert_no_grep 'work_item=' "$HOME_DIR/state/plain-a1.meta" \
    "a spawn without --work-item should record no link"

  snap=$(PATH="$FAKEBIN_DIR:$PATH" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_CREW_STATE_TIMEOUT=2 "$SNAPSHOT" --json)
  printf '%s' "$snap" | jq -e --arg item "$ITEM" '
    ([.tasks[] | select(.id == "ship-a1") | .work_item] == [$item])
      and ([.tasks[] | select(.id == "scout-a1") | .work_item] == [$item])
      and ([.tasks[] | select(.id == "plain-a1") | .work_item] == [null])
  ' >/dev/null \
    || fail "the snapshot should publish the recorded link and null when it is absent: $snap"
  pass "ship and scout spawns record an optional work item and the snapshot publishes it"
}

test_secondmate_records_the_work_item() {
  local rec sm out status
  rec=$(make_case secondmate sm-a1)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' sm-a1 > "$sm/.fm-secondmate-home"
  printf 'charter for sm-a1\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_case_spawn sm-a1 "$sm" --work-item "$ITEM" --secondmate)
  status=$?
  expect_code 0 "$status" "a secondmate spawn with --work-item should launch"$'\n'"$out"
  assert_grep "work_item=$ITEM" "$HOME_DIR/state/sm-a1.meta" \
    "a secondmate record should keep the same work_item field"
  pass "a secondmate spawn records --work-item the same way"
}

test_bad_work_item_refuses_before_a_record() {
  local rec out status bad
  rec=$(make_case refuse refuse-a1)
  read_case "$rec"
  for bad in $'card\tid' $'card\nid'; do
    out=$(run_case_spawn refuse-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --work-item "$bad")
    status=$?
    expect_code 1 "$status" "a control character in --work-item should refuse"$'\n'"$out"
    assert_contains "$out" "control character" \
      "the refusal should name the broken task record"
    assert_absent "$HOME_DIR/state/refuse-a1.meta" \
      "a refused work item must not publish a task record"
  done
  out=$(run_case_spawn refuse-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --work-item=)
  status=$?
  expect_code 1 "$status" "an empty --work-item should refuse"$'\n'"$out"
  assert_contains "$out" "non-empty" "an empty flag should say it needs a value"
  assert_absent "$HOME_DIR/state/refuse-a1.meta" \
    "an empty work item must not publish a task record"
  pass "a work item with a control character, newline, or empty value is refused before any record"
}

test_relaunch_refuses_a_new_work_item() {
  local rec out status
  rec=$(make_case override override-a1)
  read_case "$rec"
  out=$(run_case_spawn override-a1 --relaunch --work-item "$ITEM")
  status=$?
  expect_code 1 "$status" "relaunch must refuse a new --work-item"$'\n'"$out"
  assert_contains "$out" "--work-item cannot override it" \
    "the refusal should say relaunch keeps the recorded value"
  assert_absent "$HOME_DIR/state/override-a1.meta" \
    "a refused relaunch override must not publish a task record"
  pass "relaunch refuses --work-item instead of replacing the recorded link"
}

# Dead-endpoint relaunch: the pane command is a shell, so the replacement
# adopts the recorded window and republishes the task record.
make_relaunch_tmux() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_FAKE_DIR:?}
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) printf 'zsh\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *pane_tty*) printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'
    exit 0 ;;
  list-windows)
    cat "$D/windows"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_keeps_the_recorded_work_item() {
  local dir home proj wt id out status count
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  id=relaunch-a1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  make_relaunch_tmux "$dir"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "branch=fm/$id"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
    echo "work_item=$ITEM"
  } > "$home/state/$id.meta"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  expect_code 0 "$status" "relaunch of a recorded work item should launch"$'\n'"$out"
  assert_grep "work_item=$ITEM" "$home/state/$id.meta" \
    "relaunch should keep the recorded work item"
  count=$(meta_line_count "$home/state/$id.meta" 'work_item=')
  [ "$count" = 1 ] || fail "relaunch should keep a single work_item line, got ${count:-0}"
  pass "relaunch republishes the recorded work item and does not duplicate it"
}

test_snapshot_publishes_absent_as_null() {
  local home fakebin out
  home="$TMP_ROOT/snapshot-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fakebin=$(fm_fakebin "$home/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_write_meta "$home/state/linked.meta" \
    "window=fmses:fm-linked" \
    "worktree=$home/missing-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "work_item=$ITEM"
  fm_write_meta "$home/state/plain.meta" \
    "window=fmses:fm-plain" \
    "worktree=$home/missing-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "yolo=off"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_CREW_STATE_TIMEOUT=2 \
    "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg item "$ITEM" '
    .schema == "fm-fleet-snapshot.v1"
      and ([.tasks[] | select(.id == "linked") | .work_item] == [$item])
      and ([.tasks[] | select(.id == "plain") | .work_item] == [null])
  ' >/dev/null \
    || fail "snapshot work_item should be the recorded value or null: $out"
  pass "the fleet snapshot publishes work_item and null when the record has none"
}

test_help_names_the_flag
test_bad_work_item_refuses_before_a_record
test_relaunch_refuses_a_new_work_item
test_ship_and_scout_record_the_work_item
test_secondmate_records_the_work_item
test_relaunch_keeps_the_recorded_work_item
test_snapshot_publishes_absent_as_null
