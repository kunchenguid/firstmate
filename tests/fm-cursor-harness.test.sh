#!/usr/bin/env bash
# Behavior tests for the cursor (Cursor Agent CLI) crewmate adapter:
#   - harness detection via the CURSOR_INVOKED_AS env marker (layer 1) and the
#     `agent` command name whose args carry the cursor-agent install path (layer 2);
#   - the `agent --force --approve-mcps` launch template and harness=cursor meta;
#   - the per-task in-worktree .cursor/hooks.json `stop`-event turn-end signal,
#     gitignored via info/exclude, plus its no-clobber guard over an existing
#     (tracked) project .cursor/hooks.json;
#   - the `ctrl+c to stop` busy signature in the shared tmux busy regex.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS_BIN="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

# --- detection --------------------------------------------------------------

test_detect_cursor_env_marker() {
  local out
  # Layer 1: a non-empty CURSOR_INVOKED_AS wins over process ancestry. Blank the
  # other harness markers so this test is not skewed by the harness it runs under.
  out=$(CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' CURSOR_INVOKED_AS=agent "$HARNESS_BIN")
  assert_contains "$out" "cursor" "CURSOR_INVOKED_AS marker should detect cursor"
  [ "$out" = "cursor" ] || fail "expected exactly 'cursor', got '$out'"
  pass "CURSOR_INVOKED_AS env marker detects cursor"
}

test_detect_cursor_process_ancestry() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-ancestry")
  # Layer 2: comm is the generic name `agent`; disambiguate by args carrying the
  # cursor-agent install path. ppid returns 1 to stop the ancestry walk.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'agent'; exit 0 ;;
  *"args="*) printf '%s\n' '/Users/x/.local/bin/agent --use-system-ca /Users/x/.local/share/cursor-agent/versions/2026.07.09-a3815c0/index.js --force run'; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' CURSOR_INVOKED_AS='' \
    PATH="$fakebin:$PATH" "$HARNESS_BIN")
  [ "$out" = "cursor" ] || fail "expected ancestry detection 'cursor', got '$out'"
  pass "cursor process ancestry (agent + cursor-agent args) detects cursor"
}

# --- spawn / launch template / turn-end hook --------------------------------

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
  new-window) printf '@1\n'; exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:-/dev/null}"; exit 0 ;;
  has-session|new-session|set-window-option|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="cursor-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_cursor_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 sendlog=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_SENDLOG="$sendlog" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor 2>&1
}

test_cursor_spawn_launch_and_turnend_hook() {
  local rec case_dir home proj wt fakebin id out status sendlog hooks
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  sendlog="$case_dir/sendlog"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$sendlog")
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"
  assert_grep "harness=cursor" "$home/state/$id.meta" "meta did not record harness=cursor"

  # Launch template: agent --force --approve-mcps "$(cat <brief>)"
  assert_grep "agent --force --approve-mcps" "$sendlog" "launch command missing cursor autonomy flags"

  # Turn-end hook: per-task in-worktree .cursor/hooks.json with a `stop` hook that
  # touches state/<id>.turn-ended, gitignored via info/exclude.
  hooks="$wt/.cursor/hooks.json"
  assert_present "$hooks" "cursor turn-end hooks.json was not installed"
  assert_grep '"stop"' "$hooks" "cursor hook did not use the stop event"
  # The recorded path is physically resolved (macOS /var -> /private/var), so match
  # the task-specific turn-end basename rather than the pre-resolution home path.
  assert_grep "$id.turn-ended" "$hooks" "cursor hook did not target the task turn-end file"
  local excl
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_grep ".cursor/hooks.json" "$excl" "cursor hooks.json was not added to info/exclude"

  # The stop hook actually touches the marker when run.
  local marker cmd
  marker="$home/state/$id.turn-ended"
  rm -f "$marker"
  cmd=$(sed -n 's/.*"command":"\(touch [^"]*\)".*/\1/p' "$hooks")
  [ -n "$cmd" ] || fail "could not extract cursor hook command from $hooks"
  eval "$cmd"
  assert_present "$marker" "cursor stop hook command did not touch the turn-end marker"
  pass "cursor spawn uses the agent launch template and installs a working stop-hook turn-end signal"
}

test_cursor_hook_guard_does_not_clobber_project_hooks() {
  local rec case_dir home proj wt fakebin id out status sendlog hooks before after
  rec=$(make_spawn_case guard)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  sendlog="$case_dir/sendlog"
  hooks="$wt/.cursor/hooks.json"
  mkdir -p "$wt/.cursor"
  printf '%s\n' '{"version":1,"hooks":{"afterFileEdit":[{"command":".cursor/hooks/format.sh"}]}}' > "$hooks"
  before=$(cat "$hooks")
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$sendlog")
  status=$?
  expect_code 0 "$status" "cursor spawn should still succeed when project hooks exist"
  after=$(cat "$hooks")
  [ "$before" = "$after" ] || fail "cursor spawn clobbered an existing project .cursor/hooks.json"
  assert_contains "$out" "already exists" "cursor spawn did not warn about the pre-existing hooks.json"
  local excl
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_no_grep ".cursor/hooks.json" "$excl" "cursor spawn excluded a project-owned hooks.json"
  pass "cursor spawn refuses to clobber an existing project .cursor/hooks.json and falls back to stale-pane detection"
}

# --- busy signature ---------------------------------------------------------

test_cursor_busy_signature() {
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/busy")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_PANE_CONTENT:-}"
exit 0
SH
  chmod +x "$fakebin/tmux"
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CONTENT='  → Add a follow-up                    ctrl+c to stop' \
    bash -c '. "'"$ROOT"'/bin/fm-tmux-lib.sh"; fm_pane_is_busy win' \
    || fail "cursor busy footer 'ctrl+c to stop' was not recognized as busy"
  if PATH="$fakebin:$PATH" FM_FAKE_PANE_CONTENT='  → Add a follow-up' \
    bash -c '. "'"$ROOT"'/bin/fm-tmux-lib.sh"; fm_pane_is_busy win'; then
    fail "cursor idle footer '→ Add a follow-up' was wrongly seen as busy"
  fi
  pass "cursor 'ctrl+c to stop' busy signature classifies busy vs idle panes"
}

test_detect_cursor_env_marker
test_detect_cursor_process_ancestry
test_cursor_spawn_launch_and_turnend_hook
test_cursor_hook_guard_does_not_clobber_project_hooks
test_cursor_busy_signature
