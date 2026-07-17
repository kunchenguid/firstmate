#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

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
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
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
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor 2>&1
}

test_cursor_spawn_installs_no_turnend_hook_artifacts() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case hookless)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"

  assert_absent "$wt/.claude/settings.local.json" "cursor spawn must not install the claude Stop-hook settings file"
  assert_absent "$wt/.opencode/plugins/fm-turn-end.js" "cursor spawn must not install the opencode turn-end plugin"
  assert_absent "$wt/.fm-grok-turnend" "cursor spawn must not install the grok turn-end pointer"
  assert_absent "$home/state/$id.pi-ext.ts" "cursor spawn must not install the pi turn-end extension"
  assert_absent "$home/state/$id.grok-turnend-token" "cursor spawn must not write a grok turn-end token"
  pass "cursor spawn wires no turn-end hook artifacts (relies on busy-pane + stale-pane detection)"
}

test_cursor_spawn_launch_template() {
  local rec case_dir home proj wt fakebin id out status meta
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  meta="$home/state/$id.meta"
  assert_grep "harness=cursor" "$meta" "cursor meta missing harness=cursor"
  assert_grep "model=default" "$meta" "cursor meta should default model when unset"
  assert_grep "effort=default" "$meta" "cursor meta should default effort when unset"
  pass "cursor spawn resolves the launch template and records default profile in meta"
}

test_fm_harness_detects_cursor_before_claude_marker() {
  local out
  # cursor-agent ALSO sets CLAUDECODE=1 and AI_AGENT=claude-code_* (it is
  # Claude-Code-compatible under the hood); CURSOR_AGENT must win or a cursor
  # session misdetects as claude.
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 AI_AGENT=claude-code_1.0 "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "fm-harness.sh detected '$out', expected cursor to win over the claude-compatible markers"
  pass "fm-harness.sh checks CURSOR_AGENT before CLAUDECODE"
}

test_fm_harness_detects_cursor_via_process_ancestry() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/cursor-agent'; exit 0 ;;
  *"args="*) printf '%s\n' 'cursor-agent'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" env -u CURSOR_AGENT -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "fm-harness.sh process-ancestry detection returned '$out', expected cursor"
  pass "fm-harness.sh recognizes cursor-agent via process ancestry"
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
  *"comm="*) printf '%s\n' '/usr/local/bin/cursor-agent'; exit 0 ;;
  *"args="*) printf '%s\n' 'cursor-agent'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize cursor-agent as a live holder"
  pass "fm-lock recognizes cursor-agent harness processes"
}

test_fm_lock_recognizes_cursor_mainthread_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-mainthread-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-mainthread-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' '/home/user/.local/bin/cursor-agent --use-system-ca'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize MainThread cursor-agent as a live holder"
  pass "fm-lock recognizes cursor-agent when comm is MainThread"
}

test_cursor_spawn_installs_no_turnend_hook_artifacts
test_cursor_spawn_launch_template
test_fm_harness_detects_cursor_before_claude_marker
test_fm_harness_detects_cursor_via_process_ancestry
test_fm_lock_recognizes_cursor_holder
test_fm_lock_recognizes_cursor_mainthread_holder

echo "# all fm-cursor-harness tests passed"
