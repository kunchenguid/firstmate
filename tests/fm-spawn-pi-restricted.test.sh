#!/usr/bin/env bash
# Tests for the restricted direct-DeepSeek Pi launch lane (bin/fm-spawn.sh's
# pi_restricted_model()) and its tracked tool extension
# (bin/fm-pi-restricted-tools.ts).
#
# Launch-construction tests drive fm-spawn through meta writing with a fake
# tmux pane and a real isolated git worktree, mirroring
# tests/fm-spawn-dispatch-profile.test.sh. The fake tmux captures both the
# literal launch command (`send-keys -l`) and the plain text-line sends
# (`send-keys -t <target> <text> Enter`, used for the GOTMPDIR and
# FM_RESTRICTED_TASK_CONFIG exports), so both the launch string and the
# per-spawn config env var can be asserted on without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
EXT="$ROOT/bin/fm-pi-restricted-tools.ts"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-restricted)
RESTRICTED_MODEL="deepseek/deepseek-v4-pro"

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
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    if [ -n "${FM_FAKE_TEXTLINE_LOG:-}" ]; then
      case "$*" in
        *' -l '*) : ;;
        *) printf '%s\n' "$4" >> "$FM_FAKE_TEXTLINE_LOG" ;;
      esac
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog textlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  textlog="$case_dir/textline.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$textlog"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 textlog=$5
  shift 5
  : > "$launchlog"
  : > "$textlog"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_TEXTLINE_LOG="$textlog" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG TEXT_LOG <<EOF
$1
EOF
}

