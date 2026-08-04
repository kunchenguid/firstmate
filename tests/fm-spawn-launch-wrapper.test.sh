#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's optional config/launch-wrapper prefix.
#
# The wrapper exists so an operator can start the pane's harness under their own
# launcher (docs/configuration.md "Launch wrapper"). These tests drive fm-spawn
# through launch construction with a fake tmux pane and a real isolated git
# worktree, capturing the literal command sent with `tmux send-keys -l`, so they
# pin the command firstmate would actually type without starting any harness.
#
# The load-bearing guarantees are: an absent wrapper leaves the launch
# byte-identical to the no-wrapper behavior; a present wrapper lands between the
# env-assignment prefixes and the harness invocation with __TASKID__ replaced;
# and the harness's own placeholders still substitute inside the wrapped command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-wrapper)

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
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# wrapper tests are about launch construction, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# The exact claude launch fm-spawn types with no wrapper and no CLAUDE_CONFIG_DIR.
canonical_claude_launch() {
  local home=$1 id=$2
  printf '%s' "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$home/data/$id/brief.md')\""
}

assert_launch_equals() {
  local actual=$1 expected=$2 msg=$3
  [ "$actual" = "$expected" ] || fail "$msg"$'\n'"expected: $expected"$'\n'"actual:   $actual"
}

test_absent_wrapper_leaves_launch_unchanged() {
  local rec id out status launch expected
  id=wrapper-absent-w1
  rec=$(make_spawn_case wrapper-absent claude "$id")
  read_case_record "$rec"
  assert_absent "$HOME_DIR/config/launch-wrapper" "case setup should leave config/launch-wrapper absent"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without a launch wrapper should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  launch=$(cat "$LAUNCH_LOG")
  expected=$(canonical_claude_launch "$HOME_DIR" "$id")
  assert_launch_equals "$launch" "$expected" \
    "absent config/launch-wrapper changed the launch fm-spawn types"
  pass "an absent launch wrapper leaves the launch byte-identical to the no-wrapper behavior"
}

test_blank_and_comment_only_wrapper_is_a_no_op() {
  local rec id out status launch expected
  id=wrapper-blank-w2
  rec=$(make_spawn_case wrapper-blank claude "$id")
  read_case_record "$rec"
  printf '%s\n' '' '# only a comment' '   ' '' > "$HOME_DIR/config/launch-wrapper"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with a comment-only launch wrapper should succeed"
  launch=$(cat "$LAUNCH_LOG")
  expected=$(canonical_claude_launch "$HOME_DIR" "$id")
  assert_launch_equals "$launch" "$expected" \
    "a blank/comment-only config/launch-wrapper must behave exactly like an absent one"
  pass "a blank or comment-only launch wrapper is a no-op"
}

test_wrapper_prefixes_claude_launch_with_task_id_substituted() {
  local rec id out status launch expected
  id=wrapper-claude-w3
  rec=$(make_spawn_case wrapper-claude claude "$id")
  read_case_record "$rec"
  printf '%s\n' 'seat-launcher exec --worker __TASKID__ --' > "$HOME_DIR/config/launch-wrapper"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with a launch wrapper should succeed"
  launch=$(cat "$LAUNCH_LOG")
  expected="seat-launcher exec --worker $id -- $(canonical_claude_launch "$HOME_DIR" "$id")"
  assert_launch_equals "$launch" "$expected" \
    "launch wrapper did not prefix the claude launch with __TASKID__ substituted"
  # Stated separately from the equality above so a future launch-template change
  # cannot quietly drop the brief while the equality assertion is re-baselined.
  assert_contains "$launch" "< '$HOME_DIR/data/$id/brief.md'" \
    "harness __BRIEF__ substitution was lost inside the wrapped command"
  pass "a launch wrapper prefixes the claude launch with __TASKID__ substituted and __BRIEF__ intact"
}

