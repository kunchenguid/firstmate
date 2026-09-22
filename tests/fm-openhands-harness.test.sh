#!/usr/bin/env bash
# Behavior tests for the verified OpenHands CLI crewmate/scout adapter.
#
# The facts pinned here are the ones an openhands release could silently change
# and the ones a wrong guess would make dangerous:
#   1. openhands publishes no harness-identity marker of its own, so detection
#      is ancestry alone on the anchored process name `openhands`.
#   2. The anchored match must never claim unrelated commands containing the
#      fragment, and a structural openhands ancestor now outranks a retained
#      CLAUDECODE.
#   3. The launch is the TUI without -f/--task/--headless, with
#      --override-with-envs, --always-approve, and --exit-without-confirmation;
#      model rides LLM_MODEL in a firstmate-owned env file, not a --model flag.
#      Spawn waits for the idle composer, then submits a brief pointer plus Enter.
#   4. Missing LLM_API_KEY and a missing binary refuse before pane creation.
#   5. openhands is a crewmate/scout adapter only: a secondmate launch is
#      refused, and nothing is armed as busy wiring because no writer could
#      clear it.
#   6. The busy signature is the pinned `ESC: pause` status token; the word
#      `Working` must never read busy on its own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-openhands-harness)

test_openhands_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/openhands'; exit 0 ;;
  *"args="*) printf '%s\n' 'openhands --override-with-envs --always-approve'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = openhands ] \
    || fail "a natively-named openhands command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named openhands command"
}

test_openhands_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='cat /home/user/.openhands' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != openhands ] \
    || fail "a path containing .openhands must not detect openhands, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo openhands --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != openhands ] \
    || fail "a later shell argument naming openhands must not detect openhands, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated openhands mentions"
}

test_openhands_python_script_path_is_args_strength() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-python")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' python3.12; exit 0 ;;
  *"args="*) printf '%s\n' '/opt/uv/python /opt/uv/bin/openhands --always-approve'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = openhands ] \
    || fail "a python-invoked openhands script must be detected, got '$out'"
  pass "fm-harness.sh: python script-path fallback detects openhands"
}

test_openhands_claims_no_inherited_launcher_marker() {
  local fakebin out
  out=$(AGENT=1 "$HARNESS")
  [ "$out" != openhands ] \
    || fail "an inherited AGENT=1 must never claim the openhands identity, got '$out'"
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' openhands; exit 0 ;;
  *"args="*) printf '%s\n' 'openhands --always-approve'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = openhands ] \
    || fail "a structural openhands ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: no inherited launcher marker claims the openhands identity"
}

test_openhands_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported openhands || fail "openhands must be a supported control harness"
  [ "$(fm_control_harness_family openhands)" = openhands ] \
    || fail "openhands must map to its own family"
  fm_control_harness_supports_kind openhands scout || fail "openhands must run scouts"
  fm_control_harness_supports_kind openhands ship || fail "openhands must run ships"
  fm_control_harness_supports_kind openhands secondmate \
    && fail "openhands must refuse secondmates" || true
  [ "$(fm_control_interrupt_key openhands)" = Escape ] \
    || fail "openhands must interrupt on Escape"
  [ "$(fm_control_interrupt_repeat openhands)" = 1 ] \
    || fail "openhands must interrupt on a single press"
  [ -z "$(fm_control_interrupt_clear_key openhands)" ] \
    || fail "openhands must need no clear key"
  [ "$(fm_control_interrupt_ack_source openhands)" = none ] \
    || fail "openhands must have no ack source"
  [ "$(fm_control_exit_command openhands)" = /exit ] \
    || fail "openhands must exit on /exit"
  pass "fm-control-lib: openhands mechanics are Escape once, no clear key, and /exit"
}