test_pi_restricted_model_gets_restricted_launch_and_config_env() {
  local rec id out status launch textlines config_line
  id=pi-restricted-ship-z1
  rec=$(make_spawn_case restricted-ship pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TEXT_LOG" "$id" "$PROJ_DIR" --model "$RESTRICTED_MODEL")
  status=$?
  expect_code 0 "$status" "restricted-model pi ship spawn should succeed"
  assert_grep "model=$RESTRICTED_MODEL" "$HOME_DIR/state/$id.meta" "meta missing restricted model"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --model '$RESTRICTED_MODEL' --no-builtin-tools --tools public_fetch,write_report,append_status,complete_scout --no-context-files --no-skills --no-prompt-templates --no-extensions --no-session -e " \
    "restricted pi launch is missing the structural lockdown flags"
  assert_contains "$launch" "$HOME_DIR/state/$id.pi-ext.ts" "restricted pi launch dropped the trusted turn-end extension"
  assert_contains "$launch" "$ROOT/bin/fm-pi-restricted-tools.ts" "restricted pi launch dropped the tracked restricted-tools extension"
  assert_not_contains "$launch" "read_task_file" "restricted pi launch allowlists a tool that was never registered"

  textlines=$(cat "$TEXT_LOG")
  assert_contains "$textlines" "export GOTMPDIR=" "restricted pi spawn dropped the ordinary GOTMPDIR export"
  config_line=$(printf '%s\n' "$textlines" | grep '^export FM_RESTRICTED_TASK_CONFIG=' || true)
  [ -n "$config_line" ] || fail "restricted pi spawn did not export FM_RESTRICTED_TASK_CONFIG"
  assert_contains "$config_line" "\"taskId\":\"$id\"" "restricted task config missing taskId"
  assert_contains "$config_line" "\"reportPath\":\"$HOME_DIR/data/$id/report.md\"" "restricted task config missing reportPath"
  assert_contains "$config_line" "\"statusPath\":\"$HOME_DIR/state/$id.status\"" "restricted task config missing statusPath"
  pass "restricted DeepSeek model gets the structurally locked-down pi launch and its trusted config env"
}

test_pi_restricted_model_also_applies_to_scout() {
  local rec id out status launch
  id=pi-restricted-scout-z2
  rec=$(make_spawn_case restricted-scout pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TEXT_LOG" "$id" "$PROJ_DIR" --model "$RESTRICTED_MODEL" --scout)
  status=$?
  expect_code 0 "$status" "restricted-model pi scout spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--no-builtin-tools" "scout kind did not get the restricted lane"
  pass "restricted DeepSeek model also locks down a scout spawn, not only ship"
}

test_pi_non_restricted_model_keeps_ordinary_launch() {
  local rec id out status launch textlines
  id=pi-ordinary-z3
  rec=$(make_spawn_case ordinary pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TEXT_LOG" "$id" "$PROJ_DIR" --model openai-codex/gpt-5.6-sol)
  status=$?
  expect_code 0 "$status" "ordinary pi model spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  expected="pi --model 'openai-codex/gpt-5.6-sol' -e '$HOME_DIR/state/$id.pi-ext.ts' \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "ordinary pi launch changed for a non-restricted model"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  textlines=$(cat "$TEXT_LOG")
  assert_not_contains "$textlines" "FM_RESTRICTED_TASK_CONFIG" "ordinary pi spawn should not export the restricted task config"
  pass "a non-restricted model keeps the ordinary unrestricted pi crewmate launch byte-identical"
}

test_pi_no_model_keeps_ordinary_launch() {
  local rec id out status launch
  id=pi-nomodel-z4
  rec=$(make_spawn_case nomodel pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TEXT_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn with no --model should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--no-builtin-tools" "a spawn with no model at all must never get the restricted lane"
  pass "no --model at all keeps the ordinary pi crewmate launch"
}

test_pi_secondmate_ignores_restricted_model_name() {
  local rec id out status launch sm
  id=pi-restricted-secondmate-z5
  rec=$(make_spawn_case restricted-secondmate pi "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$TEXT_LOG" "$id" "$sm" --model "$RESTRICTED_MODEL" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn naming the restricted model string should still succeed"
  assert_contains "$out" "spawned $id harness=pi kind=secondmate" "secondmate spawn output did not confirm secondmate kind"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "/.pi/extensions/fm-primary-turnend-guard.ts" "secondmate launch dropped its ordinary turn-end guard extension"
  assert_contains "$launch" "/.pi/extensions/fm-primary-pi-watch.ts" "secondmate launch dropped its ordinary watch extension"
  assert_not_contains "$launch" "--no-builtin-tools" "a secondmate must never get the restricted crewmate lane, even naming the same model string"
  pass "kind=secondmate never enters the restricted lane, even when --model matches the restricted allowlist"
}

test_restricted_tools_extension_is_tracked_and_shell_free() {
  local text
  assert_present "$EXT" "tracked restricted-tools pi extension is missing"
  text=$(cat "$EXT")
  assert_contains "$text" 'name: "public_fetch"' "restricted extension missing public_fetch tool"
  assert_contains "$text" 'name: "write_report"' "restricted extension missing write_report tool"
  assert_contains "$text" 'name: "append_status"' "restricted extension missing append_status tool"
  assert_contains "$text" 'name: "complete_scout"' "restricted extension missing complete_scout tool"
  assert_contains "$text" "FM_RESTRICTED_TASK_CONFIG" "restricted extension does not read its trusted per-spawn config"
  assert_contains "$text" "terminate: true" "restricted extension's decision gate does not terminate on an unresolved decision"
  assert_not_contains "$text" "pi.exec" "restricted extension must never shell out"
  assert_not_contains "$text" "child_process" "restricted extension must never shell out"
  assert_not_contains "$text" "node:child_process" "restricted extension must never shell out"
  pass "the restricted-tools pi extension is a static tracked file exposing exactly the four scoped tools with no shell-out"
}

test_pi_restricted_model_allowlist_is_narrow() {
  local text
  text=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$text" 'deepseek/deepseek-v4-pro) return 0 ;;' "pi_restricted_model lost the verified DeepSeek model"
  assert_not_contains "$text" "deepseek/deepseek-v4-flash" "pi_restricted_model added the flash model without a documented task-class justification"
  pass "pi_restricted_model stays narrow to the one verified DeepSeek model"
}

test_pi_restricted_model_gets_restricted_launch_and_config_env
test_pi_restricted_model_also_applies_to_scout
test_pi_non_restricted_model_keeps_ordinary_launch
test_pi_no_model_keeps_ordinary_launch
test_pi_secondmate_ignores_restricted_model_name
test_restricted_tools_extension_is_tracked_and_shell_free
test_pi_restricted_model_allowlist_is_narrow

echo "# all fm-spawn-pi-restricted tests passed"
