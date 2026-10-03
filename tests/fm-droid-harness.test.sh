#!/usr/bin/env bash
# Executable adapter checks for Droid identity, launch settings, and hooks.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-droid-harness)

test_droid_identity_and_control() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/identity")
  cat >"$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' /usr/local/bin/droid ;;
  *"args="*) printf '%s\n' 'droid --settings /tmp/task.json' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = droid ] || fail "droid ancestry must outrank an inherited launcher marker, got '$out'"
  [ "$(fm_agent_process_classify_name droid)" = agent ] || fail "droid process must be an agent"
  [ "$(fm_agent_process_classify_name droid-helper)" = other ] || fail "droid identity must be anchored"
  fm_control_harness_supports_kind droid scout || fail "droid must run scouts"
  fm_control_harness_supports_kind droid ship || fail "droid must run ships"
  fm_control_harness_supports_kind droid secondmate && fail "droid must refuse secondmates" || true
  [ "$(fm_control_interrupt_key droid)" = Escape ] || fail "droid interrupt key changed"
  [ "$(fm_control_interrupt_clear_key droid)" = C-u ] || fail "Droid interrupt must clear a queued prompt"
  [ "$(fm_control_exit_command droid)" = /exit ] || fail "droid exit command changed"
  printf ' ⠃ Thinking...  (Press ESC to stop)\n' | fm_busy_lines_match droid \
    || fail "Droid working status must acknowledge typed delivery"
  printf ' ⠃ Streaming...  (Press ESC to stop)\n' | fm_busy_lines_match droid \
    || fail "Droid streaming status must acknowledge typed delivery"
  printf 'Auto (High) · allow all commands\n' | fm_busy_lines_match droid \
    && fail "Droid idle status must not acknowledge typed delivery" || true
  pass "Droid is a crewmate/scout agent with verified control mechanics"
}

# Captured from a live tmux Droid 0.230.0 scout at idle after its first turn.
DROID_IDLE_SCREEN=' Auto (High) · allow all commands                            GPT-5.6 Luna (Low)
╭──────────────────────────────────────────────────────────────────────────────╮
│ >                                                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
[⏱ 16s, context: 3%] 3 config issues — /diagnostics               MCP ✓ | TMUX ⧉
firstmate'
DROID_ORCA_IDLE_SCREEN=$(cat "$ROOT/tests/fixtures/droid/idle-orca-0.230.0.txt")

test_droid_composer_envelope() {
  local screen=$DROID_IDLE_SCREEN out
  out=$(fm_tmux_droid_composer_state "$screen")
  [ "$out" = empty ] || fail "Droid idle composer must be proven empty, got '$out'"
  out=$(fm_tmux_droid_composer_state "${screen/│ >           /│ > /exit     }")
  [ "$out" = pending ] || fail "Droid typed composer must stay pending, got '$out'"
  out=$(fm_tmux_droid_composer_state "$screen
unexpected modal")
  [ "$out" = unknown ] || fail "an overlay below Droid's composer must refuse input, got '$out'"
  out=$(fm_tmux_droid_composer_state "${screen%firstmate}[OMD] session:0m")
  [ "$out" = unknown ] || fail "a user statusLine below Droid's composer must refuse input, got '$out'"
  out=$(fm_tmux_droid_composer_state "${screen/TMUX ⧉/TMUX ●}")
  [ "$out" = empty ] || fail "a changed Droid integration indicator must not hide an empty composer"
  out=$(fm_tmux_droid_composer_state "${screen/\[⏱ 16s, context: 3%\] /}")
  [ "$out" = unknown ] || fail "a footer without Droid's timer must refuse input, got '$out'"
  pass "Droid composer is readable only under a complete live TUI envelope"
}

test_droid_composer_requires_a_droid_process() {
  local fakebin screen out
  fakebin=$(fm_fakebin "$TMP_ROOT/composer-identity")
  screen="$TMP_ROOT/composer-identity/screen.txt"
  printf '%s\n' "$DROID_IDLE_SCREEN" >"$screen"
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *cursor_y*) printf '20\n' ;;
  *pane_current_command*) printf '%s\n' "${FM_FAKE_PROCESS_NAME:-bash}" ;;
  *pane_tty*) printf '\n' ;;
  *capture-pane*) cat "$FM_FAKE_SCREEN" ;;
  *) printf '\n' ;;
