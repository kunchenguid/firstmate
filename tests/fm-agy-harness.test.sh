#!/usr/bin/env bash
# Behavior tests for the agy crewmate/scout adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-$PATH}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{pane_id}"*) printf '%s\n' '%1'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
  capture-pane) printf 'shell\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/agy"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 dir home proj wt fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/worktree"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise agy dispatch.

## Firstmate spec
Verify the agy harness behavior under test.
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  : > "$dir/launch.log"
  printf '%s|%s|%s|%s|%s\n' "$dir" "$home" "$proj" "$wt" "$fakebin"
}

run_spawn_as() {
  local dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6 harness=$7
  shift 7
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX='fake,1,0' \
    FM_FAKE_LAUNCH_LOG="$dir/launch.log" PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness "$harness" "$@" 2>&1
}

run_spawn() {
  local dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  run_spawn_as "$dir" "$home" "$proj" "$wt" "$fakebin" "$id" agy "$@"
}

test_spawn_writes_hooks_and_resolves_launch_axes() {
  local rec dir home proj wt fakebin id out rc launch hooks pre stop meta
  id="agy-launch-$$"
  rec=$(make_case launch "$id")
  IFS='|' read -r dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$dir" "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --model gemini-3.8-flash-low --effort high)
  rc=$?
  expect_code 0 "$rc" "agy spawn should succeed"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"
  launch=$(<"$dir/launch.log")
  assert_contains "$launch" "$fakebin/agy" "agy launch did not use the resolved executable"
  assert_contains "$launch" "--model 'gemini-3.8-flash-low'" "agy launch omitted the requested model"
  assert_contains "$launch" "--effort 'high'" "agy launch omitted the supported effort"
  assert_contains "$launch" '--dangerously-skip-permissions' "agy launch omitted permission bypass"
  assert_contains "$launch" ' -i ' "agy launch did not use interactive prompt mode"
  assert_contains "$launch" 'encode launch-brief' "agy launch did not use the canonical brief encoder"
  assert_not_contains "$launch" ' -p ' "agy launch used one-shot print mode"

  hooks="$wt/.agents/hooks.json"
  assert_present "$hooks" "agy spawn did not write the workspace-local hooks file"
  jq -e '."fm-firstmate".PreInvocation[0].type == "command" and ."fm-firstmate".Stop[0].type == "command"' "$hooks" >/dev/null \
    || fail "agy hooks file did not contain command PreInvocation and Stop hooks"
  assert_not_contains "$(<"$hooks")" '.gemini/config/hooks.json' \
    "agy spawn referenced the machine-global hooks configuration"

  pre=$(jq -r '."fm-firstmate".PreInvocation[0].command' "$hooks")
  stop=$(jq -r '."fm-firstmate".Stop[0].command' "$hooks")
  fm_busy_classify tmux fake agy "$id" "$home/state" | grep -q '^busy fm-spawn$' \
    || fail "agy spawn did not seed its launch turn as busy"
  sh -c "$pre"
  fm_busy_classify tmux fake agy "$id" "$home/state" | grep -q '^busy agy-hook$' \
    || fail "agy PreInvocation hook did not keep the task busy"
  sh -c "$stop"
  fm_busy_classify tmux fake agy "$id" "$home/state" | grep -q '^idle agy-hook$' \
    || fail "agy Stop hook did not close the task busy state"
  assert_present "$home/state/$id.turn-ended" "agy Stop hook did not touch the turn-end marker"
  meta="$home/state/$id.meta"
  assert_grep 'model=gemini-3.8-flash-low' "$meta" "agy metadata lost the model"
  assert_grep 'effort=high' "$meta" "agy metadata lost the effort"
  pass "fm-spawn: agy writes task-local hooks and resolves interactive model/effort launch flags"
}

