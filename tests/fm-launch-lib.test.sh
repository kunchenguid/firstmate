#!/usr/bin/env bash
# tests/fm-launch-lib.test.sh - the shared launch contract (bin/fm-launch-lib.sh)
# extracted from fm-spawn.sh: verified launch templates, model/effort flag
# rendering, the Fable effort cap, placeholder rendering, and per-harness
# turn-end hook installation with git-exclusion semantics.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-launch-lib.sh
. "$ROOT/bin/fm-launch-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-launch-lib-tests)

test_templates_match_verified_commands() {
  local t
  t=$(fm_launch_template claude ship)
  # shellcheck disable=SC2016  # golden template string: placeholders expand in the crewmate pane, not here
  [ "$t" = 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ] \
    || fail "claude ship template drifted: $t"
  t=$(fm_launch_template codex ship)
  assert_contains "$t" 'notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]' "codex ship template lost the turn-end notify"
  t=$(fm_launch_template codex secondmate)
  assert_not_contains "$t" 'notify' "codex secondmate template must not carry notify"
  t=$(fm_launch_template opencode ship)
  assert_contains "$t" 'opencode __MODELFLAG__--prompt' "opencode template drifted: $t"
  t=$(fm_launch_template pi ship)
  assert_contains "$t" '-e __PIEXT__' "pi ship template lost the turn-end extension"
  t=$(fm_launch_template pi secondmate)
  assert_contains "$t" '-e __PITURNEND__ -e __PIWATCH__' "pi secondmate template lost the home extensions"
  t=$(fm_launch_template grok ship)
  assert_contains "$t" 'grok --always-approve' "grok template drifted: $t"
  if fm_launch_template unverified ship >/dev/null 2>&1; then
    fail "unknown harness must have no template"
  fi
  pass "launch templates match the verified commands"
}

test_model_and_effort_flags() {
  local f
  f=$(fm_launch_model_flag claude 'claude-fable-5[1m]')
  [ "$f" = "--model 'claude-fable-5[1m]' " ] || fail "bracketed model flag misquoted: $f"
  [ -z "$(fm_launch_model_flag claude default)" ] || fail "default model must render no flag"
  [ -z "$(fm_launch_model_flag claude '')" ] || fail "empty model must render no flag"
  f=$(fm_launch_effort_flag codex xhigh)
  [ "$f" = "-c 'model_reasoning_effort=\"xhigh\"' " ] || fail "codex xhigh flag drifted: $f"
  [ -z "$(fm_launch_effort_flag codex max)" ] || fail "codex max must be omitted"
  [ -z "$(fm_launch_effort_flag grok xhigh)" ] || fail "grok xhigh must be omitted"
  f=$(fm_launch_effort_flag grok high)
  [ "$f" = "--reasoning-effort 'high' " ] || fail "grok high flag drifted: $f"
  f=$(fm_launch_effort_flag pi max)
  [ "$f" = "--thinking 'max' " ] || fail "pi max flag drifted: $f"
  [ -z "$(fm_launch_effort_flag opencode high)" ] || fail "opencode has no verified effort flag"
  pass "model and effort flags render as verified"
}

test_fable_effort_cap() {
  [ "$(fm_launch_fable_effort_cap claude 'claude-fable-5[1m]' xhigh)" = high ] || fail "Fable xhigh must clamp to high"
  [ "$(fm_launch_fable_effort_cap claude 'claude-fable-5[1m]' max)" = high ] || fail "Fable max must clamp to high"
  [ "$(fm_launch_fable_effort_cap claude 'claude-fable-5[1m]' high)" = high ] || fail "Fable high stays high"
  [ "$(fm_launch_fable_effort_cap claude 'claude-fable-5[1m]' low)" = low ] || fail "Fable low stays low"
  [ "$(fm_launch_fable_effort_cap claude 'claude-fable-5[1m]' default)" = default ] || fail "Fable default stays default"
  [ "$(fm_launch_fable_effort_cap claude claude-sonnet-5 xhigh)" = xhigh ] || fail "non-Fable claude models are not clamped"
  [ "$(fm_launch_fable_effort_cap pi ollama/kimi-k2.7-code xhigh)" = xhigh ] || fail "pi models are not clamped"
  [ "$(fm_launch_fable_effort_cap codex gpt-5.6-sol xhigh)" = xhigh ] || fail "codex models are not clamped"
  pass "Fable effort cap clamps xhigh/max to high for Fable launches only"
}

