#!/usr/bin/env bash
# Behavior tests for the cursor (Cursor Agent CLI) crewmate adapter: harness
# detection, spawn launch shape, secondmate refusal, project-hook busy/turn-end
# wiring, and control-plane interrupt/exit tables.
#
# Live opt-in coverage for the real cursor-agent binary lives in
# tests/fm-cursor-signals-live-e2e.test.sh (FM_CURSOR_SIGNALS_LIVE=1).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
CONTROL_LIB="$ROOT/bin/fm-control-lib.sh"
BUSY_LIB="$ROOT/bin/fm-busy-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

# shellcheck source=bin/fm-control-lib.sh
. "$CONTROL_LIB"
# shellcheck source=bin/fm-busy-lib.sh
. "$BUSY_LIB"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' zsh; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ -z "${FM_FAKE_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_WINDOW"; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        if [ "${FM_FAKE_LAUNCH_FAIL:-0}" = 1 ] && [[ "$arg" = *cursor-agent* ]]; then
          if [ "${FM_FAKE_CURSOR_RESTORE_FAIL:-0}" = 1 ]; then
            rm -f -- "$FM_FAKE_PANE_PATH/.cursor/hooks/fm-busy-turnend.sh"
            ln -s "$FM_FAKE_PANE_PATH/unsafe-hook" \
              "$FM_FAKE_PANE_PATH/.cursor/hooks/fm-busy-turnend.sh"
          fi
          exit 70
        fi
        bash -c "$arg"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
set -u
printf 'arg=%s\n' "$@" >> "$FM_FAKE_CURSOR_ARGS_LOG"
printf 'cursor_agent=%s\n' "${CURSOR_AGENT:-}" >> "$FM_FAKE_CURSOR_ARGS_LOG"
printf 'claudecode=%s\n' "${CLAUDECODE:-}" >> "$FM_FAKE_CURSOR_ARGS_LOG"
printf 'pi_coding_agent=%s\n' "${PI_CODING_AGENT:-}" >> "$FM_FAKE_CURSOR_ARGS_LOG"
printf 'grok_agent=%s\n' "${GROK_AGENT:-}" >> "$FM_FAKE_CURSOR_ARGS_LOG"
printf 'fm_pi_harness=%s\n' "${FM_PI_HARNESS:-}" >> "$FM_FAKE_CURSOR_ARGS_LOG"
exit 0
SH
  chmod +x "$fakebin/cursor-agent"
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

publish_spawn_fixture() {
  local proj=$1 wt=$2 default status
  status=$(git -C "$wt" status --porcelain)
  [ -n "$status" ] || return 0
  default=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$wt" add -A
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm fixture
  git -C "$wt" push -q origin "HEAD:refs/heads/$default"
}

run_cursor_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  publish_spawn_fixture "$proj" "$wt"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_CURSOR_ARGS_LOG="$home/cursor-agent.log" \
    PATH="$fakebin:${FM_CURSOR_TEST_PATH:-$PATH}" \
    "$SPAWN" "$id" "$proj" cursor "$@" 2>&1
}

run_raw_cursor_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_CURSOR_ARGS_LOG="$home/cursor-agent.log" \
    PATH="$fakebin:${FM_CURSOR_TEST_PATH:-$PATH}" \
    "$SPAWN" "$id" "$proj" 'cursor-agent --yolo --trust raw-brief' "$@" 2>&1
}

make_path_without_python3() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-python3" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout touch tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

run_cursor_relaunch() {  # <home> <wt> <fakebin> <id>
  local home=$1 wt=$2 fakebin=$3 id=$4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_CURSOR_ARGS_LOG="$home/cursor-agent.log" \
    FM_FAKE_WINDOW="fm-$id" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1
}