test_openhands_busy_tail_needs_the_pinned_status_token() {
  printf 'working\nESC: pause\n' | fm_busy_openhands_tail_busy \
    || fail "the ESC: pause status token must read busy"
  printf 'working\n  Working (3s)\n' | fm_busy_openhands_tail_busy \
    && fail "the word Working alone must not read busy" || true
  printf 'Working on the report...\ndone\n' | fm_busy_openhands_tail_busy \
    && fail "echoed worker output naming Working must not read busy" || true
  printf 'idle\nType your message, @mention a file, or / for commands\n' | fm_busy_openhands_tail_busy \
    && fail "an idle composer must not read busy" || true
  printf 'Working on the report...\n' | fm_busy_lines_match openhands \
    && fail "the delivery guard must not acknowledge on echoed Working output" || true
  pass "fm-busy-lib: only the pinned ESC: pause token carries the openhands busy verdict"
}

test_openhands_busy_signatures_are_harness_scoped() {
  printf 'ESC: pause\n' | fm_busy_lines_match openhands \
    || fail "harness=openhands must match its own ESC: pause token"
  printf 'ESC: pause\n' | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow openhands's token" || true
  printf 'ESC: pause\n' | fm_busy_lines_match agy \
    && fail "harness=agy must never borrow openhands's token" || true
  printf 'esc to cancel\n' | fm_busy_lines_match openhands \
    && fail "harness=openhands must never borrow agy's token" || true
  printf 'ESC: pause\n' | fm_busy_lines_match spaceship \
    && fail "an unverified harness must match nothing" || true
  pass "fm-composer-lib: openhands delivery signatures never cross harnesses"
}

test_openhands_classify_reports_unknown_when_the_marker_scrolls_out() {
  local statedir busy idle
  statedir="$TMP_ROOT/classify"; mkdir -p "$statedir"
  busy=$(fm_busy_classify tmux fake:win openhands oh-case-1 "$statedir" 'turn running
⠋ Working (4s • ESC: pause)')
  [ "$busy" = "busy openhands-regex" ] \
    || fail "a busy tail must classify busy openhands-regex, got '$busy'"
  idle=$(fm_busy_classify tmux fake:win openhands oh-case-2 "$statedir" 'reply landed
Type your message, @mention a file, or / for commands')
  [ "$idle" = "unknown openhands-regex" ] \
    || fail "a scrolled-out marker must classify unknown, got '$idle'"
  pass "fm-busy-lib: openhands classifies busy on its marker and unknown without it"
}

test_openhands_tmux_names_the_native_binary_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name openhands)
  [ "$got" = agent ] || fail "tmux liveness must read the openhands binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: openhands is an agent, fragments are not"
}

make_openhands_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_OH_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Loaded: 7 tools\n\n╭────────────────────────────────╮\n│ Type your message, @mention a file, or / for commands │\n╰────────────────────────────────╯\n'
      ;;
    busy|stale)
      printf 'Loaded: 7 tools\n\n⠋ Working (1s • ESC: pause)\nType your message, @mention a file, or / for commands\n'
      ;;
    stuck)
      printf 'shell starting\nInitializing agent...\n'
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
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
      esac
      case "$literal" in
        *'Read the brief at '*)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          case "${FM_FAKE_OH_STUCK:-0}" in
            0|3) printf 'busy\n' > "$FM_FAKE_OH_STATE" ;;
          esac
          ;;
        *--override-with-envs*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          # Run the launch line through a shell as the pane would, so a
          # composition that never reaches the openhands binary stays unready.
          if ! bash -c "$literal" >/dev/null 2>&1 || [ ! -s "$FM_FAKE_OH_EXEC_LOG" ]; then
            printf 'dead\n' > "$FM_FAKE_OH_STATE"
          elif [ "${FM_FAKE_OH_STUCK:-0}" = 1 ]; then
            printf 'stuck\n' > "$FM_FAKE_OH_STATE"
          elif [ "${FM_FAKE_OH_STUCK:-0}" = 3 ]; then
            printf 'stale\n' > "$FM_FAKE_OH_STATE"
          else
            printf 'ready\n' > "$FM_FAKE_OH_STATE"
          fi
          ;;
      esac
      exit 0
    fi
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/openhands" <<'SH'
#!/usr/bin/env bash
printf 'HOME=%s LLM_MODEL=%s args=%s\n' "$HOME" "${LLM_MODEL:-}" "$*" >> "$FM_FAKE_OH_EXEC_LOG"
SH
  chmod +x "$fakebin/openhands"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_openhands_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_openhands_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise OpenHands dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'openhands\n' > "$home/config/crew-harness"
  printf 'LLM_API_KEY=test-openhands-key\nLLM_MODEL=fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash\n' \
    > "$home/config/openhands-llm.env"
  chmod 600 "$home/config/openhands-llm.env"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/oh.state"
  : > "$case_dir/oh-exec.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_openhands_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

