#!/usr/bin/env bash
# tests/fm-context-ceiling.test.sh - a launched worker, scout, or secondmate is
# summarized by its tool at the home's or the task's context ceiling.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane received with the tool binary replaced by a probe that prints
# its own arguments, so what is asserted is what a real agent was started with.
# The live check that each covered tool honors those arguments is
# tests/fm-context-ceiling-live.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-context-ceiling-lib.sh
. "$ROOT/bin/fm-context-ceiling-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-ceiling)

make_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_DIR=$case_dir
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  LAUNCH_LOG="$case_dir/launch.log"
  PANE_LOG="$case_dir/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

run_spawn() {
  : >"$LAUNCH_LOG"
  : >"$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@" 2>&1
}

# Replace <tool> with a probe printing one argument per line, then run the
# emitted launch in a synthetic pane shell and print what the probe received.
launched_args() {  # <tool>
  cat >"$FAKEBIN_DIR/$1" <<'SH'
#!/bin/sh
for a do printf '%s\n' "$a"; done
SH
  chmod +x "$FAKEBIN_DIR/$1"
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(grep '^export ' "$PANE_LOG")
$(cat "$LAUNCH_LOG")"
}

# The --settings value a claude launch received, as one JSON line.
claude_settings_json() {
  printf '%s\n' "$1" | awk 'prev == "--settings" { print; exit } { prev = $0 }'
}

