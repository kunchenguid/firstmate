#!/usr/bin/env bash
# Behavior tests for the Cursor primary/crew harness adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

test_fm_harness_detects_cursor_env() {
  local got
  got=$(CURSOR_AGENT=1 CLAUDECODE= GROK_AGENT= PI_CODING_AGENT= "$ROOT/bin/fm-harness.sh")
  [ "$got" = cursor ] || fail "CURSOR_AGENT=1 should detect as cursor, got: $got"
  pass "fm-harness detects CURSOR_AGENT=1"
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
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' '/home/x/.local/bin/cursor-agent --use-system-ca /opt/index.js'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize cursor-agent as a live holder"
  pass "fm-lock recognizes cursor-agent harness processes"
}

test_cursor_arm_check_deny_shape() {
  local out rc=0
  out=$(printf '%s\n' '{"command":"bin/fm-watch.sh &"}' | "$ROOT/bin/fm-arm-pretool-check.sh" --cursor 2>/dev/null) || rc=$?
  expect_code 2 "$rc" "cursor arm check should deny watcher-direct with exit 2"
  assert_contains "$out" '"permission":"deny"' "cursor arm deny missing permission field"
  assert_contains "$out" 'watcher-direct' "cursor arm deny missing reason"
  pass "cursor arm check emits Cursor permission deny JSON"
}

test_cursor_sessionstart_nudge_wrapper() {
  local home out
  home="$TMP_ROOT/nudge-home"
  mkdir -p "$home/bin" "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_git_identity fmtest fmtest@example.invalid
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$home/bin/"
  cp "$ROOT/bin/fm-sessionstart-nudge-cursor.sh" "$home/bin/"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-operational-input.sh" "$home/bin/"
  chmod +x "$home/bin/"*.sh
  # No lock -> nudge should fire additional_context.
  out=$(FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-sessionstart-nudge-cursor.sh")
  assert_contains "$out" 'additional_context' "cursor sessionStart wrapper did not inject context"
  assert_contains "$out" 'fm-session-start.sh' "cursor sessionStart wrapper missing nudge text"
  pass "cursor sessionStart wrapper returns additional_context"
}

test_cursor_spawn_installs_turnend_hook() {
  local case_dir home proj wt fakebin id out status=0
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="cursor-spawn-x1"
  fakebin=$(fm_fakebin "$case_dir/fake")
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
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh cursor-agent
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor 2>&1) || status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"
  assert_present "$wt/.cursor/hooks.json" "cursor turn-end hooks.json missing"
  assert_present "$wt/.cursor/hooks/fm-turn-end.sh" "cursor turn-end script missing"
  assert_present "$wt/.fm-cursor-turnend" "cursor turn-end ownership marker missing"
  assert_grep 'created' "$wt/.fm-cursor-turnend" "fresh worktree should mark hooks.json as created"
  assert_grep 'fm-turn-end.sh' "$wt/.cursor/hooks.json" "hooks.json does not point at turn-end script"
  pass "cursor spawn installs project-local turn-end hook"
}

test_cursor_spawn_merges_existing_hooks() {
  local case_dir home proj wt fakebin id out status=0
  case_dir="$TMP_ROOT/spawn-merge"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="cursor-merge-x1"
  fakebin=$(fm_fakebin "$case_dir/fake")
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
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh cursor-agent
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$wt"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$wt/.cursor"
  printf '%s\n' '{"version":1,"hooks":{"sessionStart":[{"command":"echo keep-me"}]}}' > "$wt/.cursor/hooks.json"
  touch "$home/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor 2>&1) || status=$?
  expect_code 0 "$status" "cursor merge spawn should succeed"
  assert_grep 'keep-me' "$wt/.cursor/hooks.json" "existing Cursor hooks were destroyed"
  assert_grep 'fm-turn-end.sh' "$wt/.cursor/hooks.json" "merged stop hook missing"
  assert_grep 'merged' "$wt/.fm-cursor-turnend" "merge ownership marker missing"
  pass "cursor spawn merges into existing hooks.json"
}

test_cursor_turnend_adapter_encodes_operational_input() {
  local home out
  home="$TMP_ROOT/turnend-home"
  mkdir -p "$home/bin" "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_git_identity fmtest fmtest@example.invalid
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  for f in fm-turnend-guard-cursor.sh fm-turnend-guard.sh fm-operational-input.sh \
    fm-supervision-instructions.sh fm-supervision-lib.sh fm-primary-scope-lib.sh \
    fm-wake-lib.sh fm-harness.sh; do
    cp "$ROOT/bin/$f" "$home/bin/" 2>/dev/null || true
  done
  chmod +x "$home/bin/"*.sh
  # No in-flight tasks -> healthy stop returns {}.
  out=$(printf '%s\n' '{"loop_count":0}' | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$home/bin/fm-turnend-guard-cursor.sh")
  assert_contains "$out" '{}' "healthy cursor stop should return empty object"

  out=$(printf '%s\n' '{"loop_count":1}' | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$home/bin/fm-turnend-guard-cursor.sh")
  assert_contains "$out" '{}' "loop_count>0 must allow stop without follow-up"
  pass "cursor turnend adapter respects healthy stop and loop_count"
}

test_tracked_cursor_hooks_register_primary_adapters() {
  jq -e '.hooks.sessionStart[]?.command | contains("fm-sessionstart-nudge-cursor.sh")' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor sessionStart hook missing"
  jq -e '[.hooks.beforeShellExecution[]?.command] | any(contains("fm-arm-pretool-check.sh") and contains("--cursor"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor beforeShellExecution arm check missing"
  jq -e '[.hooks.beforeShellExecution[]?.command] | any(contains("fm-cd-pretool-check.sh") and contains("--cursor"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor beforeShellExecution cd check missing"
  jq -e '.hooks.stop[]?.command | contains("fm-turnend-guard-cursor.sh")' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor stop hook missing"
  pass "tracked .cursor/hooks.json registers primary adapters"
}

test_fm_harness_detects_cursor_env
test_fm_lock_recognizes_cursor_holder
test_cursor_arm_check_deny_shape
test_cursor_sessionstart_nudge_wrapper
test_cursor_spawn_installs_turnend_hook
test_cursor_spawn_merges_existing_hooks
test_cursor_turnend_adapter_encodes_operational_input
test_tracked_cursor_hooks_register_primary_adapters
