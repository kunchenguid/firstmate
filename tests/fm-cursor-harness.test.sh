#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

# Fake tmux that logs the `send-keys -l <payload>` launch line so tests can
# inspect the composed launch command without running a real agent.
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
  send-keys)
    shift
    prev=""
    for a in "$@"; do
      [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "${FM_FAKE_SENDKEYS_LOG:-/dev/null}"
      prev="$a"
    done
    exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin cursor_cfg id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  cursor_cfg="$case_dir/cursorcfg"
  id="cursor-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$cursor_cfg/hooks"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$cursor_cfg|$id"
}

run_cursor_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 cursor_cfg=$5 id=$6 log=$7
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CURSOR_CONFIG_DIR="$cursor_cfg" FM_FAKE_SENDKEYS_LOG="$log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor --model claude-opus-4-8-thinking-max 2>&1
}

test_cursor_launch_template() {
  local rec case_dir home proj wt fakebin cursor_cfg id log out status
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin cursor_cfg id <<EOF
$rec
EOF
  log="$case_dir/sendkeys.log"; : > "$log"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$cursor_cfg" "$id" "$log")
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"
  assert_grep 'force' "$log" "launch did not include the --force autonomy flag"
  assert_grep 'claude-opus-4-8-thinking-max' "$log" "launch did not include the model id"
  assert_no_grep 'effort' "$log" "cursor launch must not include an effort flag (effort is in the model id)"
  pass "cursor launch template uses --force, --model, and no --effort"
}

test_detects_cursor_via_env_marker() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' "$HARNESS")
  assert_contains "$out" "cursor" "CURSOR_AGENT=1 should detect the cursor harness"
  pass "detects cursor via CURSOR_AGENT marker"
}

test_claude_still_wins_when_both_set() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS")
  assert_contains "$out" "claude" "a genuine claude session (CLAUDECODE=1) must resolve to claude, not cursor"
  pass "preference-neutral: claude wins when CLAUDECODE is set"
}

test_fm_lock_recognizes_cursor_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/x/.local/share/cursor-agent/versions/v/cursor-agent'; exit 0 ;;
  *"args="*) printf '%s\n' 'cursor-agent'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize cursor-agent as a live holder"
  pass "fm-lock recognizes cursor-agent harness processes"
}

test_detects_cursor_via_env_marker
test_claude_still_wins_when_both_set
test_fm_lock_recognizes_cursor_holder
test_cursor_launch_template
