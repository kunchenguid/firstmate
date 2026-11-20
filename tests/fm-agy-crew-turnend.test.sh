#!/usr/bin/env bash
# Integration tests for Antigravity CLI (agy) crewmate turn-end lifecycle,
# busy-state notifications, watcher continuity, and secondmate enablement.
#
# Covers:
#   1. Crewmate spawn installs semantic busy wiring in $WT/.agents/plugins/fm-crew-busy/hooks.json
#      and excludes it from git tracking.
#   2. Stop hook execution touches state/<id>.turn-ended, records idle via
#      fm-busy-event.sh, and outputs {"decision":"allow"}.
#   3. PreInvocation hook records busy and outputs {}.
#   4. Worktree with pre-existing .agents/hooks.json leaves it untouched and isolates fm-crew-busy in plugin.
#   5. Teardown and relaunch clean up fm-crew-busy wiring while preserving other hooks.
#   6. Secondmate launch allows agy and pre-registers secondmate home trust.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-crew-turnend)
fm_git_identity fmtest fmtest@example.invalid

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_agy_crew_spawn_installs_hooks_and_turnend_notifies() {
  local rec id=crew-turn-1 out state hooks stop_cmd preinv_cmd excl
  rec=$(make_case spawn-hooks "$id")
  read_case "$rec"

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "agy crewmate spawn should succeed: $out"

  state="$HOME_DIR/state"
  assert_present "$state/$id.busy-gen" "agy spawn did not mint busy-gen"
  local plugin_dir="$WT_DIR/.agents/plugins/fm-crew-busy"
  hooks="$plugin_dir/hooks.json"
  assert_present "$hooks" "agy spawn did not create plugin hooks.json"
  assert_present "$plugin_dir/plugin.json" "agy spawn did not create plugin.json"

  # Excluded from git
  excl=$(cd "$WT_DIR" && git rev-parse --git-path info/exclude)
  [ -f "$excl" ] || fail "git exclude file '$excl' does not exist"
  grep -qxF '.agents/plugins/fm-crew-busy/' "$excl" || fail ".agents/plugins/fm-crew-busy/ was not added to git exclude: $(cat "$excl")"

  jq -e '."fm-crew-busy".Stop' "$hooks" >/dev/null || fail "missing Stop hook"
  jq -e '."fm-crew-busy".PreInvocation' "$hooks" >/dev/null || fail "missing PreInvocation hook"

  stop_cmd=$(jq -r '."fm-crew-busy".Stop[0].command' "$hooks")
  preinv_cmd=$(jq -r '."fm-crew-busy".PreInvocation[0].command' "$hooks")

  # 1. State right after spawn: busy fm-spawn
  out=$(fm_busy_classify tmux fake:w agy "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "initial state must be busy fm-spawn, got '$out'"

  # 2. Fire Stop hook -> touches turn-ended, transitions to idle agy-hook, allows stop
  rm -f "$state/$id.turn-ended"
  out=$(eval "$stop_cmd")
  [ -f "$state/$id.turn-ended" ] || fail "Stop hook did not touch turn-ended notification marker"
  [ "$(printf '%s' "$out" | jq -r '.decision')" = "allow" ] || fail "Stop hook did not emit allow decision: $out"
  out=$(fm_busy_classify tmux fake:w agy "$id" "$state")
  [ "$out" = "idle agy-hook" ] || fail "state after Stop hook must be idle agy-hook, got '$out'"

  # 3. Fire PreInvocation hook -> transitions to busy agy-hook, emits empty json
  out=$(eval "$preinv_cmd")
  [ "$out" = "{}" ] || fail "PreInvocation hook did not emit {}, got '$out'"
  out=$(fm_busy_classify tmux fake:w agy "$id" "$state")
  [ "$out" = "busy agy-hook" ] || fail "state after PreInvocation must be busy agy-hook, got '$out'"

  # 4. Fire Stop hook again -> back to idle
  out=$(eval "$stop_cmd")
  out=$(fm_busy_classify tmux fake:w agy "$id" "$state")
  [ "$out" = "idle agy-hook" ] || fail "state after second Stop must be idle agy-hook, got '$out'"

  pass "agy crewmate: spawn installs hooks, Stop hook touches turn-ended and classifies idle, PreInvocation turns busy"
}

test_agy_crew_spawn_preserves_existing_project_hooks() {
  local rec id=crew-merge-1 out hooks ls_flags dirty_status
  rec=$(make_case merge-hooks "$id")
  read_case "$rec"

  # Seed pre-existing project hooks
  mkdir -p "$PROJ_DIR/.agents"
  cat > "$PROJ_DIR/.agents/hooks.json" <<'EOF'
{
  "project-linter": {
    "PreToolUse": [
      {
        "matcher": "run_command",
        "hooks": [{"type": "command", "command": "echo lint"}]
      }
    ]
  }
}
EOF
  git -C "$PROJ_DIR" add .agents/hooks.json
  git -C "$PROJ_DIR" commit -q -m "add project hooks"
  git -C "$PROJ_DIR" push --quiet origin main
  git -C "$WT_DIR" fetch --quiet origin
  git -C "$WT_DIR" reset --hard origin/main >/dev/null 2>&1

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "spawn into tree with existing hooks should succeed: $out"

  # Pre-existing project hooks are completely untouched
  hooks="$WT_DIR/.agents/hooks.json"
  jq -e '."project-linter".PreToolUse' "$hooks" >/dev/null \
    || fail "spawn clobbered pre-existing project-linter hook"
  if jq -e '."fm-crew-busy"' "$hooks" >/dev/null 2>&1; then
    fail "spawn must not inject fm-crew-busy into project's .agents/hooks.json"
  fi

  # Tracked .agents/hooks.json is NEVER set to skip-worktree (normal status H)
  ls_flags=$(git -C "$WT_DIR" ls-files -v .agents/hooks.json | awk '{print $1}')
  [ "$ls_flags" = "H" ] || fail "tracked .agents/hooks.json must keep normal status (H), got '$ls_flags'"
  dirty_status=$(git -C "$WT_DIR" status --porcelain .agents/hooks.json)
  [ -z "$dirty_status" ] || fail "tracked .agents/hooks.json must be clean in git status, got '$dirty_status'"

  # fm-crew-busy is isolated in its own plugin
  local plugin_hooks="$WT_DIR/.agents/plugins/fm-crew-busy/hooks.json"
  assert_present "$plugin_hooks" "isolated plugin hooks.json missing"
  jq -e '."fm-crew-busy".Stop' "$plugin_hooks" >/dev/null \
    || fail "isolated plugin lacks fm-crew-busy Stop hook"

  pass "agy crewmate: spawn keeps project hooks untouched and isolates fm-crew-busy in plugin"
}

test_agy_crew_wiring_cleanup_preserves_other_hooks() {
  local rec id=crew-clean-1 out state hooks ls_flags dirty_status
  rec=$(make_case clean-hooks "$id")
  read_case "$rec"

  mkdir -p "$PROJ_DIR/.agents"
  cat > "$PROJ_DIR/.agents/hooks.json" <<'EOF'
{
  "custom-hook": {
    "PostInvocation": [{"type": "command", "command": "echo done"}]
  }
}
EOF
  git -C "$PROJ_DIR" add .agents/hooks.json
  git -C "$PROJ_DIR" commit -q -m "add custom hooks"
  git -C "$PROJ_DIR" push --quiet origin main
  git -C "$WT_DIR" fetch --quiet origin
  git -C "$WT_DIR" reset --hard origin/main >/dev/null 2>&1

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "spawn should succeed: $out"
  state="$HOME_DIR/state"
  hooks="$WT_DIR/.agents/hooks.json"

  # Clear wiring via fm_control_clear_harness_wiring
  fm_control_clear_harness_wiring agy "$WT_DIR" "$state" "$id" || fail "fm_control_clear_harness_wiring failed"

  assert_present "$hooks" "hooks.json should still exist because custom-hook was present"
  jq -e '."custom-hook"' "$hooks" >/dev/null || fail "custom-hook was accidentally deleted"
  [ ! -d "$WT_DIR/.agents/plugins/fm-crew-busy" ] || fail "plugin directory was not cleaned up"

  ls_flags=$(git -C "$WT_DIR" ls-files -v .agents/hooks.json | awk '{print $1}')
  [ "$ls_flags" = "H" ] || fail "tracked .agents/hooks.json must have normal status (H) after cleanup, got '$ls_flags'"
  dirty_status=$(git -C "$WT_DIR" status --porcelain .agents/hooks.json)
  [ -z "$dirty_status" ] || fail "tracked .agents/hooks.json must be clean in git status after cleanup, got '$dirty_status'"

  pass "agy crewmate: wiring cleanup removes plugin while preserving existing project hooks"
}

test_agy_secondmate_spawn_and_trust() {
  local rec id=sm-agy-1 out home sm_home store
  rec=$(make_case sm-spawn "$id")
  read_case "$rec"
  home="$HOME_DIR"
  sm_home="$CASE_DIR/secondmate-home"
  mkdir -p "$sm_home/bin" "$sm_home/data" "$sm_home/state" "$sm_home/config" "$sm_home/projects"
  touch "$sm_home/AGENTS.md"
  printf '%s\n' "$id" > "$sm_home/.fm-secondmate-home"
  printf 'Secondmate charter\n' > "$home/data/$id.charter"
  git -C "$sm_home" init -q -b main

  store="$home/user-home/.gemini/antigravity-cli/settings.json"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"trustedWorkspaces":[]}' > "$store"

  out=$(fm_test_run_spawn "$home" "$sm_home" "$FAKEBIN_DIR" "$id" "$sm_home" --secondmate --harness agy 2>&1)
  assert_not_contains "$out" "verified crewmate/scout adapter only" \
    "secondmate spawn was refused by adapter gate"

  # Pre-registration of secondmate home trust in settings.json
  if [ -f "$store" ]; then
    assert_contains "$(cat "$store")" "$sm_home" \
      "secondmate home was not pre-registered in trustedWorkspaces"
  fi

  pass "agy secondmate: secondmate launch is accepted and pre-registers workspace trust"
}

