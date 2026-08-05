#!/usr/bin/env bash
# Behavior tests for the verified Cursor Agent CLI crewmate adapter.
#
# The launch tests drive fm-spawn through meta writing and launch construction
# with a fake tmux pane and a real isolated git worktree. The fake tmux captures
# the literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would type into the pane without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

cleanup_cursor_harness() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_cursor_harness EXIT

make_cursor_fakebin() {
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
  fm_fake_exit0 "$fakebin" treehouse cursor-agent
  printf '%s\n' "$fakebin"
}

make_cursor_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  shift
  id=$1
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_cursor_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' cursor > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# --- harness detection: CURSOR_AGENT=1 marker --------------------------------

test_cursor_env_marker() {
  local out
  out=$(CURSOR_AGENT=1 "$HARNESS" 2>/dev/null)
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 must detect as cursor, got '$out'"
  pass "CURSOR_AGENT=1 detects as cursor"
}

# --- harness detection: CURSOR_AGENT=1 wins over CLAUDECODE=1 -----------------

test_cursor_env_marker_wins_over_claudecode() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS" 2>/dev/null)
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 must win over CLAUDECODE=1, got '$out'"
  pass "CURSOR_AGENT=1 wins over CLAUDECODE=1"
}

# --- launch: --force, --trust, env sanitization, encoded brief, no --worktree --

test_cursor_launch_command_typed() {
  local rec id out status expected launch
  id=cursor-launch-z1
  rec=$(make_cursor_case cursor-launch "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "cursor spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "spawn did not report cursor harness"
  assert_grep "harness=cursor" "$HOME_DIR/state/$id.meta" "meta missing harness=cursor"
  launch=$(cat "$LAUNCH_LOG")
  expected="unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; cursor-agent --force --trust \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "cursor launch did not match the canonical command"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "cursor spawn types --force --trust with env sanitization and the encoded brief"
}

test_cursor_model_flag_threaded() {
  local rec id out status launch
  id=cursor-model-z2
  rec=$(make_cursor_case cursor-model "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet)
  status=$?
  expect_code 0 "$status" "cursor spawn with --model should succeed"
  assert_grep "model=sonnet" "$HOME_DIR/state/$id.meta" "meta missing model=sonnet"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent --force --trust --model 'sonnet' \"" \
    "cursor launch did not thread the model flag"
  pass "cursor receives --model in the typed launch command"
}

test_cursor_effort_recorded_not_emitted() {
  local rec id out status launch
  id=cursor-effort-z3
  rec=$(make_cursor_case cursor-effort "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with --effort should succeed"
  assert_grep "effort=high" "$HOME_DIR/state/$id.meta" "meta missing effort=high"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent --force --trust --model 'sonnet'" \
    "cursor launch lost the model flag when effort was recorded"
  assert_not_contains "$launch" "--effort" "cursor launch must not emit an effort flag"
  pass "cursor records effort in meta but never emits it"
}

test_cursor_missing_binary_refusal() {
  local rec id out status
  id=cursor-missing-z4
  rec=$(make_cursor_case cursor-missing "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/cursor-agent"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing cursor-agent executable should refuse the spawn"
  assert_contains "$out" "cursor-agent executable not found on PATH" \
    "missing cursor-agent refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing cursor-agent refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing cursor-agent refusal typed a launch command"
  pass "cursor refuses safely and actionably when the executable is unavailable"
}

# --- run all tests (order matters: simpler checks first) ---------------------

test_cursor_env_marker
test_cursor_env_marker_wins_over_claudecode
test_cursor_launch_command_typed
test_cursor_model_flag_threaded
test_cursor_effort_recorded_not_emitted
test_cursor_missing_binary_refusal