test_cursor_marker_does_not_override_non_cursor_ancestry() {
  local dir bin out
  dir="$TMP_ROOT/contaminated-cursor-marker"
  mkdir -p "$dir"
  for bin in codex opencode kimi; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(CURSOR_AGENT=1 env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" = "$bin" ] \
      || fail "CURSOR_AGENT=1 contaminated $bin ancestry as '$out'"
  done
  pass "inherited Cursor marker cannot override non-Cursor ancestry"
}

test_static_crew_harness_resolution() {
  local home="$TMP_ROOT/static-crew-resolution" out
  mkdir -p "$home/config"
  printf '%s\n' cursor > "$home/config/crew-harness"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$HARNESS" crew)
  [ "$out" = cursor ] || fail "config/crew-harness=cursor resolved to '$out'"
  pass "cursor resolves through the public static crew harness interface"
}

test_detects_exact_cursor_agent_ancestor() {
  local dir out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/cursor-agent"
  out=$(env -u CURSOR_AGENT -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    "$dir/cursor-agent" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = cursor ] || fail "fm-harness.sh under process cursor-agent reported '$out'"
  pass "cursor is detected through exact cursor-agent ancestry"
}

test_detects_cursor_node_wrapper_argv0() {
  local dir="$TMP_ROOT/detect-node-wrapper" node out
  node=$(command -v node) || fail "node is required for Cursor wrapper detection"
  mkdir -p "$dir/bin"
  cat > "$dir/probe.js" <<'JS'
const { spawnSync } = require("node:child_process");
const result = spawnSync(process.env.FM_TEST_HARNESS, [], {
  encoding: "utf8",
  env: process.env,
});
process.stdout.write(result.stdout || "");
process.stderr.write(result.stderr || "");
process.exit(result.status === null ? 1 : result.status);
JS
  out=$(env -u CURSOR_AGENT -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_TEST_HARNESS="$HARNESS" bash -c 'exec -a "$1" "$2" "$3"' \
    _ "$dir/bin/cursor-agent" "$node" "$dir/probe.js")
  [ "$out" = cursor ] \
    || fail "full-path cursor-agent argv0 under Node reported '$out'"
  pass "cursor is detected through the real Node wrapper process shape"
}

test_detection_is_anchored() {
  local dir bin out session
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  command -v tmux >/dev/null 2>&1 || {
    echo "skip: tmux required to isolate ancestry from an outer cursor-agent parent"
    return 0
  }
  session="fm-cursor-detect-$$"
  tmux kill-session -t "$session" 2>/dev/null || true
  for bin in cursor cursor-ide not-cursor-agent; do
    cp "$(command -v bash)" "$dir/$bin"
    tmux new-session -d -s "$session" -c "$dir" -- \
      env -u CURSOR_AGENT -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\" > \"$dir/out-$bin\""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -f "$dir/out-$bin" ] && break
      sleep 0.1
    done
    tmux kill-session -t "$session" 2>/dev/null || true
    out=$(cat "$dir/out-$bin" 2>/dev/null || true)
    [ "$out" != cursor ] || fail "fm-harness.sh misdetected unrelated process '$bin' as cursor (got '$out')"
  done
  pass "cursor detection does not claim unrelated cursor-containing commands"
}

test_spawn_launch_shape() {
  local rec case_dir home proj wt fakebin id out status trusted hook_out mode
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor"
  printf '%s\n' '{"version":1,"hooks":{"beforeSubmitPrompt":[{"command":"user-before"}],"stop":[{"command":"user-stop"}],"custom":[{"command":"keep"}]}}' > "$wt/.cursor/hooks.json"
  chmod 600 "$wt/.cursor/hooks.json"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --model composer-2.5-fast --effort low)
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"

  python3 - "$home/cursor-agent.log" <<'PY' || fail "fake cursor-agent did not observe the expected launch contract"
import sys
args = open(sys.argv[1]).read().splitlines()
for item in ("arg=--yolo", "arg=--trust", "arg=--model", "arg=composer-2.5-fast"):
    assert item in args, (item, args)
assert "cursor_agent=" in args, args
assert any(item.startswith("arg=\u2063FIRSTMATE_OP: v1 launch-brief:") for item in args), args
assert "arg=--effort" not in args, args
assert "arg=reasoning-effort" not in args, args
PY
  assert_grep 'harness=cursor' "$home/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'effort=low' "$home/state/$id.meta" "requested effort was not retained in meta"
  assert_grep 'model=composer-2.5-fast' "$home/state/$id.meta" "model was not recorded in meta"

  assert_present "$wt/.cursor/hooks.json" "cursor spawn did not write project hooks.json"
  assert_present "$wt/.cursor/hooks/fm-busy-turnend.sh" "cursor spawn did not write busy/turnend hook"
  mode=$(file_mode "$wt/.cursor/hooks.json")
  [ "$mode" = 600 ] || fail "cursor spawn changed hooks.json mode 0600 to $mode"
  [ -x "$wt/.cursor/hooks/fm-busy-turnend.sh" ] \
    || fail "cursor busy/turnend hook must be executable"
  git -C "$wt" check-ignore -q -- .cursor/hooks.json \
    && fail "cursor spawn permanently ignored the user-owned hooks.json"
  git -C "$wt" check-ignore -q -- .cursor/hooks/fm-busy-turnend.sh \
    && fail "cursor spawn permanently ignored its generated hook script"
  python3 - "$wt/.cursor/hooks.json" <<'PY' || fail "cursor hooks JSON does not expose the required events"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
assert hooks["beforeSubmitPrompt"][0]["command"] == "user-before", hooks
assert hooks["stop"][0]["command"] == "user-stop", hooks
assert hooks["custom"][0]["command"] == "keep", hooks
assert hooks["beforeSubmitPrompt"][-1]["command"].endswith("fm-busy-turnend.sh busy"), hooks
assert hooks["stop"][-1]["command"].endswith("fm-busy-turnend.sh idle-stop"), hooks
assert hooks["sessionEnd"][-1]["command"].endswith("fm-busy-turnend.sh idle-session-end"), hooks
PY

  trusted=$(fm_busy_sources_for_harness cursor)
  case " $trusted " in
    *" cursor-hook "*) ;;
    *) fail "cursor must trust cursor-hook, got '$trusted'" ;;
  esac
  [ -z "$(fm_busy_sources_for_harness cursor-ide)" ] \
    || fail "unverified cursor-ide must not trust cursor-hook busy events"
  [ -f "$home/state/$id.busy-gen" ] \
    || fail "cursor spawn must arm a busy generation"
  hook_out=$(printf '%s\n' '{"hook_event_name":"stop","status":"completed"}' \
    | "$wt/.cursor/hooks/fm-busy-turnend.sh" idle-stop)
  [ "$hook_out" = '{}' ] || fail "cursor stop hook did not emit an empty response object"
  [ "$(fm_busy_classify tmux "fm-$id" cursor "$id" "$home/state")" = 'idle cursor-hook' ] \
    || fail "cursor stop hook did not persist idle cursor-hook state"
  assert_present "$home/state/$id.turn-ended" \
    "cursor stop hook did not persist the turn-ended marker"
  rm -f "$home/state/$id.turn-ended"
  hook_out=$(printf '%s\n' '{"hook_event_name":"beforeSubmitPrompt","prompt":"next turn"}' \
    | "$wt/.cursor/hooks/fm-busy-turnend.sh" busy)
  [ "$hook_out" = '{}' ] || fail "cursor busy hook did not emit an empty response object"
  [ "$(fm_busy_classify tmux "fm-$id" cursor "$id" "$home/state")" = 'busy cursor-hook' ] \
    || fail "cursor busy hook did not persist busy cursor-hook state"
  assert_absent "$home/state/$id.turn-ended" \
    "cursor busy hook wrote a turn-ended marker"
  pass "cursor spawn launches with yolo+trust, omits effort flags, and wires project hooks"
}

