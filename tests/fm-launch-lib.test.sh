#!/usr/bin/env bash
# tests/fm-launch-lib.test.sh - bin/fm-launch-lib.sh, the single owner of every
# firstmate launch command.
#
# Why this file is load-bearing: a hand-copied launch command has already
# drifted once, dropping claude's CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
# prefix - the ghost-text suppression that keeps firstmate from reading
# predicted-prompt text as real typed input when it captures a pane. So this
# suite pins two things:
#
#   1. Every crewmate/scout/secondmate template composes exactly what it did
#      before the extraction out of bin/fm-spawn.sh (behavior-preserving pin).
#   2. bin/fm-spawn.sh defines none of the three functions itself, so there is
#      exactly one copy to keep verified.
#
# The `primary` kind (a firstmate PRIMARY session: no task, no worktree, no
# brief, no status file) is pinned here too, so the fleet launcher inherits the
# same verified commands instead of hand-writing them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCH_LIB="$ROOT/bin/fm-launch-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

# shellcheck source=/dev/null
. "$LAUNCH_LIB"

HARNESSES=(claude codex opencode pi pi-signed grok kimi)

# assert_template <kind> <harness> <expected>
assert_template() {
  local kind=$1 harness=$2 expected=$3 got
  got=$(launch_template "$harness" "$kind") \
    || fail "launch_template $harness $kind returned non-zero for a verified adapter"
  [ "$got" = "$expected" ] \
    || fail "launch_template $harness $kind drifted:
  expected: $expected
  got:      $got"
}

# --- crewmate/scout templates: byte-identical to the pre-extraction commands --

test_ship_and_scout_templates_are_pinned() {
  local kind
  # shellcheck disable=SC2016  # single quotes are deliberate: these expand in the crewmate pane
  for kind in ship scout; do
    assert_template "$kind" claude 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
    assert_template "$kind" codex 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
    assert_template "$kind" opencode 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
    assert_template "$kind" pi 'FM_PI_HARNESS=pi pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
    assert_template "$kind" pi-signed 'FM_PI_HARNESS=pi-signed pi-signed __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
    assert_template "$kind" grok 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
    assert_template "$kind" kimi '__KIMIBIN__ __MODELFLAG__--auto'
  done
  pass "launch_template: ship and scout templates are unchanged for all seven verified adapters"
}

test_ship_is_the_default_kind() {
  local h
  for h in "${HARNESSES[@]}"; do
    [ "$(launch_template "$h")" = "$(launch_template "$h" ship)" ] \
      || fail "launch_template $h with no kind must equal the ship template"
  done
  pass "launch_template: an omitted kind still means ship"
}

test_secondmate_templates_are_pinned() {
  # Only codex and the pi family differ from the ship shape: codex drops the
  # per-task notify hook and pi/pi-signed point at the secondmate home's own
  # primary extensions.
  # shellcheck disable=SC2016  # single quotes are deliberate: these expand in the agent pane
  assert_template secondmate codex 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  # shellcheck disable=SC2016
  assert_template secondmate pi 'FM_PI_HARNESS=pi pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  # shellcheck disable=SC2016
  assert_template secondmate pi-signed 'FM_PI_HARNESS=pi-signed pi-signed __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  local h
  for h in claude opencode grok kimi; do
    [ "$(launch_template "$h" secondmate)" = "$(launch_template "$h" ship)" ] \
      || fail "launch_template $h secondmate must match its ship template"
  done
  pass "launch_template: secondmate templates are unchanged (codex and the pi family differ, the rest match ship)"
}

# --- the primary kind -------------------------------------------------------

test_primary_templates_are_pinned() {
  assert_template primary claude 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__'
  assert_template primary codex 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox'
  assert_template primary opencode 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--auto'
  assert_template primary pi 'FM_PI_HARNESS=pi pi __MODELFLAG____EFFORTFLAG__'
  assert_template primary pi-signed 'FM_PI_HARNESS=pi-signed pi-signed __MODELFLAG____EFFORTFLAG__'
  assert_template primary grok 'grok --always-approve __MODELFLAG____EFFORTFLAG__'
  assert_template primary kimi '__KIMIBIN__ __MODELFLAG__--auto'
  pass "launch_template: every verified adapter has a primary template"
}

test_primary_carries_no_task_scoped_placeholder() {
  local h tpl
  for h in "${HARNESSES[@]}"; do
    tpl=$(launch_template "$h" primary)
    case "$tpl" in
      *__BRIEF__*|*__OPINPUT__*|*__TURNEND__*|*__PIEXT__*|*__PITURNEND__*|*__PIWATCH__*)
        fail "primary template for $h carries a task-scoped placeholder, but a primary has no task or brief: $tpl"
        ;;
    esac
  done
  pass "launch_template: no primary template references a brief, turn-end token, or task extension"
}

