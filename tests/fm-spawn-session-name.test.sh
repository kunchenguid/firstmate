#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh secondmate session display names.
#
# These tests drive fm-spawn through label resolution, meta recording, and
# launch construction with a fake tmux pane, so assertions pin the exact launch
# command firstmate would run without starting any real harness. Covered:
# registry "label:" field wins, prior meta label= backfills, the derived
# "SM <Title-cased id suffix>" fallback, the name flag emitted only for the
# verified claude adapter, and ship spawns staying label-free.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-session-name)

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

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

register_secondmate() {  # <home-dir> <id> <sm-home> [label]
  local home=$1 id=$2 sm=$3 label=${4:-} suffix
  suffix=
  [ -z "$label" ] || suffix="; label: $label"
  printf -- '- %s - test secondmate (home: %s; scope: testing; projects: none; added 2026-07-22%s)\n' \
    "$id" "$sm" "$suffix" >> "$home/data/secondmates.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

test_registry_label_threads_claude_name_flag() {
  local rec id sm out status launch
  id='sm-cnc'
  rec=$(make_spawn_case registry-label claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  register_secondmate "$HOME_DIR" "$id" "$sm" "SM CNC"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn with a registry label should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=secondmate" "spawn did not report claude secondmate"
  assert_grep "label=SM CNC" "$HOME_DIR/state/$id.meta" "meta missing label=SM CNC"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--name 'SM CNC'" "claude secondmate launch did not carry the registry label"
  assert_not_contains "$launch" "SM Cnc" "registry label must beat the derived title-case fallback"
  pass "registry label: field threads claude's --name flag and lands in meta"
}

test_derived_label_when_registry_has_no_label() {
  local rec id sm out status launch
  id='sm-portal'
  rec=$(make_spawn_case derived-label claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  register_secondmate "$HOME_DIR" "$id" "$sm"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn without a registry label should succeed"
  assert_grep "label=SM Portal" "$HOME_DIR/state/$id.meta" "meta missing derived label=SM Portal"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--name 'SM Portal'" "claude secondmate launch did not derive SM Portal from sm-portal"
  pass "missing registry label falls back to the derived SM <Title-cased suffix> label"
}

test_derived_label_title_cases_multiword_suffix() {
  local rec id sm out status launch
  id='sm-portal-api'
  rec=$(make_spawn_case derived-multiword claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn with a multiword id should succeed"
  assert_grep "label=SM Portal Api" "$HOME_DIR/state/$id.meta" "meta missing derived multiword label"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--name 'SM Portal Api'" "derived label did not title-case each hyphen-separated word"
  pass "derived fallback title-cases every hyphen-separated id word"
}

test_meta_label_backfills_missing_registry_label() {
  local rec id sm out status launch
  id='sm-fw'
  rec=$(make_spawn_case meta-backfill claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  register_secondmate "$HOME_DIR" "$id" "$sm"
  printf 'home=%s\nlabel=SM Firmware\n' "$sm" > "$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "respawn with a prior meta label should succeed"
  assert_grep "label=SM Firmware" "$HOME_DIR/state/$id.meta" "respawn meta lost the carried-over label"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--name 'SM Firmware'" "respawn did not carry the prior meta label"
  assert_not_contains "$launch" "SM Fw" "prior meta label must beat the derived fallback"
  pass "a prior meta label= backfills a registry line without a label field"
}

test_codex_secondmate_records_label_but_omits_name_flag() {
  local rec id sm out status launch
  id='sm-cnc-codex'
  rec=$(make_spawn_case codex-omits codex "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  register_secondmate "$HOME_DIR" "$id" "$sm" "SM CNC"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "codex secondmate spawn should succeed without a name flag"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "spawn did not report codex secondmate"
  assert_grep "label=SM CNC" "$HOME_DIR/state/$id.meta" "codex meta must still record the resolved label"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--name" "codex has no verified session-name flag; it must be omitted"
  assert_contains "$launch" "codex " "codex launch command was not sent"
  pass "an unverified-name-flag harness records label= in meta but emits no flag"
}

test_ship_spawn_carries_no_label_or_name_flag() {
  local rec id out status launch
  id=ship-name-z1
  rec=$(make_spawn_case ship-unchanged claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "ship spawn should succeed unchanged"
  assert_no_grep "^label=" "$HOME_DIR/state/$id.meta" "ship meta must not record a label"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--name" "ship launch must not carry a session-name flag"
  assert_contains "$launch" "claude --dangerously-skip-permissions \"\$(cat " \
    "ship claude launch changed shape"
  pass "ship spawns stay label-free and keep the launch byte-identical"
}

test_registry_label_threads_claude_name_flag
test_derived_label_when_registry_has_no_label
test_derived_label_title_cases_multiword_suffix
test_meta_label_backfills_missing_registry_label
test_codex_secondmate_records_label_but_omits_name_flag
test_ship_spawn_carries_no_label_or_name_flag

echo "# all fm-spawn-session-name tests passed"