test_raw_cursor_binary_uses_verified_adapter() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case raw-binary)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(CLAUDECODE=claude PI_CODING_AGENT=pi GROK_AGENT=grok \
    FM_PI_HARNESS=pi-signed CURSOR_AGENT=cursor \
    run_raw_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode local-only --yolo on)
  status=$?
  expect_code 0 "$status" "raw cursor-agent spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=cursor" \
    "raw cursor-agent was not normalized to the verified adapter"
  assert_grep 'harness=cursor' "$home/state/$id.meta" \
    "raw cursor-agent did not record the canonical harness family"
  assert_present "$home/state/$id.cursor-hooks.json.installed" \
    "raw cursor-agent did not establish hook transaction ownership"
  assert_present "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    "raw cursor-agent did not install supervision hooks"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "$fakebin/cursor-agent" \
    "raw cursor-agent did not resolve the verified executable"
  python3 - "$home/cursor-agent.log" <<'PY' || fail "raw cursor-agent did not inherit verified launch invariants"
import sys

observed = open(sys.argv[1], encoding="utf-8").read().splitlines()
for marker in (
    "cursor_agent=",
    "claudecode=",
    "pi_coding_agent=",
    "grok_agent=",
    "fm_pi_harness=",
):
    assert marker in observed, (marker, observed)
assert "arg=raw-brief" not in observed, observed
assert any(
    item.startswith("arg=\u2063FIRSTMATE_OP: v1 launch-brief: brief")
    for item in observed
), observed
PY
  fm_control_cursor_hooks_restore "$wt" "$home/state" "$id" \
    || fail "raw cursor-agent hook transaction could not be restored"
  fm_control_cursor_hooks_restore "$wt" "$home/state" "$id" \
    || fail "raw cursor-agent hook restoration was not retry-safe"
  assert_absent "$wt/.cursor/hooks.json" \
    "raw cursor-agent restoration left generated hooks.json"
  assert_absent "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    "raw cursor-agent restoration left the generated hook script"
  fm_control_cursor_hooks_forget "$home/state" "$id"
  pass "raw cursor-agent uses the verified Cursor adapter lifecycle"
}

test_spawn_refuses_secondmate() {
  local case_dir home fakebin id raw_id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="cursor-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" cursor --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "cursor was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" \
    "cursor secondmate refusal did not explain the boundary"
  raw_id="cursor-raw-secondmate-x1"
  mkdir -p "$home/data/$raw_id"
  printf 'charter\n' > "$home/data/$raw_id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$raw_id" 'cursor-agent --yolo --trust raw-charter' --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "raw cursor-agent was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" \
    "raw cursor-agent secondmate refusal did not explain the boundary"
  fm_control_harness_supports_kind cursor secondmate \
    && fail "control plane must also refuse cursor secondmate"
  pass "cursor is refused as a secondmate harness"
}

test_control_tables() {
  [ "$(fm_control_interrupt_key cursor)" = C-c ] \
    || fail "cursor interrupt must be C-c"
  [ "$(fm_control_interrupt_repeat cursor)" = 1 ] \
    || fail "cursor interrupt repeat must be 1"
  [ -z "$(fm_control_interrupt_clear_key cursor || true)" ] \
    || fail "cursor must not need composer clear after interrupt"
  [ "$(fm_control_exit_command cursor)" = /exit ] \
    || fail "cursor exit must be /exit"
  [ "$(fm_control_harness_family cursor-agent)" = cursor ] \
    || fail "cursor-agent basename must resolve to cursor family"
  pass "cursor control-plane interrupt/exit tables"
}

