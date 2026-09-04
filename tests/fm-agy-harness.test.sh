#!/usr/bin/env bash
# Behavior tests for the verified Antigravity (agy) CLI crewmate adapter.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. Drop foreign
# markers so the suite does not depend on ambient harness environment.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS ANTIGRAVITY_AGENT HERDR_ENV

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HARNESS_SH="$ROOT/bin/fm-harness.sh"
AGY_HOOK="$ROOT/bin/fm-agy-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_AGY_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf '────────────────────────────────────────────────────────\n> \n────────────────────────────────────────────────────────\n? for shortcuts          Gemini 3.7 Flash · high\n'
      ;;
    typed)
      printf '────────────────────────────────────────────────────────\n> some typed input\n────────────────────────────────────────────────────────\n? for shortcuts          Gemini 3.7 Flash · high\n'
      ;;
    busy)
      printf 'Generating...\nesc to cancel\n'
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
      printf 'ready\n' > "$FM_FAKE_AGY_STATE"
      exit 0
    fi
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/.gemini/config/plugins"
  printf 'brief for agy\n' > "$home/data/$id/brief.md"
  printf 'agy\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$home/launch.log"
  : > "$home/agy.state"
  : > "$home/tmux.log"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_PANE_PATH="$wt" \
  FM_FAKE_TMUX_CALL_LOG="$home/tmux.log" \
  FM_FAKE_LAUNCH_LOG="$home/launch.log" \
  FM_FAKE_AGY_STATE="$home/agy.state" \
  TMUX="fake,1,0" \
  PATH="$fakebin:$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$home" \
  "$SPAWN" "$@" --backend tmux --mode no-mistakes --yolo off 2>&1
}

# --- 1. Harness Detection ---------------------------------------------------

test_harness_detection_marker() {
  local out
  out=$(ANTIGRAVITY_AGENT=1 "$HARNESS_SH")
  [ "$out" = "agy" ] || fail "ANTIGRAVITY_AGENT=1 must detect as 'agy', got '$out'"
  pass "fm-harness.sh detects agy from ANTIGRAVITY_AGENT=1 environment marker"
}

test_harness_resolution_crew() {
  local home="$TMP_ROOT/detect-crew" out
  mkdir -p "$home/config"
  printf 'agy\n' > "$home/config/crew-harness"
  out=$(FM_CONFIG_OVERRIDE="$home/config" "$HARNESS_SH" crew)
  [ "$out" = "agy" ] || fail "crew-harness=agy must resolve 'agy', got '$out'"
  pass "fm-harness.sh resolves config/crew-harness=agy"
}

test_harness_resolution_secondmate() {
  local home="$TMP_ROOT/detect-sm" out model effort
  mkdir -p "$home/config"
  printf 'agy gemini-3.7-flash medium\n' > "$home/config/secondmate-harness"
  out=$(FM_CONFIG_OVERRIDE="$home/config" "$HARNESS_SH" secondmate)
  [ "$out" = "agy" ] || fail "secondmate-harness=agy must resolve 'agy', got '$out'"
  model=$(FM_CONFIG_OVERRIDE="$home/config" "$HARNESS_SH" secondmate-model)
  [ "$model" = "gemini-3.7-flash" ] || fail "secondmate-model must resolve 'gemini-3.7-flash', got '$model'"
  effort=$(FM_CONFIG_OVERRIDE="$home/config" "$HARNESS_SH" secondmate-effort)
  [ "$effort" = "medium" ] || fail "secondmate-effort must resolve 'medium', got '$effort'"
  pass "fm-harness.sh resolves config/secondmate-harness agy with model and effort tokens"
}

# --- 2. Control Contract ----------------------------------------------------

test_control_contract() {
  fm_control_harness_supported "agy" || fail "agy must be a supported harness in fm-control-lib.sh"
  local fam key rep clr cmd
  fam=$(fm_control_harness_family "agy")
  [ "$fam" = "agy" ] || fail "family for agy must be 'agy', got '$fam'"
  key=$(fm_control_interrupt_key "agy")
  [ "$key" = "Escape" ] || fail "interrupt key for agy must be 'Escape', got '$key'"
  rep=$(fm_control_interrupt_repeat "agy")
  [ "$rep" = "1" ] || fail "interrupt repeat for agy must be 1, got '$rep'"
  clr=$(fm_control_interrupt_clear_key "agy" || true)
  [ -z "$clr" ] || fail "interrupt clear key for agy should be empty, got '$clr'"
  cmd=$(fm_control_exit_command "agy")
  [ "$cmd" = "/exit" ] || fail "exit command for agy must be '/exit', got '$cmd'"
  fm_control_harness_supports_kind "agy" "ship" || fail "agy must support kind=ship"
  fm_control_harness_supports_kind "agy" "scout" || fail "agy must support kind=scout"
  fm_control_harness_supports_kind "agy" "secondmate" || fail "agy must support kind=secondmate"
  pass "fm-control-lib.sh defines verified control capabilities for agy"
}