test_render_substitutes_placeholders_and_applies_cap() {
  local rendered
  rendered=$(fm_launch_render "$(fm_launch_template claude ship)" claude 'claude-fable-5[1m]' xhigh \
    /tmp/brief.md /tmp/turnend /tmp/piext /tmp/piturnend /tmp/piwatch)
  assert_contains "$rendered" "--model 'claude-fable-5[1m]'" "render lost the model flag"
  assert_contains "$rendered" "--effort 'high'" "render must apply the Fable cap at the choke point"
  assert_not_contains "$rendered" "xhigh" "render must not leak the uncapped effort"
  assert_contains "$rendered" "cat '/tmp/brief.md'" "render lost the quoted brief path"
  assert_not_contains "$rendered" "__MODELFLAG__" "render left a placeholder behind"
  rendered=$(fm_launch_render "$(fm_launch_template pi ship)" pi ollama/kimi-k2.7-code xhigh \
    /tmp/brief.md /tmp/turnend /tmp/piext /tmp/piturnend /tmp/piwatch)
  assert_contains "$rendered" "--model 'ollama/kimi-k2.7-code'" "pi render lost the model flag"
  assert_contains "$rendered" "--thinking 'xhigh'" "pi render must keep uncapped effort for non-Fable routes"
  assert_contains "$rendered" "-e '/tmp/piext'" "pi render lost the turn-end extension path"
  pass "render substitutes placeholders and applies the Fable cap"
}

test_turnend_hook_install() {
  local dir wt state excl
  dir="$TMP_ROOT/hooks"
  wt="$dir/wt"
  state="$dir/state"
  mkdir -p "$state"
  fm_git_worktree "$dir/proj" "$wt" fm/hooks-case

  fm_launch_install_turnend_hook claude "$wt" "$state" hk1 "$state/hk1.turn-ended"
  assert_present "$wt/.claude/settings.local.json" "claude hook file missing"
  assert_grep "touch '$state/hk1.turn-ended'" "$wt/.claude/settings.local.json" "claude hook lost the turn-end touch"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_grep '.claude/settings.local.json' "$excl" "claude hook not git-excluded"
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "claude hook must not dirty the worktree"

  fm_launch_install_turnend_hook opencode "$wt" "$state" hk1 "$state/hk1.turn-ended"
  assert_present "$wt/.opencode/plugins/fm-turn-end.js" "opencode plugin missing"
  assert_grep '.opencode/plugins/fm-turn-end.js' "$excl" "opencode plugin not git-excluded"

  fm_launch_install_turnend_hook pi "$wt" "$state" hk1 "$state/hk1.turn-ended"
  assert_present "$state/hk1.pi-ext.ts" "pi extension must live in state/, outside the worktree"
  assert_grep 'turn_end' "$state/hk1.pi-ext.ts" "pi extension must listen for turn_end"
  assert_absent "$wt/.pi" "pi hook must not write into the worktree"

  fm_launch_install_turnend_hook codex "$wt" "$state" hk1 "$state/hk1.turn-ended"
  assert_absent "$state/hk1.grok-turnend-token" "codex install must be a no-op"

  GROK_HOME="$dir/grokhome" fm_launch_install_turnend_hook grok "$wt" "$state" hk1 "$state/hk1.turn-ended"
  assert_present "$dir/grokhome/hooks/fm-turn-end.sh" "grok global hook script missing"
  assert_present "$dir/grokhome/hooks/fm-turn-end.json" "grok global hook registration missing"
  assert_present "$state/hk1.grok-turnend-token" "grok state token missing"
  assert_present "$wt/.fm-grok-turnend" "grok worktree pointer missing"
  assert_grep '.fm-grok-turnend' "$excl" "grok pointer not git-excluded"
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "grok hook must not dirty the worktree"
  pass "turn-end hooks install with normal spawn semantics per harness"
}

test_templates_match_verified_commands
test_model_and_effort_flags
test_fable_effort_cap
test_render_substitutes_placeholders_and_applies_cap
test_turnend_hook_install