test_cursor_composer_placeholder_requires_cursor_glyph() {
  local caps plain_placeholder cursor_placeholder
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  caps=$'styled=1\ncursor=1\nidentity=1\nrows=0'
  plain_placeholder=$'╭────────────────────╮\n│ Add a follow-up    │\n╰────────────────────╯'
  cursor_placeholder=$'╭────────────────────╮\n│ → Add a follow-up  │\n╰────────────────────╯'
  [ "$(fm_composer_classify_screen "$caps" "$plain_placeholder" 1)" = pending ] \
    || fail "ordinary Add a follow-up text was treated as an empty composer"
  [ "$(FM_COMPOSER_IDLE_RE='^(Type a message\.\.\.|Add a follow-up)$' \
    fm_composer_classify_screen "$caps" "$cursor_placeholder" 1)" = empty ] \
    || fail "Cursor's idle Add a follow-up placeholder was not recognized"
  [ "$(fm_composer_classify_screen "$caps" '→' 0)" = unknown ] \
    || fail "bare Cursor arrow weakened dead-shell injection safety"
  pass "cursor placeholder classification requires the prompt glyph"
}

test_cursor_spawn_refuses_existing_hook_target_collision() {
  local rec case_dir home proj wt fakebin id out status expected_hooks expected_script
  rec=$(make_spawn_case hook-target-collision)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor/hooks"
  printf '%s\n' '{"version":1,"hooks":{"beforeSubmitPrompt":[{"command":".cursor/hooks/fm-busy-turnend.sh user"}]}}' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'pre-existing user hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  expected_hooks="$case_dir/expected-hooks.json"
  expected_script="$case_dir/expected-hook.sh"
  cp "$wt/.cursor/hooks.json" "$expected_hooks"
  cp "$wt/.cursor/hooks/fm-busy-turnend.sh" "$expected_script"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Cursor spawn replaced an existing hook target"
  assert_contains "$out" "existing beforeSubmitPrompt hook targets .cursor/hooks/fm-busy-turnend.sh" \
    "Cursor hook-target collision refusal was not explicit"
  cmp -s "$expected_hooks" "$wt/.cursor/hooks.json" \
    || fail "Cursor hook-target collision modified hooks.json"
  cmp -s "$expected_script" "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    || fail "Cursor hook-target collision replaced the user hook script"
  assert_absent "$home/state/$id.cursor-hooks.json" \
    "Cursor hook-target collision claimed transaction ownership"
  assert_absent "$home/state/$id.cursor-hooks.json.installed" \
    "Cursor hook-target collision recorded an installed snapshot"
  assert_absent "$home/state/$id.busy-gen" \
    "Cursor hook-target collision left busy state armed"
  assert_absent "$home/launch.log" \
    "Cursor hook-target collision launched the harness"
  pass "Cursor spawn refuses an existing Firstmate hook-script target"
}

test_cursor_hooks_restore_existing_files() {
  local dir="$TMP_ROOT/restore-hooks" wt="$TMP_ROOT/restore-hooks/wt" state="$TMP_ROOT/restore-hooks/state"
  mkdir -p "$wt/.cursor/hooks" "$state"
  printf '%s\n' '{"hooks":{"user":[{"command":"keep"}]}}' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'user hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  printf '%s\n' 'user hook' > "$dir/expected-hook"
  fm_control_cursor_hooks_backup "$wt" "$state" restore
  printf '%s\n' 'firstmate hook' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'firstmate script' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  fm_control_cursor_hooks_record_installed "$wt" "$state" restore \
    "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"
  fm_control_cursor_hooks_restore "$wt" "$state" restore
  assert_present "$state/restore.cursor-hooks.json.installed" \
    "Cursor restore discarded ownership needed by a later retry"
  fm_control_cursor_hooks_restore "$wt" "$state" restore
  python3 - "$wt/.cursor/hooks.json" <<'PY' || fail "existing Cursor hooks.json was not restored semantically"
import json, sys
assert json.load(open(sys.argv[1]))["hooks"]["user"][0]["command"] == "keep"
PY
  cmp -s "$dir/expected-hook" "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    || fail "existing Cursor hook script content was not restored exactly"
  pass "Cursor wiring restores pre-existing hook files"
}

test_cursor_hook_restore_preserves_user_hook_edits() {
  local dir="$TMP_ROOT/preserve-hook-edits" wt="$TMP_ROOT/preserve-hook-edits/wt" state="$TMP_ROOT/preserve-hook-edits/state"
  mkdir -p "$wt/.cursor/hooks" "$state"
  printf '%s\n' '{"version":1,"hooks":{"user":[{"command":"keep"}],"beforeSubmitPrompt":[{"command":".cursor/hooks/fm-busy-turnend.sh busy","matcher":"user-before"}]}}' > "$wt/.cursor/hooks.json"
  fm_control_cursor_hooks_backup "$wt" "$state" preserve
  python3 - "$wt/.cursor/hooks.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
for event, command in (
    ("beforeSubmitPrompt", ".cursor/hooks/fm-busy-turnend.sh busy"),
    ("stop", ".cursor/hooks/fm-busy-turnend.sh idle-stop"),
    ("sessionEnd", ".cursor/hooks/fm-busy-turnend.sh idle-session-end"),
):
    document["hooks"].setdefault(event, []).append({"command": command})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, separators=(",", ":"))
    handle.write("\n")
PY
  printf '%s\n' 'firstmate script' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  fm_control_cursor_hooks_record_installed "$wt" "$state" preserve \
    "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"
  python3 - "$wt/.cursor/hooks.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["hooks"]["user"].append({"command": "user-later"})
entries = document["hooks"]["beforeSubmitPrompt"]
entries.insert(0, entries.pop())
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, separators=(",", ":"))
    handle.write("\n")