test_unsupported_effort_is_recorded_and_omitted() {
  local rec dir home proj wt fakebin id out rc launch
  id="agy-effort-$$"
  rec=$(make_case effort "$id")
  IFS='|' read -r dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$dir" "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "agy spawn should tolerate record-and-omit effort"
  launch=$(<"$dir/launch.log")
  assert_not_contains "$launch" '--effort' "agy launch passed an unsupported effort"
  assert_grep 'effort=xhigh' "$home/state/$id.meta" "agy metadata did not retain the unsupported effort"
  pass "fm-spawn: agy records unsupported effort while omitting it from the CLI"
}

test_secondmate_is_refused_and_control_is_key_based() {
  local rec dir home proj wt fakebin id out rc
  id="agy-secondmate-$$"
  rec=$(make_case secondmate "$id")
  IFS='|' read -r dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$dir" "$home" "$proj" "$wt" "$fakebin" "$id" --secondmate)
  rc=$?
  [ "$rc" -ne 0 ] || fail "agy was accepted as a secondmate"
  assert_contains "$out" 'crewmate/scout adapter only' "agy secondmate refusal did not explain the boundary"
  [ "$(fm_control_harness_family agy)" = agy ] || fail "agy recorded family did not resolve"
  fm_control_harness_family agyd && fail "an agy-containing command must not claim the agy adapter family"
  [ "$(fm_control_interrupt_key agy)" = C-c ] || fail "agy interrupt key was not Ctrl+C"
  [ "$(fm_control_exit_command agy)" = C-d ] || fail "agy exit command was not Ctrl+D"
  fm_control_harness_supports_kind agy ship || fail "agy should support ship tasks"
  fm_control_harness_supports_kind agy scout || fail "agy should support scout tasks"
  fm_control_harness_supports_kind agy secondmate && fail "agy should not support secondmates"
  pass "agy is scoped to crewmate/scout control and uses a native exit key"
}

test_teardown_removes_workspace_hooks() {
  local rec dir home proj wt fakebin id out rc
  id="agy-cleanup-$$"
  rec=$(make_case cleanup "$id")
  IFS='|' read -r dir home proj wt fakebin <<EOF
$rec
EOF
  run_spawn "$dir" "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "agy spawn for teardown test failed"
  assert_present "$wt/.agents/hooks.json" "agy teardown fixture did not have a hooks file"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$BASE_PATH" "$TEARDOWN" "$id" --force 2>&1)
  rc=$?
  expect_code 0 "$rc" "agy teardown should succeed"
  assert_absent "$wt/.agents/hooks.json" "agy workspace hooks survived teardown"
  assert_absent "$home/state/$id.meta" "agy metadata survived teardown"
  pass "fm-teardown: agy removes its task-local hooks file"
}

test_teardown_leaves_a_non_agy_tasks_workspace_hooks() {
  local rec dir home proj wt fakebin id out rc owned
  id="claude-hooks-$$"
  owned='{"project-owned":{"Stop":[]}}'
  rec=$(make_case foreign-hooks "$id")
  IFS='|' read -r dir home proj wt fakebin <<EOF
$rec
EOF
  fm_fake_exit0 "$fakebin" claude
  out=$(run_spawn_as "$dir" "$home" "$proj" "$wt" "$fakebin" "$id" claude --mode no-mistakes --yolo off) \
    || fail "claude spawn for the foreign hooks test failed"$'\n'"$out"
  mkdir -p "$wt/.agents"
  printf '%s\n' "$owned" > "$wt/.agents/hooks.json"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$BASE_PATH" "$TEARDOWN" "$id" --force 2>&1)
  rc=$?
  expect_code 0 "$rc" "claude teardown should succeed"$'\n'"$out"
  assert_present "$wt/.agents/hooks.json" "a non-agy task's workspace hooks file was deleted by teardown"
  [ "$(<"$wt/.agents/hooks.json")" = "$owned" ] \
    || fail "a non-agy task's workspace hooks file was rewritten by teardown"
  pass "fm-teardown: a non-agy task's .agents/hooks.json survives teardown"
}

test_spawn_writes_hooks_and_resolves_launch_axes
test_unsupported_effort_is_recorded_and_omitted
test_secondmate_is_refused_and_control_is_key_based
test_teardown_removes_workspace_hooks
test_teardown_leaves_a_non_agy_tasks_workspace_hooks