run_openhands_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_OH_STATE="$case_dir/oh.state" \
    FM_FAKE_OH_EXEC_LOG="$case_dir/oh-exec.log" \
    FM_FAKE_OH_STUCK="${FM_FAKE_OH_STUCK:-0}" \
    FM_OPENHANDS_READY_POLLS=4 FM_OPENHANDS_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness openhands --mode no-mistakes --yolo off "$@" 2>&1
}

test_openhands_launch_carries_the_brief_with_env_model_and_autonomy() {
  local id rec out rc launch pointer envfile
  id="oh-launch-z1-$$"
  rec=$(make_openhands_spawn_case launch "$id")
  read_openhands_spawn_record "$rec"
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash)
  rc=$?
  expect_code 0 "$rc" "openhands spawn with a model and API key should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  pointer=$(cat "$CASE_DIR/pointer.log")
  assert_contains "$launch" "$FAKEBIN_DIR/openhands" "openhands launch did not pin the resolved absolute binary"
  assert_contains "$launch" "--override-with-envs" "openhands launch omitted --override-with-envs"
  assert_contains "$launch" "--always-approve" "openhands launch omitted --always-approve"
  assert_contains "$launch" "--exit-without-confirmation" "openhands launch omitted --exit-without-confirmation"
  assert_not_contains "$launch" " -f " "openhands launch must not seed the composer with -f"
  assert_not_contains "$launch" "--headless" "openhands launch must keep the TUI rather than --headless"
  assert_not_contains "$launch" "--task" "openhands launch must not seed the composer with --task"
  assert_not_contains "$launch" "--model" "openhands launch must not pass a --model flag"
  assert_not_contains "$launch" "test-openhands-key" "the API key must not appear on the launch argv"
  assert_contains "$(cat "$CASE_DIR/oh-exec.log")" \
    "LLM_MODEL=fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash args=--override-with-envs" \
    "the launch line run through a shell never started openhands with the env-file model"
  assert_contains "$pointer" "Read the brief at " "openhands spawn did not submit the brief pointer after the TUI was ready"
  envfile="$HOME_DIR/state/$id.openhands-env"
  [ -f "$envfile" ] || fail "spawn did not write the per-task openhands env file"
  grep -q "LLM_MODEL=" "$envfile" || fail "the env file omitted LLM_MODEL"
  grep -q "LLM_API_KEY=" "$envfile" || fail "the env file omitted LLM_API_KEY"
  [ "$(cat "$CASE_DIR/oh.state")" = busy ] \
    || fail "the spawn reported success before the pane reached a busy turn"
  [ -d "$HOME_DIR/state/$id.openhands-home" ] \
    || fail "spawn did not create the per-task openhands HOME"
  pass "fm-spawn: openhands launch keeps the TUI, submits a brief pointer, and uses a per-task HOME"
}

test_openhands_missing_api_key_refuses_before_pane_creation() {
  local id rec out rc
  id="oh-nokey-z2-$$"
  rec=$(make_openhands_spawn_case nokey "$id")
  read_openhands_spawn_record "$rec"
  rm -f "$HOME_DIR/config/openhands-llm.env"
  rc=0
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing LLM_API_KEY should refuse the spawn"
  assert_contains "$out" "LLM_API_KEY" "missing-key diagnostic lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "a missing API key created a launch command" || true
  pass "fm-spawn: missing LLM_API_KEY refuses before pane creation"
}

test_openhands_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id="oh-missing-z3-$$"
  rec=$(make_openhands_spawn_case missing "$id")
  read_openhands_spawn_record "$rec"
  rm "$FAKEBIN_DIR/openhands"
  rc=0
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing openhands executable should refuse the spawn"
  assert_contains "$out" "openhands executable not found on PATH" \
    "missing openhands diagnostic lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "a missing openhands executable created a launch command" || true
  pass "fm-spawn: a missing openhands executable refuses before pane creation"
}

