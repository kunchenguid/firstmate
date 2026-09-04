#!/usr/bin/env bash
# Portable behavior tests for the Google Antigravity CLI (`agy`) adapter.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-antigravity-harness)

clear_identity_env() {
  env -u ANTIGRAVITY_AGENT -u AI_AGENT -u CLAUDECODE -u GEMINI_CLI \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS \
    -u GROK_AGENT "$@"
}

test_marker_precedence_and_ai_agent_rejection() {
  local out
  out=$(ANTIGRAVITY_AGENT=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi AI_AGENT=pi "$HARNESS")
  [ "$out" = antigravity ] || fail "Antigravity's own marker must outrank inherited Pi identity, got '$out'"
  out=$(clear_identity_env AI_AGENT=antigravity "$HARNESS")
  [ "$out" != antigravity ] || fail "AI_AGENT must never claim Antigravity identity"
  out=$(clear_identity_env ANTIGRAVITY_AGENT=0 "$HARNESS")
  [ "$out" != antigravity ] || fail "only ANTIGRAVITY_AGENT=1 is the verified marker"
  pass "fm-harness.sh: Antigravity marker precedence rejects inherited AI_AGENT"
}

test_exact_agy_ancestry_only() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}" ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:-}" ;;
  *"ppid="*) printf '1\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(clear_identity_env FAKE_PS_COMM=/Users/u/.local/bin/agy FAKE_PS_ARGS='agy' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = antigravity ] || fail "exact agy ancestry must identify Antigravity, got '$out'"
  out=$(clear_identity_env FAKE_PS_COMM=agy-helper FAKE_PS_ARGS='agy-helper' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != antigravity ] || fail "agy-helper must not claim Antigravity identity"
  out=$(clear_identity_env FAKE_PS_COMM=node FAKE_PS_ARGS='node app.js --model agy' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != antigravity ] || fail "an unrelated argument mentioning agy must not claim identity"
  pass "fm-harness.sh: only exact agy ancestry claims Antigravity"
}

test_control_and_busy_contracts() {
  local out
  fm_control_harness_supported antigravity || fail "antigravity must be a supported harness"
  [ "$(fm_control_harness_family agy-1.1.26)" = antigravity ] || fail "agy* records must normalize to antigravity"
  [ "$(fm_control_interrupt_key antigravity)" = Escape ] || fail "Antigravity interrupt must be Escape"
  [ "$(fm_control_interrupt_repeat antigravity)" = 1 ] || fail "Antigravity interrupt must be one key"
  [ -z "$(fm_control_interrupt_clear_key antigravity)" ] || fail "Antigravity interrupt must not clear the composer"
  [ "$(fm_control_exit_command antigravity)" = /quit ] || fail "Antigravity exit must be /quit"
  fm_control_harness_supports_kind antigravity ship || fail "Antigravity must support workers"
  fm_control_harness_supports_kind antigravity scout || fail "Antigravity must support scouts"
  fm_control_harness_supports_kind antigravity secondmate || fail "Antigravity must support second mates"
  out=$(fm_control_harness_wiring_paths antigravity /wt /state task-a)
  [ "$out" = /state/task-a.antigravity-hooks/.agents/hooks.json ] \
    || fail "unexpected Antigravity wiring path: '$out'"
  printf 'working  esc to cancel\n' | fm_busy_lines_match antigravity \
    || fail "Antigravity's stable busy footer must match"
  ! printf 'Working...\n' | fm_busy_lines_match antigravity \
    || fail "Antigravity must not borrow Pi's busy signature"
  pass "control and busy owners carry Antigravity's verified mechanics"
}

test_separated_shell_glyph_requires_antigravity_identity() {
  local caps screen typed
  caps=$(printf 'styled=0\ncursor=0\nidentity=1\nrows=40')
  screen=$(printf '%s\n' '────────────────────' '>' '────────────────────')
  typed=$(printf '%s\n' '────────────────────' '> queued steer' '────────────────────')
  [ "$(fm_composer_classify_screen "$caps" "$screen")" = need-identity ] \
    || fail "the separated Antigravity shape must request live identity"
  [ "$(fm_composer_classify_screen "$caps" "$screen" '' $'antigravity\tidle')" = empty ] \
    || fail "idle Antigravity plus its separator pair must prove empty"
  [ "$(fm_composer_classify_screen "$caps" "$typed" '' $'antigravity\tidle')" = pending ] \
    || fail "typed Antigravity composer content must remain pending"
  [ "$(fm_composer_classify_screen "$caps" "$screen" '' $'pi\tidle')" = pending ] \
    || fail "Pi identity must not reinterpret a shell-like > as furniture"
  [ "$(fm_composer_classify_screen "$caps" "$screen" '' probe-absent)" = unknown ] \
    || fail "a separator pair with no live identity must remain unknown"
  [ "$(fm_composer_classify_screen "$caps" '>' '' $'antigravity\tidle')" = unknown ] \
    || fail "a bare > must remain a dead-shell prompt under Antigravity identity"
  pass "composer classifier gates Antigravity's > row on identity plus structure"
}