meta_value() { sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta" | tail -1; }

make_secondmate_home() {  # <id>
  SM_HOME="$CASE_DIR/secondmate-home"
  mkdir -p "$SM_HOME/bin" "$SM_HOME/data"
  printf '# Firstmate\n' >"$SM_HOME/AGENTS.md"
  printf '%s\n' "$1" >"$SM_HOME/.fm-secondmate-home"
  printf 'charter for %s\n' "$1" >"$SM_HOME/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' >"$SM_HOME/.gitignore"
  git -C "$SM_HOME" init -q -b main
}

test_lib_grammar() {
  local v
  for v in off 20000 250000 10000000; do
    fm_context_ceiling_valid "$v" || fail "valid ceiling refused: $v"
  done
  for v in '' 0 19999 10000001 025000 250k -1 ' 250000' 99999999999; do
    if fm_context_ceiling_valid "$v"; then fail "unusable ceiling accepted: '$v'"; fi
  done
  pass "the ceiling grammar accepts off and 20000..10000000 tokens only"
}

test_lib_precedence() {
  local cfg="$TMP_ROOT/prec-config"
  mkdir -p "$cfg"
  fm_context_ceiling_resolve "$cfg" ship 0 '' ''
  assert_equals '' "$FM_CONTEXT_CEILING_VALUE" "absent setting must resolve to no ceiling"
  : >"$cfg/context-ceiling"
  fm_context_ceiling_resolve "$cfg" ship 0 '' ''
  assert_equals 250000 "$FM_CONTEXT_CEILING_VALUE" "an empty setting must default workers to 250000"
  fm_context_ceiling_resolve "$cfg" secondmate 0 '' ''
  assert_equals 250000 "$FM_CONTEXT_CEILING_VALUE" "an empty setting must default secondmates to 250000"
  printf '# tuned\nworker=180000\n\nsecondmate=off\n' >"$cfg/context-ceiling"
  fm_context_ceiling_resolve "$cfg" scout 0 '' ''
  assert_equals 180000 "$FM_CONTEXT_CEILING_VALUE" "worker= must apply to scouts"
  fm_context_ceiling_resolve "$cfg" secondmate 0 '' ''
  assert_equals off "$FM_CONTEXT_CEILING_VALUE" "secondmate=off must be honored"
  fm_context_ceiling_resolve "$cfg" ship 0 '' 300000
  assert_equals 300000 "$FM_CONTEXT_CEILING_VALUE" "a recorded value must beat the home setting on relaunch"
  fm_context_ceiling_resolve "$cfg" ship 1 off 300000
  assert_equals off "$FM_CONTEXT_CEILING_VALUE" "the per-spawn value must beat the record and the setting"
  printf 'worker=250000\nworker=200000\n' >"$cfg/context-ceiling"
  if fm_context_ceiling_resolve "$cfg" ship 0 '' ''; then fail "a repeated key must make the setting unreadable"; fi
  assert_contains "$FM_CONTEXT_CEILING_ERROR" 'set twice' "the repeated-key error must name the problem"
  printf 'workers=250000\n' >"$cfg/context-ceiling"
  if fm_context_ceiling_resolve "$cfg" ship 0 '' ''; then fail "an unknown line must make the setting unreadable"; fi
  printf 'worker=25000O\n' >"$cfg/context-ceiling"
  if fm_context_ceiling_resolve "$cfg" ship 0 '' ''; then fail "a typo'd value must make the setting unreadable"; fi
  pass "precedence is spawn value, then task record, then home setting; an unreadable setting is an error"
}

test_absent_setting_keeps_launch_unchanged() {
  local out args
  make_case absent-claude claude cc-absent-a1
  out=$(run_spawn cc-absent-a1 "$PROJ_DIR" --mode local-only --yolo off) || fail "spawn failed: $out"
  args=$(launched_args claude)
  assert_not_contains "$(claude_settings_json "$args")" autoCompactWindow "no setting must add no claude ceiling"
  assert_equals '' "$(meta_value cc-absent-a1 context_ceiling)" "no setting must write no context_ceiling record"
  make_case absent-codex codex cc-absent-b1
  out=$(run_spawn cc-absent-b1 "$PROJ_DIR" --mode local-only --yolo off) || fail "spawn failed: $out"
  args=$(launched_args codex)
  assert_not_contains "$args" model_auto_compact_token_limit "no setting must add no codex ceiling"
  pass "without config/context-ceiling every launch and task record is unchanged"
}

test_claude_worker_gets_default_ceiling() {
  local out args json
  make_case claude-default claude cc-claude-a1
  : >"$HOME_DIR/config/context-ceiling"
  out=$(run_spawn cc-claude-a1 "$PROJ_DIR" --mode local-only --yolo off) || fail "spawn failed: $out"
  args=$(launched_args claude)
  json=$(claude_settings_json "$args")
  assert_equals 250000 "$(printf '%s' "$json" | jq -r .autoCompactWindow)" "claude worker --settings must carry autoCompactWindow=250000: $json"
  assert_equals off "$(printf '%s' "$json" | jq -r .feedbackDrafts)" "the ceiling must not displace the existing session keys"
  assert_equals 250000 "$(meta_value cc-claude-a1 context_ceiling)" "the task record must carry the ceiling"
  assert_equals yes "$(meta_value cc-claude-a1 context_ceiling_applied)" "the task record must say the ceiling applied"
  pass "a claude worker launched under an empty setting is summarized at 250000 tokens"
}

test_codex_scout_gets_kind_value() {
  local out args
  make_case codex-scout codex cc-codex-a1
  printf 'worker=180000\n' >"$HOME_DIR/config/context-ceiling"
  out=$(run_spawn cc-codex-a1 "$PROJ_DIR" --scout) || fail "spawn failed: $out"
  args=$(launched_args codex)
  assert_contains "$args" "model_auto_compact_token_limit=180000" "codex scout must receive the worker= ceiling as a -c override"
  printf '%s\n' "$args" | awk 'prev == "-c" && $0 == "model_auto_compact_token_limit=180000" { found = 1 } { prev = $0 } END { exit !found }' \
    || fail "the codex ceiling must be its own -c argument: $args"
  pass "a codex scout receives the worker= ceiling as its own -c override"
}

test_spawn_value_overrides_and_off() {
  local out args
  make_case override claude cc-override-a1
  printf 'worker=250000\n' >"$HOME_DIR/config/context-ceiling"
  out=$(run_spawn cc-override-a1 "$PROJ_DIR" --mode local-only --yolo off --context-ceiling 400000) || fail "spawn failed: $out"
  args=$(launched_args claude)
  assert_equals 400000 "$(claude_settings_json "$args" | jq -r .autoCompactWindow)" "--context-ceiling must override the home setting"
  make_case off claude cc-off-a1
  printf 'worker=250000\n' >"$HOME_DIR/config/context-ceiling"
  out=$(run_spawn cc-off-a1 "$PROJ_DIR" --mode local-only --yolo off --context-ceiling off) || fail "spawn failed: $out"
  args=$(launched_args claude)
  assert_not_contains "$(claude_settings_json "$args")" autoCompactWindow "--context-ceiling off must leave the tool default"
  assert_equals off "$(meta_value cc-off-a1 context_ceiling)" "off must be recorded so a relaunch keeps it"
  pass "a task-type value overrides the home setting, and off leaves the tool's own (very large) window"
}

test_claude_secondmate_settings_file() {
  local out settings
  make_case secondmate claude cc-sm-a1
  printf 'secondmate=300000\n' >"$HOME_DIR/config/context-ceiling"
  make_secondmate_home cc-sm-a1
  out=$(run_spawn cc-sm-a1 "$SM_HOME" --secondmate) || fail "secondmate spawn failed: $out"
  settings="$HOME_DIR/state/cc-sm-a1.claude-settings.json"
  [ -f "$settings" ] || fail "the secondmate settings file is missing: $out"
  assert_equals 300000 "$(jq -r .autoCompactWindow "$settings")" "secondmate settings must carry the secondmate= ceiling"
  assert_equals off "$(jq -r .feedbackDrafts "$settings")" "secondmate settings must keep feedbackDrafts"
  [ "$(jq -r '.hooks | has("UserPromptSubmit")' "$settings")" = true ] || fail "secondmate settings must keep the busy hooks"
  out=$(run_spawn cc-sm-b1 "$SM_HOME" --secondmate --context-ceiling 200000)
  expect_code 1 "$?" "--context-ceiling on a secondmate must refuse"
  assert_contains "$out" 'secondmate= line' "the refusal must point at the setting"
  pass "a claude secondmate gets the secondmate= ceiling in its settings file; the per-task flag is refused"
}

test_uncovered_tool_is_recorded_not_applied() {
  local out
  make_case uncovered pi cc-pi-a1
  : >"$HOME_DIR/config/context-ceiling"
  printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN_DIR/pi"
  chmod +x "$FAKEBIN_DIR/pi"
  out=$(run_spawn cc-pi-a1 "$PROJ_DIR" --mode local-only --yolo off)
  [ -f "$HOME_DIR/state/cc-pi-a1.meta" ] || fail "pi spawn did not create a task record: $out"
  assert_contains "$out" 'context ceiling 250000 is recorded but not applied' "an uncovered tool must print one notice"
  assert_equals no "$(meta_value cc-pi-a1 context_ceiling_applied)" "an uncovered tool must record applied=no"
  pass "a tool without a verified ceiling records the value, says so once, and keeps its default"
}

test_unreadable_setting_refuses_before_launch() {
  local out
  make_case unreadable claude cc-bad-a1
  printf 'worker=2500000000\n' >"$HOME_DIR/config/context-ceiling"
  out=$(run_spawn cc-bad-a1 "$PROJ_DIR" --mode local-only --yolo off)
  expect_code 1 "$?" "an unreadable setting must refuse the spawn"
  assert_contains "$out" 'config/context-ceiling' "the refusal must name the setting"
  [ ! -s "$LAUNCH_LOG" ] || fail "an unreadable setting must launch nothing"
  [ ! -e "$HOME_DIR/state/cc-bad-a1.meta" ] || fail "an unreadable setting must create no task record"
  out=$(run_spawn cc-bad-a1 "$PROJ_DIR" --mode local-only --yolo off --context-ceiling 12)
  expect_code 1 "$?" "an unusable --context-ceiling must refuse"
  pass "an unreadable setting or unusable value refuses before anything launches"
}

# bin/fm-control.sh relaunch rebuilds the launch through bin/fm-spawn.sh
# --relaunch; the replacement must keep the ceiling the task recorded, even
# after the home setting changed, so one task does not switch size mid-flight.
test_relaunch_replays_recorded_ceiling() {
  local dir home proj wt id=cc-relaunch-a1 out launch args
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  printf 'worker=250000\n' >"$home/config/context-ceiling"
  fm_test_make_relaunch_stub "$dir"
  fm_git_worktree "$proj" "$wt" wt-cc-relaunch
  fm_test_spawn_brief "$home" "$id"
  : >"$dir/fake/literal"
  : >"$dir/fake/keys"
  printf 'codex' >"$dir/fake/command"
  printf '%s\n' "fm-$id" >"$dir/fake/windows"
  printf '%s' "$wt" >"$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=local-only"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
    echo "context_ceiling=180000"
    echo "context_ceiling_applied=yes"
  } >"$home/state/$id.meta"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$ROOT/bin/fm-control.sh" "$id" relaunch --note 'replacement continues the same task' 2>&1) \
    || fail "relaunch failed: $out"
  launch=$(cat "$dir/fake/launch" 2>/dev/null)
  [ -n "$launch" ] || fail "relaunch sent no replacement launch command: $out"
  cat >"$dir/fakebin/codex" <<'SH'
#!/bin/sh
for a do printf '%s\n' "$a"; done
SH
  chmod +x "$dir/fakebin/codex"
  args=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(grep '^export ' "$dir/fake/keys")
$launch") || fail "the replacement launch failed to run"
  assert_contains "$args" model_auto_compact_token_limit=180000 "the replacement must keep the recorded ceiling, not the changed home setting"
  assert_equals 180000 "$(sed -n 's/^context_ceiling=//p' "$home/state/$id.meta")" "the record must keep exactly one context_ceiling line"
  [ "$(grep -c '^context_ceiling=' "$home/state/$id.meta")" = 1 ] || fail "relaunch duplicated the context_ceiling record"
  pass "a relaunch replays the task's recorded ceiling rather than the home's current setting"
}

test_lib_grammar
test_lib_precedence
test_absent_setting_keeps_launch_unchanged
test_claude_worker_gets_default_ceiling
test_codex_scout_gets_kind_value
test_spawn_value_overrides_and_off
test_claude_secondmate_settings_file
test_uncovered_tool_is_recorded_not_applied
test_unreadable_setting_refuses_before_launch
test_relaunch_replays_recorded_ceiling
