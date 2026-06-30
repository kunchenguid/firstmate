#!/usr/bin/env bash
# Tests for firstmate's opt-in tmux pane layout.
#
# The default stays one window per task. With FM_TMUX_LAYOUT=pane, fm-spawn splits
# the current tmux window, records the containing window for compatibility, and
# records pane=<pane-id> as the active supervision target. These tests use a fake
# tmux and never launch a real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
PEEK="$ROOT/bin/fm-peek.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-tmux-pane-layout)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_TMUX_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '0\n'; exit 0 ;;
  *"#S"*) printf 'firstmate\n'; exit 0 ;;
  *"#W"*) printf 'main\n'; exit 0 ;;
  *"#{pane_id}"*) printf '%%42\n'; exit 0 ;;
esac
case "${1:-}" in
  split-window) printf '%%42\n'; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|select-pane|kill-window|kill-pane|send-keys) exit 0 ;;
  capture-pane) printf '>\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 dir home proj wt fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "fm/$name"
  printf '%s\n' "$dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_spawn_pane_layout_records_compatible_targets() {
  local rec id out status log meta
  id=pane-layout-z1
  rec=$(make_case spawn-pane)
  read_case "$rec"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief\n' > "$HOME_DIR/data/$id/brief.md"
  log="$CASE_DIR/tmux.log"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_TMUX_LAYOUT=pane TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_TMUX_LOG="$log" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" codex 2>&1)
  status=$?
  expect_code 0 "$status" "pane-layout spawn should succeed"
  assert_contains "$out" "window=firstmate:main pane=%42" "spawn output did not report both window and pane"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep "window=firstmate:main" "$meta" "pane-layout meta must preserve containing window"
  assert_grep "pane=%42" "$meta" "pane-layout meta missing active pane target"
  assert_grep "tmux_layout=pane" "$meta" "pane-layout meta missing layout marker"
  assert_no_grep "window=firstmate:fm-$id" "$meta" "pane layout must not overwrite window= with the pane target"
  assert_grep "split-window -d -P -F #{pane_id} -c " "$log" "spawn did not split the current tmux window"
  assert_grep "send-keys -t %42 treehouse get Enter" "$log" "treehouse get was not sent to the new pane"
  pass "FM_TMUX_LAYOUT=pane records window= for compatibility and pane= for supervision"
}

test_send_and_peek_prefer_pane_with_window_fallback() {
  local rec id log
  id=pane-target-z2
  rec=$(make_case send-pane)
  read_case "$rec"
  log="$CASE_DIR/tmux.log"
  cat > "$HOME_DIR/state/$id.meta" <<EOF
window=firstmate:fm-$id
pane=%42
worktree=$WT_DIR
harness=codex
kind=ship
EOF

  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_LOG="$log" PATH="$FAKEBIN_DIR:$PATH" \
    "$SEND" "fm-$id" "hello pane" >/dev/null 2>&1 \
    || fail "fm-send failed against pane target"
  assert_grep "send-keys -t %42 -l hello pane" "$log" "fm-send did not prefer pane= target"

  : > "$log"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_FAKE_TMUX_LOG="$log" PATH="$FAKEBIN_DIR:$PATH" \
    "$PEEK" "fm-$id" >/dev/null 2>&1 \
    || fail "fm-peek failed against pane target"
  assert_grep "capture-pane -p -t %42 -S -40" "$log" "fm-peek did not prefer pane= target"

  sed -i.bak '/^pane=/d' "$HOME_DIR/state/$id.meta"
  : > "$log"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_FAKE_TMUX_LOG="$log" PATH="$FAKEBIN_DIR:$PATH" \
    "$PEEK" "fm-$id" >/dev/null 2>&1 \
    || fail "fm-peek failed against legacy window-only target"
  assert_grep "capture-pane -p -t firstmate:fm-$id -S -40" "$log" "fm-peek did not fall back to window="
  pass "fm-send/fm-peek use pane= when present and keep legacy window= fallback"
}

test_teardown_kills_pane_not_window_when_recorded() {
  local case_dir fakebin log state
  case_dir="$TMP_ROOT/teardown-pane"
  fakebin=$(make_fakebin "$case_dir/fake")
  state="$case_dir/state"
  mkdir -p "$state" "$case_dir/config" "$case_dir/data" "$case_dir/wt" "$case_dir/project"
  log="$case_dir/tmux.log"
  cat > "$state/task.meta" <<EOF
window=firstmate:main
pane=%42
worktree=$case_dir/wt
project=$case_dir/project
kind=ship
mode=no-mistakes
tasktmp=$case_dir/tmp
EOF

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_TMUX_LOG="$log" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task --force >/dev/null 2>&1 \
    || fail "forced teardown failed for pane target"
  assert_grep "kill-pane -t %42" "$log" "teardown did not kill the recorded pane"
  assert_no_grep "kill-window -t firstmate:main" "$log" "teardown killed the containing window instead of the pane"
  pass "teardown kills pane= targets without killing the containing window"
}

test_spawn_pane_layout_records_compatible_targets
test_send_and_peek_prefer_pane_with_window_fallback
test_teardown_kills_pane_not_window_when_recorded

echo "# all fm-tmux-pane-layout tests passed"