# --- 3. Busy State Contract -------------------------------------------------

test_busy_sources() {
  local sources
  sources=$(fm_busy_sources_for_harness "agy")
  case "$sources" in
    *"agy-hook"*) ;;
    *) fail "fm_busy_sources_for_harness agy must include 'agy-hook', got '$sources'" ;;
  esac
  fm_busy_source_trusted "agy" "agy-hook" || fail "agy-hook must be trusted for agy"
  fm_busy_source_trusted "agy" "fm-spawn" || fail "fm-spawn must be trusted for agy"
  pass "fm-busy-lib.sh trusts agy-hook and firstmate sources for agy"
}

test_composer_busy_delivery() {
  local match
  match=$(printf 'Generating...\nesc to cancel\n' | fm_busy_lines_match "agy" && echo yes || echo no)
  [ "$match" = "yes" ] || fail "fm_busy_lines_match agy must match 'Generating... esc to cancel'"
  pass "fm-composer-lib.sh matches agy busy delivery footer"
}

# --- 4. Spawn & Hook Lifecycle ---------------------------------------------

test_spawn_and_turnend_hook_lifecycle() {
  local rec id=agy-task-1 case_dir home proj wt fakebin out launch state wt_pointer token auth_dir
  rec=$(make_spawn_case spawn-test "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF

  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness agy --model gemini-3.7-flash --effort medium)
  expect_code 0 $? "agy spawn should succeed: $out"

  launch=$(cat "$home/launch.log" 2>/dev/null || true)
  case "$launch" in
    *"agy --dangerously-skip-permissions"*|*"agy' --dangerously-skip-permissions"*) ;;
    *) fail "launch command must contain agy --dangerously-skip-permissions, got '$launch'" ;;
  esac
  case "$launch" in
    *"--prompt-interactive"*) ;;
    *) fail "launch command must contain --prompt-interactive, got '$launch'" ;;
  esac
  case "$launch" in
    *"--model gemini-3.7-flash"*|*"--model 'gemini-3.7-flash'"*) ;;
    *) fail "launch command must contain threaded model flag, got '$launch'" ;;
  esac
  case "$launch" in
    *"--effort medium"*|*"--effort 'medium'"*) ;;
    *) fail "launch command must contain threaded effort flag, got '$launch'" ;;
  esac

  state="$home/state"
  wt_pointer="$wt/.fm-agy-turnend"
  assert_present "$wt_pointer" "worktree must contain .fm-agy-turnend pointer"
  assert_present "$state/$id.agy-turnend-token" "state must contain agy-turnend-token"
  token=$(cat "$state/$id.agy-turnend-token")
  [ -n "$token" ] || fail "token must not be empty"

  auth_dir="$home/.gemini/config/plugins/firstmate/fm-turn-end.d"
  assert_present "$auth_dir/$token" "registry must contain token auth record"

  # Initial state after spawn must be busy fm-spawn
  out=$(fm_busy_classify tmux fake:w agy "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "initial state after spawn must be 'busy fm-spawn', got '$out'"

  # Drive PreInvocation hook
  out=$(python3 -c "
import json, subprocess
payload = {
  'conversationId': 'conv-1',
  'workspacePaths': ['$wt'],
  'invocationNum': 1,
  'initialNumSteps': 0
}
res = subprocess.run(
  ['bash', '$home/.gemini/config/plugins/firstmate/fm-turn-end.sh', 'pre-invocation'],
  input=json.dumps(payload).encode('utf-8'),
  capture_output=True,
  env={'HOME': '$home', 'PATH': '$fakebin:$PYTHON_BIN_DIR:/usr/bin:/bin'}
)
assert res.returncode == 0
")
  out=$(fm_busy_classify tmux fake:w agy "$id" "$state")
  [ "$out" = "busy agy-hook" ] || fail "state after pre-invocation must be 'busy agy-hook', got '$out'"

  # Drive Stop hook with fullyIdle=false (subagent / background work continuing)
  out=$(python3 -c "
import json, subprocess
payload = {
  'conversationId': 'conv-1',
  'workspacePaths': ['$wt'],
  'executionNum': 1,
  'fullyIdle': False
}
res = subprocess.run(
  ['bash', '$home/.gemini/config/plugins/firstmate/fm-turn-end.sh', 'stop'],
  input=json.dumps(payload).encode('utf-8'),
  capture_output=True,
  env={'HOME': '$home', 'PATH': '$fakebin:$PYTHON_BIN_DIR:/usr/bin:/bin'}
)
assert res.returncode == 0
")
  [ ! -f "$state/$id.turn-ended" ] || fail "turn-ended must NOT be touched when fullyIdle=false"
  out=$(fm_busy_classify tmux fake:w agy "$id" "$state")
  [ "$out" = "busy agy-hook" ] || fail "state must stay busy when fullyIdle=false, got '$out'"

  # Drive Stop hook with fullyIdle=true (turn completed)
  out=$(python3 -c "
import json, subprocess
payload = {
  'conversationId': 'conv-1',
  'workspacePaths': ['$wt'],
  'executionNum': 1,
  'fullyIdle': True
}
res = subprocess.run(
  ['bash', '$home/.gemini/config/plugins/firstmate/fm-turn-end.sh', 'stop'],
  input=json.dumps(payload).encode('utf-8'),
  capture_output=True,
  env={'HOME': '$home', 'PATH': '$fakebin:$PYTHON_BIN_DIR:/usr/bin:/bin'}
)
assert res.returncode == 0
")
  [ -f "$state/$id.turn-ended" ] || fail "turn-ended MUST be touched when fullyIdle=true"
  out=$(fm_busy_classify tmux fake:w agy "$id" "$state")
  [ "$out" = "idle agy-hook" ] || fail "state after full idle stop must be 'idle agy-hook', got '$out'"

  # Drive Teardown
  HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PYTHON_BIN_DIR:/usr/bin:/bin" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "agy teardown failed"
  assert_absent "$wt_pointer" "worktree pointer must be removed after teardown"
  assert_absent "$auth_dir/$token" "auth registry token must be removed after teardown"
  assert_absent "$state/$id.agy-turnend-token" "state token must be removed after teardown"

  pass "agy spawn wires turn-end hook, PreInvocation transitions to busy, Stop settles idle, teardown cleans up"
}

# --- 5. Hook installer validation ------------------------------------------

test_hook_installer_idempotency() {
  local home="$TMP_ROOT/hook-install"
  mkdir -p "$home/.gemini/config/plugins"
  HOME="$home" "$AGY_HOOK" install
  expect_code 0 $? "first agy hook install should succeed"

  assert_present "$home/.gemini/config/plugins/firstmate/plugin.json" "plugin.json must exist"
  assert_present "$home/.gemini/config/plugins/firstmate/hooks.json" "hooks.json must exist"
  assert_present "$home/.gemini/config/plugins/firstmate/fm-turn-end.sh" "fm-turn-end.sh must exist"
  assert_present "$home/.gemini/config/plugins/firstmate/fm-turn-end.d" "fm-turn-end.d must exist"

  HOME="$home" "$AGY_HOOK" install
  expect_code 0 $? "idempotent agy hook install should succeed"

  HOME="$home" "$AGY_HOOK" remove
  expect_code 0 $? "agy hook remove should succeed"
  [ ! -d "$home/.gemini/config/plugins/firstmate" ] || fail "firstmate plugin dir should be removed after remove"

  pass "fm-agy-turnend-hook.sh installs idempotently and removes cleanly"
}

# --- 6. Missing binary & Fallback -------------------------------------------

test_agy_missing_binary_refuses_before_pane_creation() {
  local rec id=agy-missing-1 case_dir home proj wt fakebin out rc
  rec=$(make_spawn_case missing-test "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  rm "$fakebin/agy"
  rc=0
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness agy) || rc=$?
  [ "$rc" -ne 0 ] || fail "missing agy executable should refuse spawn"
  assert_contains "$out" "searched PATH for 'agy'" "missing agy diagnostic omitted PATH"
  assert_contains "$out" "fallback '$home/.local/bin/agy'" "missing agy diagnostic omitted fallback path"
  pass "fm-spawn: missing agy executable refuses before pane creation"
}

test_agy_fallback_binary() {
  local rec id=agy-fallback-1 case_dir home proj wt fakebin out fallback launch
  rec=$(make_spawn_case fallback-test "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  rm "$fakebin/agy"
  fallback="$home/.local/bin/agy"
  mkdir -p "$(dirname "$fallback")"
  fm_fake_exit0 "$(dirname "$fallback")" agy
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness agy)
  expect_code 0 $? "agy fallback spawn should succeed: $out"
  launch=$(cat "$home/launch.log" 2>/dev/null || true)
  case "$launch" in
    *"$fallback"*) ;;
    *) fail "launch command must use fallback binary, got '$launch'" ;;
  esac
  pass "fm-spawn: agy falls back to ~/.local/bin/agy"
}

test_fm_lock_recognizes_agy_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/agy'; exit 0 ;;
  *"args="*) printf '%s\n' 'agy'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize agy as a live holder"
  pass "fm-lock recognizes agy harness processes"
}

test_harness_detection_marker
test_harness_resolution_crew
test_harness_resolution_secondmate
test_control_contract
test_busy_sources
test_composer_busy_delivery
test_hook_installer_idempotency
test_spawn_and_turnend_hook_lifecycle
test_agy_missing_binary_refuses_before_pane_creation
test_agy_fallback_binary
test_fm_lock_recognizes_agy_holder
