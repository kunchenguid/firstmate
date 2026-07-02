#!/usr/bin/env bash
set -u

# cursor (cursor-agent) harness-adapter wiring tests, modeled on
# tests/fm-grok-harness.test.sh. Covers: fm-harness.sh self-detection from
# CURSOR_AGENT=1 and from a cursor-agent process name; fm-spawn.sh launch_template
# emitting the verified `cursor-agent --yolo ...` string; and the SHARED
# ~/.cursor/hooks.json merge being idempotent (apply twice -> same content) while
# preserving an unrelated existing (cmux) entry, using Cursor's documented flat
# "command" schema for stop entries.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

# --- fm-harness.sh self-detection -------------------------------------------

test_fm_harness_detects_cursor_env_marker() {
  local out
  # Unset the competing markers (this test process runs inside a claude crewmate,
  # where CLAUDECODE=1 would otherwise win the layer-1 env check first). Real
  # firstmate-on-cursor sets only CURSOR_AGENT=1, never CLAUDECODE.
  out=$(env -u CLAUDECODE -u GROK_AGENT -u PI_CODING_AGENT CURSOR_AGENT=1 "$HARNESS")
  assert_contains "$out" "cursor" "fm-harness did not detect CURSOR_AGENT=1 env marker"
  pass "fm-harness detects cursor via CURSOR_AGENT=1"
}

test_fm_harness_detects_cursor_process_name() {
  # Layer-2 (process-name) detection is exercised through fm-lock.sh's HARNESS_RE,
  # which shares the same basename-matching logic as fm-harness.sh's ancestry walk.
  # Directly testing layer 2 via exec -a is unreliable on macOS (ps -o comm returns
  # the real binary path, not argv[0]), so the deterministic test is fm-lock with a
  # fake ps that reports a cursor-agent process (the captain's actual hit bug).
  local home fakebin out
  home="$TMP_ROOT/harness-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/harness-lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/x/.local/bin/cursor-agent'; exit 0 ;;
  *"args="*) printf '%s\n' 'cursor-agent'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-harness/fm-lock did not recognize cursor-agent process name"
  pass "fm-harness layer-2 process-name arm recognizes cursor-agent"
}

# --- fm-spawn.sh launch_template --------------------------------------------

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
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/.cursor"
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
    HOME="$home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor 2>&1
}

test_spawn_emits_cursor_launch_template() {
  local rec case_dir home proj wt fakebin id out status sendlog
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # The verified launch string is what fm-spawn sends to tmux via send-keys.
  # Point the fake tmux at a log so we can assert the exact cursor-agent command.
  sendlog="$case_dir/sendkeys.log"
  export FM_TEST_SENDLOG="$sendlog"
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
  send-keys) printf '%s\n' "$*" >> "${FM_TEST_SENDLOG:-/dev/null}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"
  assert_present "$sendlog" "tmux send-keys was not invoked by cursor spawn"
  local sent
  sent=$(cat "$sendlog")
  assert_contains "$sent" 'cursor-agent --yolo' "launch_template did not emit 'cursor-agent --yolo'"
  assert_not_contains "$sent" '--prompt' "cursor launch used --prompt instead of a positional prompt"
  pass "cursor launch_template emits verified cursor-agent --yolo command"
}

# --- shared ~/.cursor/hooks.json merge: idempotent + preserves cmux -----------

test_cursor_hook_merge_idempotent_and_preserves_cmux() {
  local rec case_dir home proj wt fakebin id out hooks auth token target
  rec=$(make_spawn_case hooks1)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # Pre-seed the SHARED hooks.json with cmux's own entries (the realistic state).
  # Use Cursor's documented flat schema: each stop (and other hook) entry has a
  # top-level "command" (not a nested {"hooks":[{...}]} wrapper).
  hooks="$home/.cursor/hooks.json"
  printf '%s\n' '{"hooks":{"afterAgentResponse":[{"command":"cmux-after.sh"}],"stop":[{"command":"cmux-stop.sh"}]},"version":1}' > "$hooks"
  cmux_hash=$(jq -S . "$hooks" | shasum)

  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  expect_code 0 $? "cursor spawn with shared hooks.json should succeed"
  token=$(sed -n 's/^token=//p' "$wt/.fm-cursor-turnend")
  [ -n "$token" ] || fail "cursor pointer did not record a token (got empty)"
  auth="$home/.cursor/fm-turn-end.d"
  assert_present "$auth/$token" "cursor auth registry entry was not written"
  assert_present "$auth/fm-turn-end.sh" "cursor guard script was not installed"

  # cmux's afterAgentResponse entry must survive the merge untouched.
  jq -e '.hooks.afterAgentResponse[0].command == "cmux-after.sh"' "$hooks" >/dev/null \
    || fail "cursor merge clobbered cmux's afterAgentResponse entry"
  # cmux's own stop entry must survive; firstmate's stop entry added alongside it.
  jq -e '.hooks.stop | map(select(.command == "cmux-stop.sh")) | length == 1' "$hooks" >/dev/null \
    || fail "cursor merge dropped cmux's stop entry"
  fm_count=$(jq --arg cmd "$auth/fm-turn-end.sh" \
    '.hooks.stop | map(select(.command | test($cmd))) | length' "$hooks")
  [ "$fm_count" = "1" ] || fail "expected exactly one firstmate stop entry, got $fm_count"

  # Re-run the SAME spawn a second time (simulating a respawn or a second task
  # against the same shared hooks.json): must NOT duplicate the firstmate entry
  # and must NOT touch cmux's entries.
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  expect_code 0 $? "second cursor spawn should succeed"
  fm_count2=$(jq --arg cmd "$home/.cursor/fm-turn-end.d/fm-turn-end.sh" \
    '.hooks.stop | map(select(.command | test($cmd))) | length' "$hooks")
  [ "$fm_count2" = "1" ] || fail "second cursor spawn duplicated the firstmate stop entry (got $fm_count2)"
  jq -e '.hooks.afterAgentResponse[0].command == "cmux-after.sh"' "$hooks" >/dev/null \
    || fail "second cursor spawn clobbered cmux's afterAgentResponse"

  # The guard must fire the right target: this task's pointer -> its turn-ended,
  # and must stay silent when no pointer is present (the cmux-session case).
  target="$home/state/$id.turn-ended"
  rm -f "$target"
  CURSOR_WORKSPACE_ROOT="$wt" bash "$auth/fm-turn-end.sh"
  assert_present "$target" "cursor guard did not touch the task turn-ended for a registered pointer"
  # Silent when the pointer is absent (cmux-driven session).
  rm -f "$target" "$wt/.fm-cursor-turnend"
  CURSOR_WORKSPACE_ROOT="$wt" bash "$auth/fm-turn-end.sh"
  assert_absent "$target" "cursor guard fired for a workspace with no firstmate pointer"
  pass "cursor hooks.json merge is idempotent and preserves cmux entries"
}

test_fm_harness_detects_cursor_env_marker
test_fm_harness_detects_cursor_process_name
test_spawn_emits_cursor_launch_template
test_cursor_hook_merge_idempotent_and_preserves_cmux
