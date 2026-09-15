#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-ready.sh and the claude spawn that calls it.
#
# Claude Code shows a once-per-machine bypass-permissions confirmation that
# firstmate cannot answer: the dialog's selection starts on "No, exit" and
# firstmate's key plane carries only Enter, Escape and C-c, so a sent Enter
# ends the session. A worker launched on a machine that has never accepted it
# sits on that dialog until the watcher reports it wedged. The gate exists so
# the operator gets one setup instruction instead of repeated escalations, and
# so no endpoint is allocated for a worker that cannot reach its brief.
#
# Workspace trust is the separate per-path gate and lives in
# tests/fm-claude-trust.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-ready)
READY="$ROOT/bin/fm-claude-ready.sh"

# run_ready <config-dir> [project]: check against an isolated Claude config.
run_ready() {
  local config=$1 project=${2:-}
  CLAUDE_CONFIG_DIR="$config" FM_CLAUDE_BYPASS_READY='' "$READY" check "$project" 2>&1
}

# Machine-wide managed settings could record the acceptance for every case
# here, which would make the refusals vacuous. Ask the check itself once and
# report rather than pass silently.
managed_settings_already_ready() {
  local probe="$TMP_ROOT/managed-probe"
  mkdir -p "$probe"
  run_ready "$probe" >/dev/null 2>&1
}

test_unaccepted_machine_is_refused_with_the_setup_command() {
  local config out status
  if managed_settings_already_ready; then
    pass "fm-claude-ready.sh: unaccepted-machine refusal (skipped: this machine records the acceptance machine-wide)"
    return 0
  fi
  config="$TMP_ROOT/unaccepted/claude-config"
  mkdir -p "$config"

  out=$(run_ready "$config")
  status=$?
  [ "$status" -ne 0 ] || fail "an unprovisioned machine reported ready: $out"
  assert_contains "$out" "has not accepted Claude Code's bypass-permissions confirmation" \
    "the refusal did not say what is missing"
  assert_contains "$out" "claude --dangerously-skip-permissions" \
    "the refusal did not name the command that provisions the machine"
  pass "fm-claude-ready.sh: an unaccepted machine is refused with its setup command"
}

test_accepted_machine_is_ready() {
  local config out status
  config="$TMP_ROOT/accepted/claude-config"
  mkdir -p "$config"
  printf '{"skipDangerousModePermissionPrompt":true}\n' > "$config/settings.json"

  out=$(run_ready "$config")
  status=$?
  expect_code 0 "$status" "an accepted machine was refused: $out"
  assert_contains "$out" "ready:" "the accepted machine did not report readiness"
  pass "fm-claude-ready.sh: a machine that accepted the confirmation reads as ready"
}

test_unparseable_settings_do_not_read_as_accepted() {
  local config out status
  if managed_settings_already_ready; then
    pass "fm-claude-ready.sh: unparseable-settings refusal (skipped: this machine records the acceptance machine-wide)"
    return 0
  fi
  config="$TMP_ROOT/corrupt/claude-config"
  mkdir -p "$config"
  printf 'skipDangerousModePermissionPrompt: true\n' > "$config/settings.json"

  out=$(run_ready "$config")
  status=$?
  [ "$status" -ne 0 ] || fail "settings that are not JSON were read as acceptance: $out"
  pass "fm-claude-ready.sh: settings that are not JSON never read as acceptance"
}

# A tmux stub that records the windows it creates, so the refusal can be shown
# to arrive before any endpoint exists rather than after one is allocated.
make_ready_fakebin() {
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
  new-window)
    printf '%s\n' "new-window $*" >> "${FM_FAKE_WINDOW_LOG:?FM_FAKE_WINDOW_LOG unset}"
    exit 0
    ;;
  has-session|new-session|set-window-option|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# The dispatch half: a claude spawn on an unprovisioned machine must refuse
# before allocating an endpoint, instead of launching a worker that stops on
# the dialog and is escalated as wedged.
test_claude_spawn_refuses_before_allocating_an_endpoint() {
  local case_dir home proj wt config fakebin log id out status
  case_dir="$TMP_ROOT/spawn-refusal"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  log="$case_dir/window-log"
  id="claudeready$$"

  if managed_settings_already_ready; then
    pass "fm-spawn.sh: claude bypass-readiness refusal (skipped: this machine records the acceptance machine-wide)"
    return 0
  fi

  mkdir -p "$config"
  : > "$log"
  fakebin=$(make_ready_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-ready
  fm_test_spawn_brief "$home" "$id"

  out=$(FM_TEST_CLAUDE_BYPASS_UNREADY=1 FM_TEST_CLAUDE_CONFIG_DIR="$config" \
    FM_FAKE_WINDOW_LOG="$log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a claude spawn on an unprovisioned machine reported success: $out"
  assert_contains "$out" "claude --dangerously-skip-permissions" \
    "the refused spawn did not carry the setup command"
  assert_absent "$home/state/$id.meta" "a refused spawn published a task record"
  if grep -q 'new-window' "$log" 2>/dev/null; then
    fail "a refused spawn allocated an endpoint before checking bypass readiness"
  fi
  [ ! -e "/tmp/fm-$id" ] \
    || { rm -rf "/tmp/fm-$id"; fail "a refused spawn stranded a temp root no teardown can find"; }
  pass "fm-spawn.sh: a claude spawn refuses before allocating an endpoint when the machine is unprovisioned"
}

test_unaccepted_machine_is_refused_with_the_setup_command
test_accepted_machine_is_ready
test_unparseable_settings_do_not_read_as_accepted
test_claude_spawn_refuses_before_allocating_an_endpoint

printf '\nall claude readiness tests passed\n'