test_primary_keeps_the_autonomy_and_ghost_text_knowledge() {
  # The exact knowledge a hand-written launcher command has already lost once.
  assert_contains "$(launch_template claude primary)" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false' \
    "the claude primary template must keep the ghost-text suppression prefix"
  assert_contains "$(launch_template claude primary)" '--dangerously-skip-permissions' \
    "the claude primary template must keep its autonomy flag"
  assert_contains "$(launch_template codex primary)" '--dangerously-bypass-approvals-and-sandbox' \
    "the codex primary template must keep its autonomy flag"
  assert_contains "$(launch_template grok primary)" '--always-approve' \
    "the grok primary template must keep its autonomy flag"
  assert_contains "$(launch_template opencode primary)" '"permission":{"*":"allow"}' \
    "the opencode primary template must keep its permission config"
  assert_contains "$(launch_template opencode primary)" '--auto' \
    "the opencode primary template must keep the verified briefless --auto form"
  pass "launch_template: primary templates keep each adapter's verified autonomy and ghost-text knowledge"
}

test_primary_and_ship_share_a_model_and_effort_surface() {
  local h
  for h in "${HARNESSES[@]}"; do
    assert_contains "$(launch_template "$h" primary)" '__MODELFLAG__' \
      "the $h primary template must accept the shared model flag"
    case "$(launch_template "$h" ship)" in
      *__EFFORTFLAG__*)
        assert_contains "$(launch_template "$h" primary)" '__EFFORTFLAG__' \
          "the $h primary template must accept the effort flag its ship template accepts"
        ;;
    esac
  done
  pass "launch_template: primary templates expose the same model/effort placeholders as their ship templates"
}

# --- the unverified-adapter guard -------------------------------------------

test_unknown_harness_returns_non_zero_for_every_kind() {
  local kind
  for kind in ship scout secondmate primary; do
    launch_template not-a-harness "$kind" >/dev/null 2>&1 \
      && fail "launch_template must refuse an unverified adapter for kind=$kind"
  done
  pass "launch_template: an unverified adapter returns non-zero for every kind, including primary"
}

test_unknown_kind_falls_back_to_the_crewmate_shape() {
  # fm-spawn passes only ship|scout|secondmate; anything else must not silently
  # produce a briefless primary command.
  [ "$(launch_template claude bogus-kind)" = "$(launch_template claude ship)" ] \
    || fail "an unrecognized kind must keep the crewmate shape, never fall through to primary"
  pass "launch_template: an unrecognized kind keeps the crewmate shape"
}

# --- flag resolution --------------------------------------------------------

test_model_flag_covers_every_verified_adapter() {
  local h
  for h in "${HARNESSES[@]}"; do
    [ "$(model_flag_for_harness "$h" opus)" = "--model 'opus' " ] \
      || fail "model_flag_for_harness $h opus drifted: $(model_flag_for_harness "$h" opus)"
  done
  [ -z "$(model_flag_for_harness not-a-harness opus)" ] \
    || fail "model_flag_for_harness must emit nothing for an unverified adapter"
  pass "model_flag_for_harness: every verified adapter takes --model, quoted"
}

test_model_flag_is_empty_when_unset_or_default() {
  local h v
  for h in "${HARNESSES[@]}"; do
    for v in '' default; do
      [ -z "$(model_flag_for_harness "$h" "$v")" ] \
        || fail "model_flag_for_harness $h '$v' must emit nothing"
    done
  done
  pass "model_flag_for_harness: an unset or 'default' model emits no flag"
}

test_effort_flag_per_harness_vocabulary() {
  # Each adapter's verified effort flag and the exact vocabulary it accepts;
  # values outside that vocabulary are omitted rather than passed through.
  [ "$(effort_flag_for_harness claude xhigh)" = "--effort 'xhigh' " ] || fail "claude effort flag drifted"
  [ "$(effort_flag_for_harness claude max)" = "--effort 'max' " ] || fail "claude must accept max"
  [ "$(effort_flag_for_harness codex xhigh)" = "-c 'model_reasoning_effort=\"xhigh\"' " ] || fail "codex effort flag drifted"
  [ -z "$(effort_flag_for_harness codex max)" ] || fail "codex must omit max, not pass an unsupported value"
  [ "$(effort_flag_for_harness grok high)" = "--reasoning-effort 'high' " ] || fail "grok effort flag drifted"
  [ -z "$(effort_flag_for_harness grok xhigh)" ] || fail "grok must omit xhigh"
  [ -z "$(effort_flag_for_harness grok max)" ] || fail "grok must omit max"
  [ "$(effort_flag_for_harness pi max)" = "--thinking 'max' " ] || fail "pi effort flag drifted"
  [ "$(effort_flag_for_harness pi-signed max)" = "--thinking 'max' " ] || fail "pi-signed must share pi's effort flag and vocabulary"
  [ -z "$(effort_flag_for_harness opencode high)" ] || fail "opencode has no verified effort flag"
  [ -z "$(effort_flag_for_harness kimi high)" ] || fail "kimi has no verified effort flag"
  pass "effort_flag_for_harness: each adapter's verified flag and vocabulary are unchanged"
}