test_agy_crew_worker_edits_to_tracked_hooks_preserved_and_refuses_teardown() {
  local rec id=crew-edit-1 out hooks dirty_status teardown_out tmp_edit
  rec=$(make_case edit-hooks "$id")
  read_case "$rec"

  mkdir -p "$PROJ_DIR/.agents"
  cat > "$PROJ_DIR/.agents/hooks.json" <<'EOF'
{
  "existing-hook": {
    "PreToolUse": [{"type": "command", "command": "echo exist"}]
  }
}
EOF
  git -C "$PROJ_DIR" add .agents/hooks.json
  git -C "$PROJ_DIR" commit -q -m "add existing hook"
  git -C "$PROJ_DIR" push --quiet origin main
  git -C "$WT_DIR" fetch --quiet origin
  git -C "$WT_DIR" reset --hard origin/main >/dev/null 2>&1

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "spawn should succeed: $out"
  hooks="$WT_DIR/.agents/hooks.json"

  # Worker modifies hooks.json (e.g. adding worker-hook)
  tmp_edit="$hooks.tmp.$$"
  jq '. + {"worker-hook":{"Stop":[{"type":"command","command":"echo worker"}]}}' "$hooks" > "$tmp_edit"
  mv -f "$tmp_edit" "$hooks"

  # git status must IMMEDIATELY report .agents/hooks.json without waiting for teardown!
  dirty_status=$(git -C "$WT_DIR" status --porcelain)
  assert_contains "$dirty_status" ".agents/hooks.json" "git status must immediately report .agents/hooks.json as dirty"

  # Teardown without --force MUST refuse loudly because of uncommitted changes
  teardown_out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  expect_code 1 $? "teardown must refuse when worker has uncommitted edits to hooks.json"
  assert_contains "$teardown_out" "REFUSED: worktree" "refusal message missing REFUSED: worktree"
  assert_contains "$teardown_out" "uncommitted changes present (includes tracked edits)" "refusal message missing tracked edits notice"

  # Worker's edits must be KEPT on disk
  assert_present "$hooks" "hooks.json was deleted on refused teardown"
  jq -e '."worker-hook"' "$hooks" >/dev/null || fail "worker's edits were dropped"
  jq -e '."existing-hook"' "$hooks" >/dev/null || fail "existing hooks were dropped"

  pass "agy crewmate: worker edits to tracked hooks.json are visible to git status and refuse teardown loudly"
}