test_hook_transport_and_task_lifecycle() {
  local state id gen turn out
  state="$TMP_ROOT/hook-state"
  id=agy-hook
  turn="$state/$id.turn-ended"
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id") || fail "could not arm task activity"
  out=$(printf '{}\n' | "$ROOT/bin/fm-antigravity-hook.sh" task-busy "$state" "$id" "$gen")
  [ "$out" = '{}' ] || fail "PreInvocation task hook must emit an empty object"
  case "$(fm_busy_record_read "$state" "$id")" in busy\ antigravity-hook\ *) ;; *) fail "task hook did not publish busy" ;; esac
  out=$(printf '{}\n' | "$ROOT/bin/fm-antigravity-hook.sh" task-stop "$state" "$id" "$gen" "$turn")
  [ "$(printf '%s' "$out" | jq -r .decision)" = stop ] || fail "Stop hook must allow termination"
  [ -f "$turn" ] || fail "Stop hook must publish the turn-end edge"
  case "$(fm_busy_record_read "$state" "$id")" in idle\ antigravity-hook\ *) ;; *) fail "task hook did not settle activity" ;; esac
  jq -e '
    has("firstmate-sessionstart") and
    ."firstmate-sessionstart".PreInvocation[0].command == "../bin/fm-antigravity-hook.sh sessionstart" and
    ."firstmate-shell-seatbelts".PreToolUse[0].matcher == "run_command" and
    ."firstmate-delegation-seatbelt".PreToolUse[0].matcher == "*"
  ' "$ROOT/.agents/hooks.json" >/dev/null || fail "tracked Antigravity primary hooks have the wrong native schema"
  pass "Antigravity hook transport publishes task lifecycle and native primary wiring"
}

make_primary_fixture() {
  local fixture=$1
  mkdir -p "$fixture/state"
  printf '# Firstmate\n' > "$fixture/AGENTS.md"
  ln -s "$ROOT/bin" "$fixture/bin"
  git -C "$fixture" init -q
}

test_native_pretool_deny_transport() {
  local fixture payload out status
  fixture="$TMP_ROOT/primary"
  make_primary_fixture "$fixture"
  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"bin/fm-watch-arm.sh && echo bundled"}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-arm-pretool-check.sh" --antigravity)
  status=$?
  [ "$status" -eq 0 ] || fail "Antigravity deny transport must exit zero for the hook host"
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "watcher-arm seatbelt did not emit native deny"

  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"cd projects/example"}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-cd-pretool-check.sh" --antigravity)
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "cd seatbelt did not emit native deny"

  # invoke_subagent and send_message are the exact Antigravity 1.1.26 tool
  # names observed in a live Gemini delegation turn.
  payload='{"toolCall":{"name":"invoke_subagent","args":{}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-subagent-pretool-check.sh" --antigravity)
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "delegation seatbelt did not emit native deny"
  pass "Antigravity PreToolUse payloads receive native deny responses"
}

