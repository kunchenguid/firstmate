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
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
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

run_cursor_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_CURSOR_ARGS_LOG="$home/cursor-agent.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor "$@" 2>&1
}

test_detects_cursor_agent_marker() {
  local out
  out=$(CURSOR_AGENT=1 env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT "$HARNESS")
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 should detect cursor, got '$out'"
  pass "cursor is detected through CURSOR_AGENT=1"
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
  local rec case_dir home proj wt fakebin id out status trusted
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
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
assert any(item.startswith("arg=\u2063FIRSTMATE_OP: v1 launch-brief:") for item in args), args
assert "arg=--effort" not in args, args
assert "arg=reasoning-effort" not in args, args
PY
  assert_grep 'harness=cursor' "$home/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'effort=low' "$home/state/$id.meta" "requested effort was not retained in meta"
  assert_grep 'model=composer-2.5-fast' "$home/state/$id.meta" "model was not recorded in meta"

  assert_present "$wt/.cursor/hooks.json" "cursor spawn did not write project hooks.json"
  assert_present "$wt/.cursor/hooks/fm-busy-turnend.sh" "cursor spawn did not write busy/turnend hook"
  [ -x "$wt/.cursor/hooks/fm-busy-turnend.sh" ] \
    || fail "cursor busy/turnend hook must be executable"
  python3 - "$wt/.cursor/hooks.json" <<'PY' || fail "cursor hooks JSON does not expose the required events"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
assert hooks["beforeSubmitPrompt"], hooks
assert hooks["stop"], hooks
assert hooks["sessionEnd"], hooks
assert hooks["stop"][0]["command"].endswith("fm-busy-turnend.sh idle-stop"), hooks
assert hooks["sessionEnd"][0]["command"].endswith("fm-busy-turnend.sh idle-session-end"), hooks
PY

  trusted=$(fm_busy_sources_for_harness cursor)
  case " $trusted " in
    *" cursor-hook "*) ;;
    *) fail "cursor must trust cursor-hook, got '$trusted'" ;;
  esac
  [ -f "$home/state/$id.busy-gen" ] \
    || fail "cursor spawn must arm a busy generation"
  pass "cursor spawn launches with yolo+trust, omits effort flags, and wires project hooks"
}

test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
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
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  [ "$(fm_tmux_composer_row_state '│ Add a follow-up │' 1 0)" = pending ] \
    || fail "ordinary Add a follow-up text was treated as an empty composer"
  [ "$(fm_tmux_composer_row_state '→' 0 0)" = empty ] \
    || fail "cursor's empty prompt glyph was not recognized"
  pass "cursor placeholder classification requires the prompt glyph"
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

test_detects_cursor_agent_marker
test_detects_exact_cursor_agent_ancestor
test_detection_is_anchored
test_spawn_launch_shape
test_spawn_refuses_secondmate
test_control_tables
test_cursor_family_is_exact
test_cursor_composer_placeholder_requires_cursor_glyph
test_tmux_classifies_cursor_agent_only