test_openhands_secondmate_is_refused() {
  local id rec out rc
  id="oh-secondmate-z4-$$"
  rec=$(make_openhands_spawn_case secondmate-refuse "$id")
  read_openhands_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate openhands 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an openhands secondmate spawn should be refused"
  assert_contains "$out" "openhands is a verified crewmate/scout adapter only" \
    "openhands secondmate refusal lacked its concrete reason"
  pass "fm-spawn: openhands cannot be launched as a secondmate"
}

test_openhands_spawn_arms_no_busy_wiring() {
  local id rec out rc statedir
  id="oh-nowiring-z5-$$"
  rec=$(make_openhands_spawn_case nowiring "$id")
  read_openhands_spawn_record "$rec"
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash)
  rc=$?
  expect_code 0 "$rc" "openhands spawn should succeed"
  statedir="$HOME_DIR/state"
  [ -e "$statedir/$id.busy-gen" ] && fail "openhands spawn armed a busy generation nothing could clear" || true
  pass "fm-spawn: openhands arms no busy wiring"
}

test_openhands_stuck_pane_fails_the_readiness_gate() {
  local id rec out rc
  id="oh-stuck-z6-$$"
  rec=$(make_openhands_spawn_case stuck "$id")
  read_openhands_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_OH_STUCK=1 run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash) || rc=$?
  [ "$rc" -ne 0 ] || fail "a pane that never turns ready should fail the spawn"
  assert_contains "$out" "did not show a ready composer before brief delivery" \
    "stuck-pane diagnostic lacked its concrete reason"
  pass "fm-spawn: openhands readiness gate fails a pane that never shows the idle composer"
}

test_openhands_idle_composer_without_submit_never_goes_busy() {
  local id rec out rc
  id="oh-nosubmit-z7-$$"
  rec=$(make_openhands_spawn_case nosubmit "$id")
  read_openhands_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_OH_STUCK=2 run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash) || rc=$?
  [ "$rc" -ne 0 ] || fail "a ready composer that never starts a turn should fail the spawn"
  assert_contains "$out" "did not start processing its brief" \
    "idle-composer diagnostic lacked its concrete reason"
  assert_contains "$(cat "$CASE_DIR/pointer.log")" "Read the brief at " \
    "the spawn must still submit the brief pointer before failing the busy gate"
  pass "fm-spawn: openhands busy gate fails a ready composer that never shows ESC: pause"
}

test_openhands_stale_busy_token_still_gets_the_pointer() {
  local id rec out rc
  id="oh-stale-z8-$$"
  rec=$(make_openhands_spawn_case stale "$id")
  read_openhands_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_OH_STUCK=3 run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash) || rc=$?
  expect_code 0 "$rc" "openhands spawn over a stale ESC: pause capture should succeed: $out"
  assert_contains "$(cat "$CASE_DIR/pointer.log")" "Read the brief at " \
    "a stale ESC: pause in the capture must not skip the brief pointer"
  pass "fm-spawn: openhands always sends the brief pointer even when the capture shows a stale ESC: pause"
}

test_openhands_ancestry_detects_the_native_command_name
test_openhands_ancestry_rejects_unrelated_mentions
test_openhands_python_script_path_is_args_strength
test_openhands_claims_no_inherited_launcher_marker
test_openhands_control_mechanics_are_the_verified_ones
test_openhands_busy_tail_needs_the_pinned_status_token
test_openhands_busy_signatures_are_harness_scoped
test_openhands_classify_reports_unknown_when_the_marker_scrolls_out
test_openhands_tmux_names_the_native_binary_an_agent
test_openhands_launch_carries_the_brief_with_env_model_and_autonomy
test_openhands_missing_api_key_refuses_before_pane_creation
test_openhands_missing_binary_refuses_before_pane_creation
test_openhands_secondmate_is_refused
test_openhands_spawn_arms_no_busy_wiring
test_openhands_stuck_pane_fails_the_readiness_gate
test_openhands_idle_composer_without_submit_never_goes_busy
test_openhands_stale_busy_token_still_gets_the_pointer