esac
SH
  chmod +x "$fakebin/tmux"
  out=$(FM_FAKE_SCREEN="$screen" FM_FAKE_PROCESS_NAME=droid PATH="$fakebin:$PATH" fm_tmux_composer_state fake:win)
  [ "$out" = empty ] || fail "a live Droid pane must reach the cursorless composer proof, got '$out'"
  out=$(FM_FAKE_SCREEN="$screen" FM_FAKE_PROCESS_NAME=notdroid PATH="$fakebin:$PATH" fm_tmux_composer_state fake:win)
  [ "$out" = unknown ] || fail "an identical screen from another process must stay unknown, got '$out'"
  pass "Droid composer proof is gated on the foreground process identity"
}

test_droid_orca_composer_uses_the_live_screen() {
  local screen=$DROID_ORCA_IDLE_SCREEN out
  out=$(fm_composer_droid_state "$screen" orca)
  [ "$out" = empty ] || fail "captured Orca Droid idle screen must read empty, got '$out'"
  out=$(fm_composer_droid_state "${screen/│ >           /│ > /exit     }" orca)
  [ "$out" = pending ] || fail "typed text in captured Orca composer must stay pending, got '$out'"
  out=$(fm_composer_droid_state "$screen
shell prompt" orca)
  [ "$out" = unknown ] || fail "a shell prompt below a stale Orca Droid frame must stay unknown"
  out=$(fm_composer_droid_state "${screen/IDE ◌/IDE ●}" orca)
  [ "$out" = empty ] || fail "an Orca integration status change must preserve the empty verdict"
  out=$(fm_composer_droid_state "${screen/\[⏱ 17s, context: 3%\] /}" orca)
  [ "$out" = unknown ] || fail "an Orca footer without Droid's timer must refuse input"
  pass "captured Orca Droid screen has strict idle, pending, and stale-frame verdicts"
}

make_droid_case() {  # <name> <id>
  local case_dir=$1 id=$2 fakebin
  CASE_DIR="$TMP_ROOT/$case_dir"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  fakebin=$(make_spawn_fakebin "$CASE_DIR/fake" droid)
  FAKEBIN_DIR=$fakebin
  fm_test_spawn_home "$HOME_DIR" droid
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$case_dir"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = send-keys ] && [ "${*: -1}" = Enter ] && [ -n "${FM_FAKE_DROID_SETTINGS:-}" ]; then
  printf 'Enter\n' >>"${FM_FAKE_DROID_SETTINGS}.enters"
fi
if [ "${1:-}" = capture-pane ] && [ -f "${FM_FAKE_DROID_SETTINGS:-/nonexistent}" ]; then
  [ -z "${FM_FAKE_DROID_CAPTURE_SLEEP:-}" ] || sleep "$FM_FAKE_DROID_CAPTURE_SLEEP"
  captures=$(cat "${FM_FAKE_DROID_SETTINGS}.captures" 2>/dev/null || printf 0)
  captures=$((captures + 1))
  printf '%s\n' "$captures" >"${FM_FAKE_DROID_SETTINGS}.captures"
  [ "$captures" -gt "${FM_FAKE_DROID_CAPTURE_FAIL_POLLS:-0}" ] || exit 1
  shown=$(cat "${FM_FAKE_DROID_SETTINGS}.trust" 2>/dev/null || printf 0)
  if [ "$shown" -lt "${FM_FAKE_DROID_TRUST_POLLS:-0}" ]; then
    printf '%s\n' "$((shown + 1))" >"${FM_FAKE_DROID_SETTINGS}.trust"
    if [ "${FM_FAKE_DROID_TRUST_NEGATIVE:-0}" = 1 ]; then
      printf 'Trust this folder?\n  1. Trust this folder\n> 2. Exit without trusting\nEnter to confirm · Esc to exit\n'
    else
      printf 'Trust this folder?\n> 1. Trust this folder\n  2. Exit without trusting\nEnter to confirm · Esc to exit\n'
    fi
    exit 0
  fi
  if [ ! -e "${FM_FAKE_DROID_SETTINGS}.submitted" ]; then
    if [ "${FM_FAKE_DROID_HOOKS_DISABLED:-0}" != 1 ]; then
      command=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$FM_FAKE_DROID_SETTINGS")
      sh -c "$command"
    fi
    touch "${FM_FAKE_DROID_SETTINGS}.submitted"
  fi
  printf 'Droid ready\n'
  exit 0
fi
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$fakebin/tmux"
  cat >"$fakebin/droid" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = exec ] && IFS= read -r -t 1 _; then
  touch "$(dirname "$0")/probe-read-stdin"
fi
if [ "${1:-}" = exec ] && [ "${2:-}" = --help ]; then
  cat <<'HELP'
Available Models:
  gpt-5.6-luna                 GPT-5.6 Luna (default)
  claude-haiku-4-5-20251001    Haiku 4.5

Model details:
  - GPT-5.6 Luna: supports reasoning: Yes; supported: [none, low, medium, high, xhigh, max]; default: medium
  - Haiku 4.5: supports reasoning: Yes; supported: [off, low, medium, high]; default: off
HELP
  exit 0
fi
if [ "${1:-}" = exec ] && [ -n "${FM_FAKE_DROID_REJECT_MODEL:-}" ]; then
  printf 'Invalid model: %s\n' "$FM_FAKE_DROID_REJECT_MODEL" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/droid"
}

