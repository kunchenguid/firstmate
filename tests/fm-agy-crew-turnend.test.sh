#!/usr/bin/env bash
# Integration tests for Antigravity CLI (agy) crewmate turn-end lifecycle,
# busy-state notifications, watcher continuity, and secondmate enablement.
#
# Covers:
#   1. Crewmate spawn installs semantic busy wiring in $WT/.agents/hooks.json
#      and excludes it from git tracking.
#   2. Stop hook execution touches state/<id>.turn-ended, records idle via
#      fm-busy-event.sh, and outputs {"decision":"allow"}.
#   3. PreInvocation hook records busy and outputs {}.
#   4. Worktree with pre-existing hooks.json merges fm-crew-busy without clobbering.
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
  local rec id=crew-turn-1 out state hooks stop_cmd preinv_cmd
  rec=$(make_case spawn-hooks "$id")
  read_case "$rec"

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "agy crewmate spawn should succeed: $out"

  state="$HOME_DIR/state"
  assert_present "$state/$id.busy-gen" "agy spawn did not mint busy-gen"
  hooks="$WT_DIR/.agents/hooks.json"
  assert_present "$hooks" "agy spawn did not create .agents/hooks.json"

  # Excluded from git
  excl=$(cd "$WT_DIR" && git rev-parse --git-path info/exclude)
  [ -f "$excl" ] || fail "git exclude file '$excl' does not exist"
  grep -qxF '.agents/hooks.json' "$excl" || fail ".agents/hooks.json was not added to git exclude: $(cat "$excl")"

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

test_agy_crew_spawn_merges_with_existing_hooks() {
  local rec id=crew-merge-1 out state hooks
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

  hooks="$WT_DIR/.agents/hooks.json"
  jq -e '."project-linter".PreToolUse' "$hooks" >/dev/null \
    || fail "spawn clobbered pre-existing project-linter hook"
  jq -e '."fm-crew-busy".Stop' "$hooks" >/dev/null \
    || fail "spawn did not add fm-crew-busy Stop hook"

  pass "agy crewmate: spawn merges fm-crew-busy without clobbering pre-existing hooks"
}

test_agy_crew_wiring_cleanup_preserves_other_hooks() {
  local rec id=crew-clean-1 out state hooks
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
  if jq -e '."fm-crew-busy"' "$hooks" >/dev/null 2>&1; then
    fail "fm-crew-busy was not pruned from hooks.json"
  fi

  pass "agy crewmate: wiring cleanup prunes fm-crew-busy while preserving existing project hooks"
}

test_agy_secondmate_spawn_and_trust() {
  local rec id=sm-agy-1 out home sm_home store fakebin
  rec=$(make_case sm-spawn "$id")
  read_case "$rec"
  home="$HOME_DIR"
  sm_home="$CASE_DIR/secondmate-home"
  mkdir -p "$sm_home/bin" "$sm_home/data" "$sm_home/state" "$sm_home/config" "$sm_home/projects"
  touch "$sm_home/AGENTS.md"
  printf '%s\n' "$id" > "$sm_home/.fm-secondmate-home"
  printf 'Secondmate charter\n' > "$home/data/$id.charter"

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

test_agy_crew_spawn_installs_hooks_and_turnend_notifies
test_agy_crew_spawn_merges_with_existing_hooks
test_agy_crew_wiring_cleanup_preserves_other_hooks
test_agy_secondmate_spawn_and_trust

echo "all fm-agy-crew-turnend tests passed"