PY
  fm_control_cursor_hooks_restore "$wt" "$state" preserve
  python3 - "$wt/.cursor/hooks.json" <<'PY' || fail "Cursor hook restore discarded a non-Firstmate edit"
import json
import sys

hooks = json.load(open(sys.argv[1]))["hooks"]
assert hooks["user"] == [{"command": "keep"}, {"command": "user-later"}], hooks
assert hooks["beforeSubmitPrompt"] == [
    {"command": ".cursor/hooks/fm-busy-turnend.sh busy", "matcher": "user-before"}
], hooks
for event in ("stop", "sessionEnd"):
    assert hooks[event] == [], hooks
PY
  assert_absent "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    "Cursor hook restore left its generated script after preserving user edits"
  pass "Cursor hook restoration preserves user edits while removing Firstmate entries"
}

test_cursor_hook_restore_refuses_edited_generated_entry() {
  local wt="$TMP_ROOT/refuse-edited-hook/wt" state="$TMP_ROOT/refuse-edited-hook/state"
  local expected="$TMP_ROOT/refuse-edited-hook/expected.json"
  mkdir -p "$wt/.cursor/hooks" "$state"
  printf '%s\n' '{"version":1,"hooks":{}}' > "$wt/.cursor/hooks.json"
  fm_control_cursor_hooks_backup "$wt" "$state" edited
  python3 - "$wt/.cursor/hooks.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
for event, command in (
    ("beforeSubmitPrompt", ".cursor/hooks/fm-busy-turnend.sh busy"),
    ("stop", ".cursor/hooks/fm-busy-turnend.sh idle-stop"),
    ("sessionEnd", ".cursor/hooks/fm-busy-turnend.sh idle-session-end"),
):
    document["hooks"][event] = [{"command": command}]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, separators=(",", ":"))
    handle.write("\n")
PY
  printf '%s\n' 'firstmate script' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  fm_control_cursor_hooks_record_installed "$wt" "$state" edited \
    "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"
  python3 - "$wt/.cursor/hooks.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["hooks"]["beforeSubmitPrompt"][0]["matcher"] = "edited-during-task"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, separators=(",", ":"))
    handle.write("\n")
PY
  cp "$wt/.cursor/hooks.json" "$expected"
  if fm_control_cursor_hooks_restore "$wt" "$state" edited; then
    fail "Cursor restore accepted an edited generated hook entry"
  fi
  cmp -s "$expected" "$wt/.cursor/hooks.json" \
    || fail "failed Cursor reconciliation partially rewrote hooks.json"
  assert_present "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    "failed Cursor reconciliation removed the installed hook script"
  assert_present "$state/edited.cursor-hooks.json.installed" \
    "failed Cursor reconciliation discarded recovery ownership"
  python3 - "$wt/.cursor/hooks.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["hooks"]["beforeSubmitPrompt"][0] = {
    "command": ".cursor/hooks/fm-busy-turnend.sh busy && printf stale"
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, separators=(",", ":"))
    handle.write("\n")
PY
  cp "$wt/.cursor/hooks.json" "$expected"
  if fm_control_cursor_hooks_restore "$wt" "$state" edited; then
    fail "Cursor restore accepted edited generated command text"
  fi
  cmp -s "$expected" "$wt/.cursor/hooks.json" \
    || fail "failed command reconciliation partially rewrote hooks.json"
  assert_present "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    "failed command reconciliation removed the installed hook script"
  assert_present "$state/edited.cursor-hooks.json.installed" \
    "failed command reconciliation discarded recovery ownership"
  python3 - "$wt/.cursor/hooks.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["hooks"]["beforeSubmitPrompt"][0] = {
    "command": ".cursor/hooks/../hooks/fm-busy-turnend.sh busy"
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, separators=(",", ":"))
    handle.write("\n")
PY
  cp "$wt/.cursor/hooks.json" "$expected"
  if fm_control_cursor_hooks_restore "$wt" "$state" edited; then
    fail "Cursor restore accepted an equivalent generated hook path"
  fi
  cmp -s "$expected" "$wt/.cursor/hooks.json" \
    || fail "failed equivalent-path reconciliation partially rewrote hooks.json"
  assert_present "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    "failed equivalent-path reconciliation removed the installed hook script"
  assert_present "$state/edited.cursor-hooks.json.installed" \
    "failed equivalent-path reconciliation discarded recovery ownership"
  pass "Cursor restore fails closed on edited generated hook targets"
}

test_cursor_hook_backup_is_atomic() {
  local rec case_dir home proj wt fakebin id out status expected_hooks
  rec=$(make_spawn_case atomic-backup)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor/hooks"
  printf '%s\n' '{"version":1,"hooks":{"beforeSubmitPrompt":[{"command":"user-before"}]}}' > "$wt/.cursor/hooks.json"
  expected_hooks="$case_dir/expected-hooks.json"
  cp "$wt/.cursor/hooks.json" "$expected_hooks"
  ln -s "$case_dir/unsafe-hook" "$wt/.cursor/hooks/fm-busy-turnend.sh"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unsafe Cursor hook script was accepted"
  assert_absent "$home/state/$id.cursor-hooks.json" \
    "failed Cursor backup left a partial hooks.json sidecar"
  assert_absent "$home/state/$id.cursor-fm-busy-turnend.sh" \
    "failed Cursor backup left a partial hook-script sidecar"
  assert_absent "$home/state/$id.busy-gen" \
    "failed Cursor backup left its busy generation armed"
  cmp -s "$expected_hooks" "$wt/.cursor/hooks.json" \
    || fail "failed Cursor backup modified pre-existing matching user hooks"
  [ -L "$wt/.cursor/hooks/fm-busy-turnend.sh" ] \
    || fail "failed Cursor backup modified the unsafe user hook path"
  pass "Cursor hook backup validates atomically and abort cleanup retires busy state"
}