run_droid_spawn() {  # <id> [extra args]
  local id=$1
  shift
  FM_FAKE_DROID_SETTINGS="$HOME_DIR/state/$id.droid-settings.json" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --scout --harness droid "$@"
}

test_droid_launch_and_hooks() {
  local id=droid-launch-1 out rc settings cmd state
  make_droid_case launch "$id"
  out=$(run_droid_spawn "$id" --model gpt-5.6-luna --effort low)
  rc=$?
  expect_code 0 "$rc" "Droid spawn failed: $out"
  settings="$HOME_DIR/state/$id.droid-settings.json"
  state="$HOME_DIR/state"
  jq -e '.model == "gpt-5.6-luna" and .reasoningEffort == "low" and .sessionDefaultSettings.autonomyLevel == "high" and (has("hooksDisabled") | not)' "$settings" >/dev/null \
    || fail "Droid settings lost model/effort/autonomy or overrode the operator's hooks policy"
  out=$(sh -c "$(jq -r '.statusLine.command' "$settings")" 2>/dev/null)
  [ -n "$out" ] && [ "$(fm_tmux_droid_composer_state "${DROID_IDLE_SCREEN%firstmate}$out")" = empty ] \
    || fail "Droid worker statusLine must draw the row the composer read accepts, got '$out'"
  grep -Fq -- '--settings' "$CASE_DIR/launch.log" || fail "Droid launch did not use its runtime settings"
  grep -Fq -- '--model' "$CASE_DIR/launch.log" && fail "interactive Droid does not accept --model" || true
  grep -Fq -- '--auto high' "$CASE_DIR/launch.log" || fail "Droid launch did not request unattended autonomy"
  grep -Fq -- 'encode launch-brief' "$CASE_DIR/launch.log" || fail "Droid launch did not carry the encoded brief"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'busy droid-hook' ] \
    || fail "UserPromptSubmit hook did not replace the spawn seed"
  cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")
  sh -c "$cmd"
  [ -e "$state/$id.turn-ended" ] || fail "Stop hook did not signal turn end"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'idle droid-hook' ] \
    || fail "Stop hook did not close the busy record"
  cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$settings")
  sh -c "$cmd"
  cmd=$(jq -r '.hooks.Notification[0].hooks[0].command' "$settings")
  printf '%s\n' '{"notification_type":"idle_prompt"}' | sh -c "$cmd"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'idle droid-hook' ] \
    || fail "idle notification did not settle a cancelled turn"
  cmd=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$settings")
  sh -c "$cmd"
  [ "$(cat "$state/$id.droid-session-end")" = "$(cat "$state/$id.busy-gen")" ] \
    || fail "SessionEnd did not record the current busy generation"
  fm_control_droid_session_ended "$state" "$id" "$state/$id.meta" \
    || fail "Orca control must accept the generation-bound SessionEnd marker"
  rm -f "$state/$id.droid-session-end"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  sh -c "$cmd"
  [ ! -e "$state/$id.droid-session-end" ] || fail "an old Droid session marked a replacement stopped"
  rm -f "$state/$id.turn-ended"
  cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")
  sh -c "$cmd"
  [ ! -e "$state/$id.turn-ended" ] || fail "an old Droid Stop falsely woke the replacement turn"
  pass "Droid spawn passes the brief and model settings; hooks open and close turns"
}