test_wrapper_uses_first_meaningful_line_trimmed() {
  local rec id out status launch expected
  id=wrapper-firstline-w4
  rec=$(make_spawn_case wrapper-firstline claude "$id")
  read_case_record "$rec"
  printf '%s\n' '# seat binding for this home' '' '   seat-launcher --seat c --   ' \
    'seat-launcher --seat SHOULD-NOT-BE-USED --' > "$HOME_DIR/config/launch-wrapper"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with a multi-line launch wrapper should succeed"
  launch=$(cat "$LAUNCH_LOG")
  expected="seat-launcher --seat c -- $(canonical_claude_launch "$HOME_DIR" "$id")"
  assert_launch_equals "$launch" "$expected" \
    "launch wrapper did not use only the first non-empty, non-comment line, whitespace-trimmed"
  assert_not_contains "$launch" "SHOULD-NOT-BE-USED" \
    "launch wrapper used a later line of config/launch-wrapper"
  pass "the launch wrapper uses only the first non-empty, non-comment line, whitespace-trimmed"
}

test_wrapper_sits_after_claude_config_dir_prefix() {
  local rec id out status launch expected
  id=wrapper-cfgdir-w5
  rec=$(make_spawn_case wrapper-cfgdir claude "$id")
  read_case_record "$rec"
  printf '%s\n' 'seat-launcher exec --worker __TASKID__ --' > "$HOME_DIR/config/launch-wrapper"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with a wrapper and CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  # The env assignment must stay leftmost so it is inherited THROUGH the wrapper
  # into the harness; a wrapper placed ahead of it would be exec'd as the command
  # named "CLAUDE_CONFIG_DIR=...".
  expected="CLAUDE_CONFIG_DIR='/opt/test/claude-work' seat-launcher exec --worker $id -- $(canonical_claude_launch "$HOME_DIR" "$id")"
  assert_launch_equals "$launch" "$expected" \
    "launch wrapper was not placed between the CLAUDE_CONFIG_DIR assignment and the harness"
  pass "the launch wrapper sits after the CLAUDE_CONFIG_DIR assignment and before the harness"
}

test_wrapper_applies_to_a_non_claude_harness() {
  local rec id out status launch
  id=wrapper-pi-w6
  rec=$(make_spawn_case wrapper-pi pi "$id")
  read_case_record "$rec"
  printf '%s\n' 'seat-launcher exec --worker __TASKID__ --' > "$HOME_DIR/config/launch-wrapper"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn with a launch wrapper should succeed"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "seat-launcher exec --worker $id -- FM_PI_HARNESS=pi "*) ;;
    *) fail "pi launch did not start with the wrapper ahead of the harness invocation"$'\n'"actual: $launch" ;;
  esac
  assert_contains "$launch" "-e '$HOME_DIR/state/$id.pi-ext.ts'" \
    "harness __PIEXT__ substitution was lost inside the wrapped pi command"
  assert_contains "$launch" "< '$HOME_DIR/data/$id/brief.md'" \
    "harness __BRIEF__ substitution was lost inside the wrapped pi command"
  pass "the launch wrapper applies to a non-claude harness with its placeholders intact"
}

test_wrapper_sits_after_secondmate_home_env_prefixes() {
  local rec id sm out status launch
  id=wrapper-secondmate-w7
  rec=$(make_spawn_case wrapper-secondmate codex "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf '%s\n' 'seat-launcher exec --worker __TASKID__ --' > "$HOME_DIR/config/launch-wrapper"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn with a launch wrapper should succeed"
  launch=$(cat "$LAUNCH_LOG")
  # FM_HOME and the override-clearing assignments must reach the secondmate agent
  # through the wrapper, so they stay ahead of it exactly like CLAUDE_CONFIG_DIR.
  expected="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_PUBLIC_FOLLOWUP_PRIMARY_HOME='$HOME_DIR' FM_HOME='$sm' FM_TRACE_CONTEXT=off seat-launcher exec --worker $id -- "
  case "$launch" in
    "$expected"*) ;;
    *) fail "secondmate launch did not place the wrapper after the home env assignments"$'\n'"expected prefix: $expected"$'\n'"actual: $launch" ;;
  esac
  pass "the launch wrapper sits after the secondmate home env assignments and before the harness"
}

test_absent_wrapper_leaves_launch_unchanged
test_blank_and_comment_only_wrapper_is_a_no_op
test_wrapper_prefixes_claude_launch_with_task_id_substituted
test_wrapper_uses_first_meaningful_line_trimmed
test_wrapper_sits_after_claude_config_dir_prefix
test_wrapper_applies_to_a_non_claude_harness
test_wrapper_sits_after_secondmate_home_env_prefixes

echo "# all fm-spawn-launch-wrapper tests passed"