test_teardown_preserves_unparseable_or_missing_jq_hooks() {
  local case_dir wt unparseable_hooks rc=0
  case_dir="$TMP_ROOT/unparseable-hooks"
  mkdir -p "$case_dir/wt/.agents"
  wt="$case_dir/wt"
  unparseable_hooks="$wt/.agents/hooks.json"
  printf 'NOT VALID JSON {{{{ \n' > "$unparseable_hooks"

  # Sourcing fm-control-lib.sh functions to test cleanup_worktree_agents_hooks directly
  (
    # shellcheck source=bin/fm-control-lib.sh
    . "$ROOT/bin/fm-control-lib.sh"
    cleanup_worktree_agents_hooks "$wt"
  ) 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "cleanup must refuse when hooks.json is unparseable"
  assert_present "$unparseable_hooks" "unparseable hooks.json was deleted by cleanup"
  assert_contains "$(cat "$unparseable_hooks")" "NOT VALID JSON" "unparseable hooks.json content was modified"

  pass "teardown: unparseable hooks.json is preserved and refuses cleanup"
}

test_teardown_preserves_worker_plugin_files_and_hooks() {
  local case_dir wt plugin_dir p_json p_hooks worker_file
  case_dir="$TMP_ROOT/plugin-worker-files"
  wt="$case_dir/wt"
  plugin_dir="$wt/.agents/plugins/fm-crew-busy"
  mkdir -p "$plugin_dir"

  p_json="$plugin_dir/plugin.json"
  p_hooks="$plugin_dir/hooks.json"
  worker_file="$plugin_dir/worker_file.sh"

  echo '{"name":"fm-crew-busy"}' > "$p_json"
  echo '{"fm-crew-busy":{"Stop":[]},"worker-custom":{"Stop":[]}}' > "$p_hooks"
  echo 'echo "worker code"' > "$worker_file"

  (
    # shellcheck source=bin/fm-control-lib.sh
    . "$ROOT/bin/fm-control-lib.sh"
    cleanup_worktree_agents_hooks "$wt"
  ) 2>/dev/null || fail "cleanup should succeed and preserve worker files"

  assert_present "$worker_file" "worker file in plugin directory was deleted"
  assert_present "$p_hooks" "plugin hooks.json containing other hooks was deleted"
  jq -e '."worker-custom"' "$p_hooks" >/dev/null || fail "worker custom hook was removed from plugin hooks.json"
  jq -e '."fm-crew-busy"' "$p_hooks" >/dev/null && fail "fm-crew-busy hook was not pruned from plugin hooks.json"
  [ ! -f "$p_json" ] || fail "firstmate-owned plugin.json should have been cleaned up"
  [ -d "$plugin_dir" ] || fail "plugin directory was deleted despite holding worker file"

  pass "teardown: worker files and custom hooks in plugin directory are preserved"
}

test_agy_crew_spawn_installs_hooks_and_turnend_notifies
test_agy_crew_spawn_preserves_existing_project_hooks
test_agy_crew_wiring_cleanup_preserves_other_hooks
test_agy_crew_worker_edits_to_tracked_hooks_preserved_and_refuses_teardown
test_teardown_preserves_unparseable_or_missing_jq_hooks
test_teardown_preserves_worker_plugin_files_and_hooks
test_agy_secondmate_spawn_and_trust

echo "all fm-agy-crew-turnend tests passed"