test_droid_trust_dialog_is_answered_once() {
  local out rc base trusted
  make_droid_case trust-base droid-trust-base
  out=$(run_droid_spawn droid-trust-base)
  expect_code 0 $? "Droid baseline spawn failed: $out"
  base=$(wc -l <"$HOME_DIR/state/droid-trust-base.droid-settings.json.enters")
  make_droid_case trust-held droid-trust-held
  out=$(FM_FAKE_DROID_TRUST_POLLS=3 run_droid_spawn droid-trust-held)
  rc=$?
  expect_code 0 "$rc" "Droid spawn behind a lingering trust dialog failed: $out"
  trusted=$(wc -l <"$HOME_DIR/state/droid-trust-held.droid-settings.json.enters")
  [ "$trusted" -eq $((base + 1)) ] \
    || fail "a trust dialog drawn for three polls must get one Enter, got $((trusted - base))"
  pass "Droid answers a lingering trust dialog once"
}

test_droid_refuses_a_negative_trust_selection() {
  local id=droid-trust-negative out rc base seen
  make_droid_case trust-negative-base droid-trust-negative-base
  out=$(run_droid_spawn droid-trust-negative-base)
  expect_code 0 $? "Droid baseline spawn failed: $out"
  base=$(wc -l <"$HOME_DIR/state/droid-trust-negative-base.droid-settings.json.enters")
  make_droid_case trust-negative "$id"
  out=$(FM_FAKE_DROID_TRUST_POLLS=3 FM_FAKE_DROID_TRUST_NEGATIVE=1 run_droid_spawn "$id")
  rc=$?
  expect_code 1 "$rc" "Droid must refuse a trust dialog with Exit selected: $out"
  seen=$(wc -l <"$HOME_DIR/state/$id.droid-settings.json.enters")
  [ "$seen" -eq "$base" ] || fail "negative trust selection received an extra Enter"
  printf '%s' "$out" | grep -Fq 'Exit without trusting selected' || fail "trust refusal must identify the selected choice: $out"
  pass "Droid never confirms a selected negative trust choice"
}

test_droid_retries_one_transient_viewport_failure() {
  local id=droid-capture-retry out rc
  make_droid_case capture-retry "$id"
  out=$(FM_FAKE_DROID_CAPTURE_FAIL_POLLS=1 run_droid_spawn "$id")
  rc=$?
  expect_code 0 "$rc" "Droid should recover from one failed viewport read: $out"
  [ "$(cat "$HOME_DIR/state/$id.droid-settings.json.captures")" -ge 2 ] \
    || fail "Droid did not retry the viewport read"
  pass "Droid retries a transient viewport capture failure"
}

test_droid_bounds_a_hung_viewport_read() {
  local id=droid-capture-hung out rc started elapsed
  make_droid_case capture-hung "$id"
  started=$(date +%s)
  out=$(FM_FAKE_DROID_CAPTURE_SLEEP=10 FM_DROID_CAPTURE_TIMEOUT=1 \
    FM_DROID_READY_SECONDS=2 FM_DROID_READY_POLLS=2 FM_DROID_POLL_INTERVAL=0 \
    run_droid_spawn "$id")
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 1 "$rc" "a hung Droid viewport read must fail: $out"
  [ "$elapsed" -lt 30 ] || fail "hung Droid viewport read exceeded its bound (${elapsed}s)"
  printf '%s' "$out" | grep -Fq 'viewport capture never succeeded (last exit 124)' \
    || fail "hung viewport refusal did not identify capture failure: $out"
  pass "Droid bounds hung viewport reads and reports capture failure"
}

test_droid_respects_disabled_hooks_policy() {
  local id=droid-hooks-disabled out rc
  make_droid_case hooks-disabled "$id"
  out=$(FM_FAKE_DROID_HOOKS_DISABLED=1 FM_DROID_READY_POLLS=2 FM_DROID_POLL_INTERVAL=0 \
    run_droid_spawn "$id")
  rc=$?
  expect_code 1 "$rc" "Droid without operator-enabled hooks must fail readiness: $out"
  jq -e 'has("hooksDisabled") | not' "$HOME_DIR/state/$id.droid-settings.json" >/dev/null \
    || fail "Droid overrode the operator's hooks-disabled policy"
  printf '%s' "$out" | grep -Fq 'whether hooks are disabled' \
    || fail "Droid hook refusal did not name the policy possibility: $out"
  pass "Droid leaves operator hook policy intact and refuses unacknowledged launches"
}