test_spawn_builds_canonical_antigravity_launch() {
  local case_dir home proj wt fakebin id launchlog out launch hooks
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  id=agy-spawn
  fm_test_spawn_home "$home" antigravity
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" agy-spawn-worktree \
    || fail "could not create the canonical Antigravity isolated worktree"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '1.1.26\n' ;;
  models) printf 'gemini-test-low\tGemini Test Low\ngemini-test-medium\tGemini Test Medium\nother-model\tOther Model\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/agy"
  : > "$launchlog"
  if ! out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --harness antigravity --model gemini-test-low --effort low \
    --mode no-mistakes --yolo off); then
    fail "Antigravity spawn failed: $out"
  fi
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--dangerously-skip-permissions" "spawn omitted autonomous permission mode"
  assert_contains "$launch" "--add-dir '$wt'" "spawn omitted the exact isolated project"
  assert_contains "$launch" "--add-dir '$home/state/$id.antigravity-hooks'" "spawn omitted the hook overlay"
  assert_contains "$launch" "--model 'gemini-test-low'" "spawn omitted the selected Gemini model"
  assert_contains "$launch" "--effort 'low'" "spawn omitted native effort"
  assert_contains "$launch" "--prompt-interactive" "spawn did not select the persistent TUI"
  assert_contains "$launch" "env -u AI_AGENT" "spawn did not clear inherited generic identity"
  hooks="$home/state/$id.antigravity-hooks/.agents/hooks.json"
  jq -e '."firstmate-task-lifecycle".PreInvocation[0].command and ."firstmate-task-lifecycle".Stop[0].command' \
    "$hooks" >/dev/null || fail "spawn did not write native task hook schema"
  jq -e '."firstmate-task-lifecycle".PreInvocation[0].command | contains("fm-antigravity-hook.sh") and contains("task-busy")' \
    "$hooks" >/dev/null || fail "task hook omitted busy transport"
  jq -e '."firstmate-task-lifecycle".Stop[0].command | contains("fm-antigravity-hook.sh") and contains("task-stop")' \
    "$hooks" >/dev/null || fail "task hook omitted Stop transport"
  pass "fm-spawn.sh builds the canonical Antigravity worker launch and isolated hooks"
}

test_spawn_defaults_to_gemini_and_enforces_verified_boundaries() {
  local case_dir home proj proj_other proj_old wt fakebin id launchlog out launch status
  case_dir="$TMP_ROOT/spawn-gemini-only"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  id=agy-default
  fm_test_spawn_home "$home" antigravity
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" agy-default-worktree \
    || fail "could not create the default-model isolated worktree"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '1.1.26\n' ;;
  models) printf 'gemini-test-low\tGemini Test Low\ngemini-test-medium\tGemini Test Medium\nother-model\tOther Model\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/agy"
  : > "$launchlog"
  if ! out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --harness antigravity --effort medium --mode no-mistakes --yolo off); then
    fail "default-model Antigravity spawn failed: $out"
  fi
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--model 'gemini-test-medium'" \
    "default Antigravity selection did not prefer the requested Gemini effort"
  assert_grep 'model=gemini-test-medium' "$home/state/$id.meta" \
    "task record did not persist the concrete Gemini selection"

  id=agy-other-family
  wt="$case_dir/wt-other"
  proj_other="$case_dir/project-other"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj_other" "$wt" agy-other-worktree \
    || fail "could not create the non-Gemini refusal worktree"
  : > "$launchlog"
  set +e
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj_other" --harness antigravity --model other-model --effort low \
    --mode no-mistakes --yolo off)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Antigravity must reject a model outside the Gemini family"
  assert_contains "$out" "adapter is Gemini-only" "non-Gemini refusal did not explain the boundary"
  [ ! -s "$launchlog" ] || fail "a refused non-Gemini model must launch no pane command"

  id=agy-old-version
  wt="$case_dir/wt-old"
  proj_old="$case_dir/project-old"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj_old" "$wt" agy-old-worktree \
    || fail "could not create the old-version refusal worktree"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '1.1.25\n' ;;
  models) printf 'gemini-test-low\tGemini Test Low\n' ;;
esac
exit 0
SH
  : > "$launchlog"
  set +e
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj_old" --harness antigravity --model gemini-test-low --effort low \
    --mode no-mistakes --yolo off)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Antigravity must reject a CLI older than 1.1.26"
  assert_contains "$out" "1.1.26 or newer is required" \
    "old-version refusal did not explain the verified floor"
  [ ! -s "$launchlog" ] || fail "a refused old Antigravity CLI must launch no pane command"
  pass "fm-spawn.sh defaults to Gemini and enforces model and version boundaries"
}

test_marker_precedence_and_ai_agent_rejection
test_exact_agy_ancestry_only
test_control_and_busy_contracts
test_separated_shell_glyph_requires_antigravity_identity
test_hook_transport_and_task_lifecycle
test_native_pretool_deny_transport
test_spawn_builds_canonical_antigravity_launch
test_spawn_defaults_to_gemini_and_enforces_verified_boundaries
