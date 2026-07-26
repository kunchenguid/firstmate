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
# The harnesses README.md:61 lists as verified for a PRIMARY session. kimi is
# deliberately absent, so launch_template refuses it for kind=primary.
PRIMARY_HARNESSES=(claude codex opencode pi pi-signed grok)

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

# Each primary shape gets its own test naming the evidence that fixes its flags,
# so an edit that drops a load-bearing flag fails here rather than reaching a
# reviewer. A primary template is NOT the crewmate command minus its brief; it is
# whatever this repo empirically verified for a briefless PRIMARY launch.

test_primary_claude_template_is_pinned() {
  # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false is the ghost-text suppression a
  # hand-copied command already dropped once. README.md:90 documents the primary
  # launch as bare `claude`; the only in-repo launch carrying
  # --dangerously-skip-permissions is the headless print-mode session at
  # tests/fm-claude-stop-autoarm-live-e2e.test.sh:115, so this pin records the
  # flag's presence rather than claiming an interactive primary verified it.
  assert_template primary claude 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__'
  pass "launch_template: the claude primary template is pinned"
}

test_primary_codex_template_is_pinned() {
  # tests/fm-codex-continuity-live-e2e.test.sh:40 runs codex headlessly via
  # `codex exec`, which is not evidence of the interactive primary TUI shape;
  # --dangerously-bypass-approvals-and-sandbox carries over from the crewmate
  # command and this pin holds it steady until a primary TUI launch verifies it.
  assert_template primary codex 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox'
  pass "launch_template: the codex primary template is pinned"
}

test_primary_opencode_template_is_pinned() {
  # tests/fm-opencode-primary-live-e2e.test.sh:256 and :310 both launch a primary
  # opencode TUI as OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' with
  # `opencode --auto`. --prompt belongs to the crewmate, which has a brief to pass.
  assert_template primary opencode 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--auto'
  pass "launch_template: the opencode primary template is pinned"
}

test_primary_pi_template_is_pinned() {
  # README.md:102 documents the primary launch as bare `pi`, and README.md:106
  # records that the once-per-clone project trust prompt is what auto-loads the
  # tracked .pi/extensions/*.ts. tests/fm-pi-primary-live-e2e.test.sh:266 adds
  # --approve --no-session --no-context-files --no-extensions plus explicit -e
  # paths, but that is the test's own isolation scaffolding against a throwaway
  # clone, not the verified primary form, so it must not leak into this template.
  # The FM_PI_HARNESS identity marker rides every Pi-family launch, primary
  # included: README.md:104 documents the signed primary launch as
  # `FM_PI_HARNESS=pi-signed pi-signed`, and pi-signed is a distinct executable
  # identity sharing pi's verified flag surface, never an alias.
  assert_template primary pi 'FM_PI_HARNESS=pi pi __MODELFLAG____EFFORTFLAG__'
  assert_template primary pi-signed 'FM_PI_HARNESS=pi-signed pi-signed __MODELFLAG____EFFORTFLAG__'
  pass "launch_template: the pi and pi-signed primary templates are pinned"
}

test_primary_grok_template_is_pinned() {
  # tests/fm-grok-continuity-live-e2e.test.sh:76 launches a primary grok as
  # `grok --trust --always-approve --reasoning-effort low`, where
  # --reasoning-effort is what __EFFORTFLAG__ resolves to; README.md:96 documents
  # `grok --trust` too. --trust is load-bearing, not setup trivia:
  # .agents/skills/harness-adapters/SKILL.md:345 records that without folder trust
  # the primary turn-end guard fails open, README.md:105 and
  # docs/turnend-guard.md:63 say the same, and trust being granted once per clone
  # means a fresh clone is exactly when dropping it bites.
  assert_template primary grok 'grok --trust --always-approve __MODELFLAG____EFFORTFLAG__'
  pass "launch_template: the grok primary template is pinned, --trust included"
}

test_primary_kimi_refuses() {
  # README.md:61 lists only Claude Code, Grok, Pi, pi-signed, Codex, and OpenCode
  # as verified primary harnesses (docs/configuration.md:177 defers that narrower
  # set to README), and __KIMIBIN__ is resolvable by bin/fm-spawn.sh alone, which never
  # launches a primary. Refusing beats handing back an unsubstitutable command.
  launch_template kimi primary >/dev/null 2>&1 \
    && fail "launch_template kimi primary must refuse: kimi is not a verified primary harness and only fm-spawn.sh can resolve __KIMIBIN__"
  [ -z "$(launch_template kimi primary 2>/dev/null)" ] \
    || fail "launch_template kimi primary must emit nothing when it refuses"
  pass "launch_template: kimi has no primary template and refuses instead of emitting __KIMIBIN__"
}

test_primary_kimi_refusal_leaves_the_crewmate_template_intact() {
  # bin/fm-spawn.sh depends on the kimi crewmate command byte-for-byte.
  local kind
  for kind in ship scout secondmate; do
    assert_template "$kind" kimi '__KIMIBIN__ __MODELFLAG__--auto'
  done
  pass "launch_template: the kimi crewmate template is unaffected by the primary refusal"
}

test_primary_carries_no_task_scoped_placeholder() {
  local h tpl
  for h in "${PRIMARY_HARNESSES[@]}"; do
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
  assert_contains "$(launch_template grok primary)" '--trust' \
    "the grok primary template must keep --trust, without which the primary turn-end guard fails open"
  assert_contains "$(launch_template opencode primary)" '"permission":{"*":"allow"}' \
    "the opencode primary template must keep its permission config"
  assert_contains "$(launch_template opencode primary)" '--auto' \
    "the opencode primary template must keep the verified briefless --auto form"
  pass "launch_template: primary templates keep each adapter's verified autonomy and ghost-text knowledge"
}

test_primary_and_ship_share_a_model_and_effort_surface() {
  local h
  for h in "${PRIMARY_HARNESSES[@]}"; do
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
  #
  # The two --auto markers are anchored to the binary they belong to. A bare
  # --auto would also match unrelated legitimate flags - `gh pr merge --auto` in
  # bin/fm-pr-*.sh is the obvious one - and fail with a misleading "a launch
  # command is hand-written" message. Double-quoted so the single quote inside
  # the character class stays literal; it stops the match at the template's own
  # quoting so the pattern cannot run past the end of a launch string.
  local markers=(
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION'
    '--dangerously-skip-permissions'
    '--dangerously-bypass-approvals-and-sandbox'
    'OPENCODE_CONFIG_CONTENT='
    '--always-approve'
    "opencode [^']*--auto([^-a-z]|$)"
    "(kimi|__KIMIBIN__)[^']*--auto([^-a-z]|$)"
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
test_primary_claude_template_is_pinned
test_primary_codex_template_is_pinned
test_primary_opencode_template_is_pinned
test_primary_pi_template_is_pinned
test_primary_grok_template_is_pinned
test_primary_kimi_refuses
test_primary_kimi_refusal_leaves_the_crewmate_template_intact
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