test_droid_omits_unsupported_model_effort() {
  local id=droid-effort-unsupported out rc settings
  make_droid_case effort-unsupported "$id"
  out=$(run_droid_spawn "$id" --model claude-haiku-4-5-20251001 --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "unsupported effort should use the recorded-and-omitted contract: $out"
  settings="$HOME_DIR/state/$id.droid-settings.json"
  jq -e '.model == "claude-haiku-4-5-20251001" and (has("reasoningEffort") | not)' "$settings" >/dev/null \
    || fail "unsupported Haiku xhigh effort reached Droid runtime settings"
  grep -Fqx 'effort=xhigh' "$HOME_DIR/state/$id.meta" || fail "requested effort was not recorded"
  printf '%s' "$out" | grep -Fq 'unsupported' || fail "effort omission was not disclosed"
  pass "Droid records and omits a model-specific unsupported effort"
}

test_droid_omits_effort_without_explicit_model() {
  local id=droid-effort-no-model out rc settings
  make_droid_case effort-no-model "$id"
  out=$(run_droid_spawn "$id" --effort low)
  rc=$?
  expect_code 0 "$rc" "effort without a model should use the recorded-and-omitted contract: $out"
  settings="$HOME_DIR/state/$id.droid-settings.json"
  jq -e '(has("model") | not) and (has("reasoningEffort") | not)' "$settings" >/dev/null \
    || fail "effort without --model reached Droid runtime settings for the operator's default model"
  grep -Fqx 'effort=low' "$HOME_DIR/state/$id.meta" || fail "requested effort was not recorded"
  printf '%s' "$out" | grep -Fq 'omitting it from runtime settings' || fail "effort omission was not disclosed: $out"
  pass "Droid omits effort when the operator's default model runs"
}

test_droid_model_probe_detaches_stdin() {
  local id=droid-probe-stdin out rc
  make_droid_case probe-stdin "$id"
  out=$(printf 'stdin-leak\n' | run_droid_spawn "$id" --model gpt-5.6-luna)
  rc=$?
  expect_code 0 "$rc" "Droid spawn with piped stdin failed: $out"
  [ ! -e "$FAKEBIN_DIR/probe-read-stdin" ] || fail "Droid model probe read the caller's stdin"
  pass "Droid model probe cannot read the caller's stdin"
}

test_droid_bad_model_refuses_before_launch() {
  local id=droid-bad-model out rc
  make_droid_case bad-model "$id"
  out=$(FM_FAKE_DROID_REJECT_MODEL=invalid run_droid_spawn "$id" --model invalid)
  rc=$?
  expect_code 1 "$rc" "Droid should refuse a model its own catalog rejects"
  [ ! -e "$CASE_DIR/launch.log" ] || fail "Droid rejected model after a pane launch"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "Droid rejected model after task record creation"
  pass "Droid rejects a model before creating a worker endpoint"
}

test_raw_droid_command_does_not_arm_unused_hooks() {
  local id=droid-raw-1 out rc
  make_droid_case raw "$id"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" 'droid --auto high' --scout)
  rc=$?
  expect_code 0 "$rc" "raw Droid command should keep the raw-launch contract: $out"
  [ ! -e "$HOME_DIR/state/$id.busy-gen" ] || fail "raw Droid command armed a busy record with no hook writer"
  [ ! -e "$HOME_DIR/state/$id.droid-settings.json" ] || fail "raw Droid command wrote unused runtime settings"
  pass "raw Droid commands remain outside canonical hook arming"
}

test_droid_identity_and_control
test_droid_composer_envelope
test_droid_composer_requires_a_droid_process
test_droid_orca_composer_uses_the_live_screen
test_droid_launch_and_hooks
test_droid_trust_dialog_is_answered_once
test_droid_refuses_a_negative_trust_selection
test_droid_retries_one_transient_viewport_failure
test_droid_bounds_a_hung_viewport_read
test_droid_respects_disabled_hooks_policy
test_droid_omits_unsupported_model_effort
test_droid_omits_effort_without_explicit_model
test_droid_model_probe_detaches_stdin
test_droid_bad_model_refuses_before_launch
test_raw_droid_command_does_not_arm_unused_hooks
fm_test_cleanup "$TMP_ROOT"
