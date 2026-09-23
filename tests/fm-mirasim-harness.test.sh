#!/usr/bin/env bash
# Portable behavior regression for the Mirasim Claude-wrapper adapter.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mirasim-harness)

run_hook() {  # <settings> <event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "missing $2 hook command"
  sh -c "$cmd"
}

test_mirasim_launch_reuses_claude_adapter() {
  local case_dir home proj wt fakebin id out launch meta settings state
  case_dir="$TMP_ROOT/launch path"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=mirasim-route
  fakebin=$(make_spawn_fakebin "$case_dir/fake" mirasim claude)
  fm_test_spawn_home "$home" mirasim
  fm_git_worktree "$proj" "$wt" mirasim-route
  fm_test_spawn_brief "$home" "$id"
  printf 'auto\n' > "$home/config/claude-permission-mode"

  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
      --harness mirasim --model 'claude-opus-5[1m]' --effort high \
      --mode no-mistakes --yolo off)
  expect_code 0 $? "Mirasim spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=mirasim" "spawn lost the route identity"

  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "'$fakebin/mirasim' claude --permission-mode auto" \
    "spawn did not invoke the resolved Mirasim wrapper with the configured Claude permission posture"
  assert_not_contains "$launch" "--dangerously-skip-permissions" \
    "Mirasim launch ignored the configured Claude permission posture"
  assert_contains "$launch" "--model 'claude-opus-5[1m]' --effort 'high'" \
    "spawn did not preserve the bracketed model id and effort as quoted arguments"
  assert_contains "$launch" "--append-system-prompt" \
    "Mirasim task launch lost Claude's task-control channel"

  meta="$home/state/$id.meta"
  grep -Fqx 'harness=mirasim' "$meta" || fail "metadata lost the Mirasim route identity"
  grep -Fqx 'model=claude-opus-5[1m]' "$meta" || fail "metadata lost the requested model id"
  grep -Fqx 'effort=high' "$meta" || fail "metadata lost the requested effort"

  state="$home/state"
  settings="$wt/.claude/settings.local.json"
  assert_present "$settings" "Mirasim spawn did not install Claude lifecycle hooks"
  case " $(fm_busy_sources_for_harness mirasim) " in
    *' claude-hook '*) ;;
    *) fail "Mirasim does not trust the Claude hook source" ;;
  esac
  run_hook "$settings" Stop || fail "Mirasim Stop hook failed"
  [ "$(fm_busy_classify tmux fake:w mirasim "$id" "$state")" = "idle claude-hook" ] \
    || fail "Mirasim Stop did not settle through Claude's busy owner"
  run_hook "$settings" UserPromptSubmit || fail "Mirasim UserPromptSubmit hook failed"
  [ "$(fm_busy_classify tmux fake:w mirasim "$id" "$state")" = "busy claude-hook" ] \
    || fail "Mirasim submit did not reopen through Claude's busy owner"
  pass "Mirasim records its route and reuses Claude launch, trust, control-channel, and busy-hook mechanics"
}

test_mirasim_control_and_scope() {
  local case_dir home proj wt fakebin id out
  [ "$(fm_control_harness_family mirasim)" = mirasim ] \
    || fail "Mirasim control identity did not stay distinct"
  [ "$(fm_control_interrupt_key mirasim)" = Escape ] \
    || fail "Mirasim did not reuse Claude's interrupt key"
  [ "$(fm_control_exit_command mirasim)" = /exit ] \
    || fail "Mirasim did not reuse Claude's exit command"
  fm_control_harness_supports_kind mirasim scout \
    || fail "Mirasim should support scout work"
  if fm_control_harness_supports_kind mirasim secondmate; then
    fail "Mirasim must not claim unverified secondmate support"
  fi

  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=mirasim-secondmate
  fakebin=$(make_spawn_fakebin "$case_dir/fake" mirasim claude)
  fm_test_spawn_home "$home" mirasim
  fm_git_worktree "$proj" "$wt" mirasim-secondmate
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" mirasim --secondmate) && {
    fail "Mirasim secondmate must be refused: $out"
  }
  assert_contains "$out" 'crewmate/scout adapter only' \
    "secondmate refusal did not name the supported boundary"
  pass "Mirasim reuses verified Claude control mechanics and refuses primary-dependent secondmate work"
}

test_mirasim_launch_reuses_claude_adapter
test_mirasim_control_and_scope

echo "all fm-mirasim-harness tests passed"