test_spawn_abort_retains_cursor_backups_when_restore_fails() {
  local rec case_dir home proj wt fakebin id out status expected_hooks expected_script
  rec=$(make_spawn_case failed-restore)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor/hooks"
  printf '%s\n' '{"version":1,"hooks":{"user":[{"command":"keep"}]}}' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'user hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  expected_hooks="$case_dir/expected-hooks.json"
  expected_script="$case_dir/expected-hook.sh"
  cp "$wt/.cursor/hooks.json" "$expected_hooks"
  cp "$wt/.cursor/hooks/fm-busy-turnend.sh" "$expected_script"
  out=$(FM_FAKE_LAUNCH_FAIL=1 FM_FAKE_CURSOR_RESTORE_FAIL=1 \
    run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn restore-failure injection unexpectedly succeeded"
  cmp -s "$expected_hooks" "$home/state/$id.cursor-hooks.json" \
    || fail "failed restore discarded the original hooks.json backup"
  cmp -s "$expected_script" "$home/state/$id.cursor-fm-busy-turnend.sh" \
    || fail "failed restore discarded the original hook-script backup"
  assert_present "$home/state/$id.cursor-hooks.json.installed" \
    "failed restore discarded the installed hooks snapshot"
  assert_present "$home/state/$id.cursor-fm-busy-turnend.sh.installed" \
    "failed restore discarded the installed hook-script snapshot"
  assert_absent "$home/state/$id.busy-gen" \
    "failed restore left its busy generation armed"
  [ -L "$wt/.cursor/hooks/fm-busy-turnend.sh" ] \
    || fail "restore-failure injection did not leave the unsafe path in place"
  pass "aborted Cursor spawn retains recovery sidecars when restoration fails"
}

test_same_cursor_relaunch_refuses_divergent_hook_script() {
  local rec case_dir home proj wt fakebin id out status expected_script expected_live
  rec=$(make_spawn_case cursor-relaunch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor/hooks"
  printf '%s\n' '{"version":1,"hooks":{}}' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'pre-existing user hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  expected_script="$case_dir/expected-hook.sh"
  cp "$wt/.cursor/hooks/fm-busy-turnend.sh" "$expected_script"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "initial Cursor spawn should succeed: $out"
  git -C "$wt" check-ignore -q -- .cursor/hooks/fm-busy-turnend.sh \
    && fail "cursor spawn ignored a pre-existing user hook script"
  printf '%s\n' 'divergent live hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  expected_live="$case_dir/expected-live-hook.sh"
  cp "$wt/.cursor/hooks/fm-busy-turnend.sh" "$expected_live"
  out=$(run_cursor_relaunch "$home" "$wt" "$fakebin" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "same-Cursor relaunch overwrote a divergent hook script"
  assert_contains "$out" "could not retire cursor wiring" \
    "same-Cursor relaunch did not report its fail-closed refusal"
  cmp -s "$expected_live" "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    || fail "same-Cursor relaunch overwrote the divergent live hook script"
  cmp -s "$expected_script" "$home/state/$id.cursor-fm-busy-turnend.sh" \
    || fail "same-Cursor relaunch overwrote the pre-existing hook-script backup"
  pass "same-Cursor relaunch refuses a divergent installed hook script"
}

test_failed_same_cursor_relaunch_remains_retryable() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case cursor-relaunch-retry)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor/hooks"
  printf '%s\n' '{"version":1,"hooks":{"user":[{"command":"keep"}]}}' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'pre-existing user hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "initial Cursor spawn should succeed: $out"

  out=$(FM_FAKE_LAUNCH_FAIL=1 run_cursor_relaunch "$home" "$wt" "$fakebin" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "same-Cursor relaunch failure injection unexpectedly succeeded"
  assert_present "$home/state/$id.cursor-hooks.json.installed" \
    "failed same-Cursor relaunch discarded retry ownership"
  assert_present "$home/state/$id.cursor-fm-busy-turnend.sh.installed" \
    "failed same-Cursor relaunch discarded the script snapshot"

  out=$(run_cursor_relaunch "$home" "$wt" "$fakebin" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "same-Cursor relaunch retry should succeed: $out"
  assert_present "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    "same-Cursor relaunch retry did not install replacement wiring"
  pass "failed same-Cursor relaunch retains ownership for retry"
}

test_cursor_restore_recreates_removed_preexisting_hook_script() {
  local dir="$TMP_ROOT/restore-removed-script" wt="$TMP_ROOT/restore-removed-script/wt"
  local state="$TMP_ROOT/restore-removed-script/state"
  mkdir -p "$wt/.cursor/hooks" "$state"
  printf '%s\n' '{"version":1,"hooks":{}}' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'pre-existing user hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  printf '%s\n' 'pre-existing user hook' > "$dir/expected-hook.sh"
  fm_control_cursor_hooks_backup "$wt" "$state" removed
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":".cursor/hooks/fm-busy-turnend.sh idle-stop"}]}}' \
    > "$wt/.cursor/hooks.json"
  printf '%s\n' 'firstmate generated hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  fm_control_cursor_hooks_record_installed "$wt" "$state" removed \
    "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"
  rm -f "$wt/.cursor/hooks/fm-busy-turnend.sh"
  fm_control_cursor_hooks_restore "$wt" "$state" removed
  cmp -s "$dir/expected-hook.sh" "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    || fail "Cursor restore did not recreate the removed pre-existing hook script"
  pass "Cursor restoration recreates a removed pre-existing hook script"
}

test_spawn_abort_preserves_cursor_recovery_for_durable_task() {
  local rec case_dir home proj wt fakebin id out status expected_hooks expected_script
  rec=$(make_spawn_case abort-hooks)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor/hooks"
  printf '%s\n' '{"version":1,"hooks":{"user":[{"command":"keep"}]}}' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'user hook' > "$wt/.cursor/hooks/fm-busy-turnend.sh"
  expected_hooks="$case_dir/expected-hooks.json"
  expected_script="$case_dir/expected-hook.sh"
  cp "$wt/.cursor/hooks.json" "$expected_hooks"
  cp "$wt/.cursor/hooks/fm-busy-turnend.sh" "$expected_script"
  out=$(FM_FAKE_LAUNCH_FAIL=1 run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn failure injection unexpectedly succeeded"
  cmp -s "$expected_hooks" "$wt/.cursor/hooks.json" \
    || fail "aborted Cursor spawn did not restore hooks.json"
  cmp -s "$expected_script" "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    || fail "aborted Cursor spawn did not restore the pre-existing hook script"
  assert_absent "$home/state/$id.busy-gen" \
    "aborted Cursor spawn left its busy generation armed"
  assert_present "$home/state/$id.meta" \
    "aborted Cursor spawn did not leave its durable task record"
  assert_present "$home/state/$id.cursor-hooks.json.installed" \
    "aborted Cursor spawn discarded recovery needed by its durable task"
  assert_present "$home/state/$id.cursor-fm-busy-turnend.sh.installed" \
    "aborted Cursor spawn discarded its generated-script snapshot"
  out=$(run_cursor_relaunch "$home" "$wt" "$fakebin" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "durable Cursor task could not relaunch after spawn abort: $out"
  assert_present "$wt/.cursor/hooks/fm-busy-turnend.sh" \
    "Cursor relaunch did not re-arm the retained hook transaction"
  pass "aborted Cursor spawn retains recovery for its durable task"
}

test_spawn_retry_preserves_preexisting_cursor_recovery() {
  local rec case_dir home proj wt fakebin id out status expected
  rec=$(make_spawn_case preexisting-recovery)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor/hooks"
  printf '%s\n' '{"version":1,"hooks":{}}' > "$wt/.cursor/hooks.json"
  printf '%s\n' 'original hooks recovery' > "$home/state/$id.cursor-hooks.json"
  printf '%s\n' 'original script recovery' > "$home/state/$id.cursor-fm-busy-turnend.sh"
  printf '%s\n' 'installed hooks recovery' > "$home/state/$id.cursor-hooks.json.installed"
  printf '%s\n' 'installed script recovery' > "$home/state/$id.cursor-fm-busy-turnend.sh.installed"
  expected="$case_dir/expected-state"
  mkdir -p "$expected"
  cp "$home/state/$id.cursor-hooks.json" "$expected/hooks"
  cp "$home/state/$id.cursor-fm-busy-turnend.sh" "$expected/script"
  cp "$home/state/$id.cursor-hooks.json.installed" "$expected/hooks-installed"
  cp "$home/state/$id.cursor-fm-busy-turnend.sh.installed" "$expected/script-installed"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn retry unexpectedly replaced pre-existing recovery"
  cmp -s "$expected/hooks" "$home/state/$id.cursor-hooks.json" \
    || fail "spawn retry replaced the retained hooks backup"
  cmp -s "$expected/script" "$home/state/$id.cursor-fm-busy-turnend.sh" \
    || fail "spawn retry replaced the retained script backup"
  cmp -s "$expected/hooks-installed" "$home/state/$id.cursor-hooks.json.installed" \
    || fail "spawn retry deleted the retained installed hooks snapshot"
  cmp -s "$expected/script-installed" "$home/state/$id.cursor-fm-busy-turnend.sh.installed" \
    || fail "spawn retry deleted the retained installed script snapshot"
  assert_absent "$home/state/$id.busy-gen" \
    "refused spawn retry left its busy generation armed"
  pass "Cursor spawn retry preserves recovery it does not own"
}

test_cursor_hooks_reject_parent_symlinks() {
  local dir="$TMP_ROOT/reject-hook-symlink" wt="$TMP_ROOT/reject-hook-symlink/wt" state="$TMP_ROOT/reject-hook-symlink/state"
  mkdir -p "$wt" "$state" "$dir/real-cursor"
  ln -s "$dir/real-cursor" "$wt/.cursor"
  fm_control_cursor_hooks_backup "$wt" "$state" symlink \
    && fail "Cursor hook backup followed a symlinked .cursor directory"
  pass "Cursor hook setup rejects symlinked parent directories"
}

test_cursor_malformed_hooks_fail_before_writing() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case malformed)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.cursor"
  printf '%s\n' '{not-json' > "$wt/.cursor/hooks.json"
  out=$(run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed Cursor hooks.json was accepted"
  [ ! -e "$wt/.cursor/hooks/fm-busy-turnend.sh" ] \
    || fail "malformed Cursor hooks.json left a generated hook script"
  printf '%s\n' '{not-json' > "$case_dir/expected-hooks.json"
  cmp -s "$case_dir/expected-hooks.json" "$wt/.cursor/hooks.json" \
    || fail "malformed Cursor hooks.json was modified"
  assert_absent "$home/state/$id.busy-gen" \
    "malformed Cursor hooks.json left its busy generation armed"
  pass "malformed Cursor hooks fail before writing artifacts"
}

test_cursor_spawn_requires_python_before_setup() {
  local rec case_dir home proj wt fakebin id path_without_python3 out status
  rec=$(make_spawn_case missing-python)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  path_without_python3=$(make_path_without_python3 "$case_dir")
  PATH="$fakebin:$path_without_python3" command -v python3 >/dev/null 2>&1 \
    && fail "Cursor spawn runtime fixture unexpectedly exposes python3"

  out=$(FM_CURSOR_TEST_PATH="$path_without_python3" \
    run_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Cursor spawn without python3 unexpectedly succeeded"
  assert_contains "$out" "Cursor hook setup requires python3" \
    "Cursor spawn did not report its missing runtime"
  assert_absent "$home/state/$id.meta" \
    "Cursor spawn published durable task state before its Python preflight"
  assert_absent "$home/state/$id.busy-gen" \
    "Cursor spawn armed busy state before its Python preflight"
  assert_absent "$wt/.cursor/hooks.json" \
    "Cursor spawn wrote hook configuration before its Python preflight"
  assert_absent "$home/launch.log" \
    "Cursor spawn launched the harness before its Python preflight"
  out=$(FM_CURSOR_TEST_PATH="$path_without_python3" \
    run_raw_cursor_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "raw cursor-agent without python3 unexpectedly succeeded"
  assert_contains "$out" "Cursor hook setup requires python3" \
    "raw cursor-agent did not report its missing runtime"
  assert_absent "$home/state/$id.meta" \
    "raw cursor-agent published durable task state before its Python preflight"
  assert_absent "$home/state/$id.busy-gen" \
    "raw cursor-agent armed busy state before its Python preflight"
  assert_absent "$wt/.cursor/hooks.json" \
    "raw cursor-agent wrote hook configuration before its Python preflight"
  assert_absent "$home/launch.log" \
    "raw cursor-agent launched before its Python preflight"
  pass "Cursor templates and raw binaries require Python before setup"
}

test_cursor_family_is_exact() {
  [ "$(fm_control_harness_family cursor-ide 2>/dev/null || true)" != cursor ] \
    || fail "unverified cursor-ide basename was accepted as cursor"
  pass "cursor control-plane family matching is exact"
}

test_tmux_classifies_cursor_agent_only() {
  # Exercise the classifier through fm-backend.sh's source path rather than
  # sourcing backends/tmux.sh directly (that file requires FM_BACKEND_LIB_DIR).
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux
  [ "$(fm_backend_tmux_classify_process_name cursor-agent)" = agent ] \
    || fail "cursor-agent must classify as agent"
  case "$(fm_backend_tmux_classify_process_name cursor)" in
    agent) fail "basename cursor must not classify as agent" ;;
  esac
  case "$(fm_backend_tmux_classify_process_name cursor-ide)" in
    agent) fail "cursor-ide must not classify as agent" ;;
  esac
  pass "tmux liveness classifies exact cursor-agent only"
}

test_cursor_marker_does_not_override_non_cursor_ancestry
test_static_crew_harness_resolution
test_detects_exact_cursor_agent_ancestor
test_detects_cursor_node_wrapper_argv0
test_detection_is_anchored
test_spawn_launch_shape
test_raw_cursor_binary_uses_verified_adapter
test_spawn_refuses_secondmate
test_control_tables
test_cursor_family_is_exact
test_cursor_composer_placeholder_requires_cursor_glyph
test_cursor_spawn_refuses_existing_hook_target_collision
test_cursor_hooks_restore_existing_files
test_cursor_hook_restore_preserves_user_hook_edits
test_cursor_hook_restore_refuses_edited_generated_entry
test_cursor_hook_backup_is_atomic
test_spawn_abort_retains_cursor_backups_when_restore_fails
test_same_cursor_relaunch_refuses_divergent_hook_script
test_failed_same_cursor_relaunch_remains_retryable
test_cursor_restore_recreates_removed_preexisting_hook_script
test_spawn_abort_preserves_cursor_recovery_for_durable_task
test_spawn_retry_preserves_preexisting_cursor_recovery
test_cursor_hooks_reject_parent_symlinks
test_cursor_malformed_hooks_fail_before_writing
test_cursor_spawn_requires_python_before_setup
test_tmux_classifies_cursor_agent_only
