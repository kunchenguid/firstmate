#!/usr/bin/env bash
# Behavior tests for the Cursor primary/crew harness adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

test_fm_harness_detects_cursor_env() {
  local got
  got=$(CURSOR_AGENT=1 CLAUDECODE='' GROK_AGENT='' PI_CODING_AGENT='' "$ROOT/bin/fm-harness.sh")
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
  assert_present "$wt/.cursor/hooks/fm-firstmate-turn-end.sh" "cursor turn-end script missing"
  assert_absent "$wt/.cursor/hooks/fm-turn-end.sh" "legacy cursor turn-end script should not be installed"
  assert_present "$wt/.fm-cursor-turnend" "cursor turn-end ownership marker missing"
  assert_grep 'created' "$wt/.fm-cursor-turnend" "fresh worktree should mark hooks.json as created"
  assert_grep 'fm-firstmate-turn-end.sh' "$wt/.cursor/hooks.json" "hooks.json does not point at owned turn-end script"
  jq -e '
      [.hooks.stop[]?
        | select((.command // "") == ".cursor/hooks/fm-firstmate-turn-end.sh")
        | .loop_limit] == [1]
    ' "$wt/.cursor/hooks.json" >/dev/null \
    || fail "created hooks.json must set loop_limit 1"
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
  assert_grep 'fm-firstmate-turn-end.sh' "$wt/.cursor/hooks.json" "merged stop hook missing"
  jq -e '
      [.hooks.stop[]?
        | select((.command // "") == ".cursor/hooks/fm-firstmate-turn-end.sh")
        | .loop_limit] == [1]
    ' "$wt/.cursor/hooks.json" >/dev/null \
    || fail "merged stop hook must set loop_limit 1"
  assert_grep 'merged' "$wt/.fm-cursor-turnend" "merge ownership marker missing"
  assert_present "$wt/.fm-cursor-hooks.json.bak" "merge should keep a pre-merge hooks backup"
  assert_grep 'keep-me' "$wt/.fm-cursor-hooks.json.bak" "backup should preserve pre-merge hooks"
  pass "cursor spawn merges into existing hooks.json"
}

test_cursor_spawn_reconciles_legacy_hook() {
  local case_dir home proj wt fakebin id out status=0
  case_dir="$TMP_ROOT/spawn-legacy"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="cursor-legacy-x1"
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
  mkdir -p "$wt/.cursor/hooks"
  printf '%s\n' '#!/bin/sh' > "$wt/.cursor/hooks/fm-turn-end.sh"
  chmod +x "$wt/.cursor/hooks/fm-turn-end.sh"
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":".cursor/hooks/fm-turn-end.sh","loop_limit":0}],"sessionStart":[{"command":"echo keep-me"}]}}' \
    > "$wt/.cursor/hooks.json"
  printf 'merged\n' > "$wt/.fm-cursor-turnend"
  touch "$home/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor 2>&1) || status=$?
  expect_code 0 "$status" "legacy reconcile spawn should succeed"
  assert_absent "$wt/.cursor/hooks/fm-turn-end.sh" "legacy script must be removed on respawn"
  assert_present "$wt/.cursor/hooks/fm-firstmate-turn-end.sh" "current owned script must be installed"
  assert_grep 'fm-firstmate-turn-end.sh' "$wt/.cursor/hooks.json" "current stop command missing after reconcile"
  if grep -q 'fm-turn-end.sh"' "$wt/.cursor/hooks.json"; then
    fail "legacy stop command left after reconcile"
  fi
  assert_grep 'keep-me' "$wt/.cursor/hooks.json" "unrelated hooks destroyed during legacy reconcile"
  # Teardown must leave neither generation behind.
  # Extract only the helper bodies; do not pull the production source graph into lint.
  # shellcheck disable=SC1090
  eval "$(sed -n \
    -e '/^cursor_hooks_is_owned_delta()/,/^}/p' \
    -e '/^cursor_unexclude_path()/,/^}/p' \
    -e '/^remove_cursor_turnend()/,/^}/p' \
    "$ROOT/bin/fm-teardown.sh")"
  remove_cursor_turnend "$wt"
  assert_absent "$wt/.cursor/hooks/fm-firstmate-turn-end.sh" "teardown left current script"
  assert_absent "$wt/.cursor/hooks/fm-turn-end.sh" "teardown left legacy script"
  if grep -q 'fm-firstmate-turn-end.sh\|fm-turn-end.sh' "$wt/.cursor/hooks.json" 2>/dev/null; then
    fail "teardown left owned stop commands in hooks.json"
  fi
  assert_grep 'keep-me' "$wt/.cursor/hooks.json" "teardown destroyed unrelated hooks"
  pass "cursor spawn reconciles legacy hook then teardown cleans both generations"
}

test_cursor_teardown_preserves_concurrent_hooks_edit() {
  local case_dir wt excl mode_out
  case_dir="$TMP_ROOT/teardown-concurrent"
  wt="$case_dir/wt"
  mkdir -p "$wt/.cursor/hooks"
  fm_git_identity fmtest fmtest@example.invalid
  git init -q "$wt"
  git -C "$wt" commit -q --allow-empty -m init
  # Track the pre-merge project hooks, then mutate working tree like a merge + concurrent edit.
  printf '%s\n' '{"version":1,"hooks":{"sessionStart":[{"command":"echo keep-me"}]}}' \
    > "$wt/.cursor/hooks.json"
  git -C "$wt" add .cursor/hooks.json
  git -C "$wt" commit -q -m 'project cursor hooks'
  cp "$wt/.cursor/hooks.json" "$wt/.fm-cursor-hooks.json.bak"
  printf '%s\n' '{"version":1,"hooks":{"sessionStart":[{"command":"echo keep-me"},{"command":"echo concurrent-edit"}],"stop":[{"command":".cursor/hooks/fm-firstmate-turn-end.sh","loop_limit":1}]}}' \
    > "$wt/.cursor/hooks.json"
  printf 'merged\n' > "$wt/.fm-cursor-turnend"
  printf '%s\n' '#!/bin/sh' > "$wt/.cursor/hooks/fm-firstmate-turn-end.sh"
  chmod +x "$wt/.cursor/hooks/fm-firstmate-turn-end.sh"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$excl")"
  printf '%s\n' '.cursor/hooks.json' '.cursor/hooks/fm-firstmate-turn-end.sh' >> "$excl"
  # shellcheck disable=SC1090
  eval "$(sed -n \
    -e '/^cursor_hooks_is_owned_delta()/,/^}/p' \
    -e '/^cursor_unexclude_path()/,/^}/p' \
    -e '/^filter_owned_hook_dirtiness()/,/^}/p' \
    -e '/^remove_cursor_turnend()/,/^}/p' \
    "$ROOT/bin/fm-teardown.sh")"
  mode_out=$(git -C "$wt" status --porcelain | filter_owned_hook_dirtiness "$wt")
  assert_contains "$mode_out" '.cursor/hooks.json' \
    "concurrent hooks.json edit must remain dirty under merged mode"
  remove_cursor_turnend "$wt"
  assert_grep 'concurrent-edit' "$wt/.cursor/hooks.json" \
    "merged teardown must not restore bak over concurrent edits"
  assert_grep 'keep-me' "$wt/.cursor/hooks.json" "unrelated hooks lost during concurrent-edit teardown"
  if grep -q 'fm-firstmate-turn-end.sh\|fm-turn-end.sh' "$wt/.cursor/hooks.json" 2>/dev/null; then
    fail "teardown left owned stop commands after concurrent-edit strip"
  fi
  if grep -qxF '.cursor/hooks.json' "$excl" 2>/dev/null; then
    fail "teardown left .cursor/hooks.json in info/exclude"
  fi
  if grep -qxF '.cursor/hooks/fm-firstmate-turn-end.sh' "$excl" 2>/dev/null; then
    fail "teardown left owned turn-end script in info/exclude"
  fi
  pass "cursor merged teardown preserves concurrent hooks.json edits and retires excludes"
}

test_cursor_teardown_restores_owned_delta_backup() {
  local case_dir wt mode_out bak_before restored
  case_dir="$TMP_ROOT/teardown-owned-delta"
  wt="$case_dir/wt"
  mkdir -p "$wt/.cursor/hooks"
  fm_git_identity fmtest fmtest@example.invalid
  git init -q "$wt"
  git -C "$wt" commit -q --allow-empty -m init
  # Track pre-merge project hooks; working tree remains exactly bak + owned stop.
  printf '%s\n' '{"version":1,"hooks":{"sessionStart":[{"command":"echo keep-me"}]}}' \
    > "$wt/.cursor/hooks.json"
  git -C "$wt" add .cursor/hooks.json
  git -C "$wt" commit -q -m 'project cursor hooks'
  cp "$wt/.cursor/hooks.json" "$wt/.fm-cursor-hooks.json.bak"
  bak_before=$(cat "$wt/.fm-cursor-hooks.json.bak")
  printf '%s\n' '{"version":1,"hooks":{"sessionStart":[{"command":"echo keep-me"}],"stop":[{"command":".cursor/hooks/fm-firstmate-turn-end.sh","loop_limit":1}]}}' \
    > "$wt/.cursor/hooks.json"
  printf 'merged\n' > "$wt/.fm-cursor-turnend"
  printf '%s\n' '#!/bin/sh' > "$wt/.cursor/hooks/fm-firstmate-turn-end.sh"
  chmod +x "$wt/.cursor/hooks/fm-firstmate-turn-end.sh"
  # shellcheck disable=SC1090
  eval "$(sed -n \
    -e '/^cursor_hooks_is_owned_delta()/,/^}/p' \
    -e '/^cursor_unexclude_path()/,/^}/p' \
    -e '/^filter_owned_hook_dirtiness()/,/^}/p' \
    -e '/^remove_cursor_turnend()/,/^}/p' \
    "$ROOT/bin/fm-teardown.sh")"
  mode_out=$(git -C "$wt" status --porcelain | filter_owned_hook_dirtiness "$wt")
  if printf '%s\n' "$mode_out" | grep -qF '.cursor/hooks.json'; then
    fail "owned-delta hooks.json dirtiness must be suppressed"
  fi
  remove_cursor_turnend "$wt"
  assert_absent "$wt/.cursor/hooks/fm-firstmate-turn-end.sh" "teardown left owned turn-end script"
  assert_absent "$wt/.fm-cursor-hooks.json.bak" "owned-delta restore should consume bak"
  restored=$(cat "$wt/.cursor/hooks.json")
  [ "$restored" = "$bak_before" ] || fail "teardown must restore exact pre-merge bak content"
  if grep -q 'fm-firstmate-turn-end.sh\|fm-turn-end.sh' "$wt/.cursor/hooks.json" 2>/dev/null; then
    fail "restored hooks.json still contains owned stop"
  fi
  assert_grep 'keep-me' "$wt/.cursor/hooks.json" "bak restore lost unrelated hooks"
  pass "cursor teardown restores owned-delta bak and suppresses dirtiness"
}

test_cursor_spawn_upgrades_owned_stop_loop_limit() {
  local case_dir home proj wt fakebin id out status=0
  case_dir="$TMP_ROOT/spawn-loop-upgrade"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="cursor-loop-up-x1"
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
  mkdir -p "$wt/.cursor"
  # Prior install left owned stop at loop_limit 0; respawn must upgrade to 1.
  printf '%s\n' '{"version":1,"hooks":{"sessionStart":[{"command":"echo keep-me"}],"stop":[{"command":".cursor/hooks/fm-firstmate-turn-end.sh","loop_limit":0}]}}' \
    > "$wt/.cursor/hooks.json"
  touch "$home/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor 2>&1) || status=$?
  expect_code 0 "$status" "loop_limit upgrade spawn should succeed"
  assert_grep 'keep-me' "$wt/.cursor/hooks.json" "unrelated hooks destroyed during loop_limit upgrade"
  assert_grep 'fm-firstmate-turn-end.sh' "$wt/.cursor/hooks.json" "owned stop missing after loop_limit upgrade"
  jq -e '
      [.hooks.stop[]?
        | select((.command // "") == ".cursor/hooks/fm-firstmate-turn-end.sh")
        | .loop_limit] == [1]
    ' "$wt/.cursor/hooks.json" >/dev/null \
    || fail "respawn must upgrade owned stop loop_limit to 1"
  assert_grep 'merged' "$wt/.fm-cursor-turnend" "loop_limit upgrade must keep merged marker"
  assert_present "$wt/.fm-cursor-hooks.json.bak" "loop_limit upgrade should create bak when missing"
  jq -e '
      [.hooks.stop[]?
        | select((.command // "") == ".cursor/hooks/fm-firstmate-turn-end.sh")
        | .loop_limit] == [0]
    ' "$wt/.fm-cursor-hooks.json.bak" >/dev/null \
    || fail "bak must capture pre-upgrade owned stop at loop_limit 0"
  pass "cursor spawn upgrades owned stop loop_limit on respawn"
}

test_cursor_teardown_retires_created_hooks_exclude() {
  local case_dir home proj wt fakebin id out status=0 excl
  case_dir="$TMP_ROOT/teardown-exclude"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="cursor-exclude-x1"
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
  expect_code 0 "$status" "cursor spawn for exclude teardown should succeed"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_grep '.cursor/hooks.json' "$excl" "spawn should exclude created hooks.json for task lifetime"
  # shellcheck disable=SC1090
  eval "$(sed -n \
    -e '/^cursor_hooks_is_owned_delta()/,/^}/p' \
    -e '/^cursor_unexclude_path()/,/^}/p' \
    -e '/^remove_cursor_turnend()/,/^}/p' \
    "$ROOT/bin/fm-teardown.sh")"
  remove_cursor_turnend "$wt"
  if grep -qxF '.cursor/hooks.json' "$excl" 2>/dev/null; then
    fail "teardown left .cursor/hooks.json in info/exclude after created cleanup"
  fi
  pass "cursor teardown retires created hooks.json info/exclude entry"
}

test_cursor_teardown_refuses_staged_created_hooks() {
  local case_dir wt mode_out
  case_dir="$TMP_ROOT/teardown-staged"
  wt="$case_dir/wt"
  mkdir -p "$wt/.cursor/hooks"
  fm_git_identity fmtest fmtest@example.invalid
  git init -q "$wt"
  git -C "$wt" commit -q --allow-empty -m init
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":".cursor/hooks/fm-firstmate-turn-end.sh","loop_limit":1}]}}' \
    > "$wt/.cursor/hooks.json"
  printf 'created\n' > "$wt/.fm-cursor-turnend"
  git -C "$wt" add .cursor/hooks.json
  # shellcheck disable=SC1090
  eval "$(sed -n \
    -e '/^cursor_hooks_is_owned_delta()/,/^}/p' \
    -e '/^filter_owned_hook_dirtiness()/,/^}/p' \
    "$ROOT/bin/fm-teardown.sh")"
  mode_out=$(git -C "$wt" status --porcelain | filter_owned_hook_dirtiness "$wt")
  assert_contains "$mode_out" '.cursor/hooks.json' "staged created hooks.json must remain dirty"
  pass "cursor teardown filter keeps staged created hooks.json"
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
test_cursor_spawn_reconciles_legacy_hook
test_cursor_spawn_upgrades_owned_stop_loop_limit
test_cursor_teardown_preserves_concurrent_hooks_edit
test_cursor_teardown_restores_owned_delta_backup
test_cursor_teardown_retires_created_hooks_exclude
test_cursor_teardown_refuses_staged_created_hooks
test_cursor_turnend_adapter_encodes_operational_input
test_tracked_cursor_hooks_register_primary_adapters