test_effort_flag_is_empty_when_unset_or_default() {
  local h v
  for h in "${HARNESSES[@]}"; do
    for v in '' default; do
      [ -z "$(effort_flag_for_harness "$h" "$v")" ] \
        || fail "effort_flag_for_harness $h '$v' must emit nothing"
    done
  done
  pass "effort_flag_for_harness: an unset or 'default' effort emits no flag"
}

test_flags_are_shell_quoted() {
  # The composed command is evaluated by a shell in the target pane, so a value
  # carrying a quote must not be able to break out of it.
  [ "$(model_flag_for_harness claude "o'pus")" = "--model 'o'\\''pus' " ] \
    || fail "model_flag_for_harness must shell-quote a value containing a single quote"
  pass "model_flag_for_harness: values are shell-quoted against injection"
}

# --- one owner --------------------------------------------------------------

test_fm_spawn_defines_none_of_the_three_functions() {
  local fn
  for fn in launch_template model_flag_for_harness effort_flag_for_harness shell_quote; do
    grep -qE "^$fn\(\) \{" "$SPAWN" \
      && fail "bin/fm-spawn.sh defines $fn again; bin/fm-launch-lib.sh is the single owner"
  done
  # shellcheck disable=SC2016  # matching fm-spawn.sh's literal source line, not expanding it
  grep -Fq '. "$SCRIPT_DIR/fm-launch-lib.sh"' "$SPAWN" \
    || fail "bin/fm-spawn.sh must source bin/fm-launch-lib.sh"
  pass "one owner: bin/fm-spawn.sh sources the library and redefines nothing"
}

test_no_other_tracked_script_hand_writes_a_launch_command() {
  # One marker per verified adapter's autonomy, permission, or ghost-text
  # knowledge, so a hand-copied codex, opencode, grok, or kimi command is caught
  # too and not just claude's. Each pattern must still match the library itself;
  # a pattern that matches nothing would pass this guard while checking nothing.
  local markers=(
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION'
    '--dangerously-skip-permissions'
    '--dangerously-bypass-approvals-and-sandbox'
    'OPENCODE_CONFIG_CONTENT='
    '--always-approve'
    '--auto([^-a-z]|$)'
  )
  local marker owners status matches
  for marker in "${markers[@]}"; do
    owners=$(git -C "$ROOT" grep -lE -e "$marker" -- bin)
    status=$?
    [ "$status" -le 1 ] \
      || fail "the one-owner guard could not run git grep for '$marker' (git grep exited $status)"
    case $'\n'"$owners"$'\n' in
      *$'\n'bin/fm-launch-lib.sh$'\n'*) ;;
      *) fail "the one-owner guard's '$marker' pattern no longer matches bin/fm-launch-lib.sh, so it checks nothing" ;;
    esac
    matches=$(printf '%s\n' "$owners" | grep -v '^bin/fm-launch-lib.sh$' | grep -v '^$')
    [ -z "$matches" ] \
      || fail "a launch command is hand-written outside bin/fm-launch-lib.sh ('$marker'): $matches"
  done
  pass "one owner: no other script under bin/ hand-writes any verified harness launch command"
}

test_ship_and_scout_templates_are_pinned
test_ship_is_the_default_kind
test_secondmate_templates_are_pinned
test_primary_templates_are_pinned
test_primary_carries_no_task_scoped_placeholder
test_primary_keeps_the_autonomy_and_ghost_text_knowledge
test_primary_and_ship_share_a_model_and_effort_surface
test_unknown_harness_returns_non_zero_for_every_kind
test_unknown_kind_falls_back_to_the_crewmate_shape
test_model_flag_covers_every_verified_adapter
test_model_flag_is_empty_when_unset_or_default
test_effort_flag_per_harness_vocabulary
test_effort_flag_is_empty_when_unset_or_default
test_flags_are_shell_quoted
test_fm_spawn_defines_none_of_the_three_functions
test_no_other_tracked_script_hand_writes_a_launch_command
