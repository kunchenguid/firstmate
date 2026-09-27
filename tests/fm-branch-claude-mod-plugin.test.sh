#!/usr/bin/env bash
# The Claude Code supervision-branch mod (.claude/mods/fm-branch-mod) under the
# real installed Claude Code: `claude plugin validate --strict` on the mod
# folder, then its own `claude plugin test` suite (tests/branch.test.ts inside
# the mod), which runs the hooks module in the engine's own host against a
# mocked clock, environment, file system, classifier, and process runner. No
# model turn is submitted and no credential is spent, so the guard runs by
# default wherever `claude` is installed; the portable checks that need no
# Claude Code binary live in tests/fm-branch-claude-mod.test.sh, and the pinned
# end-to-end session in tests/fm-branch-claude-mod-live-e2e.test.sh.
#
# The early-access function-hooks surface is default-off; the flag is set on
# this test's own processes only and never written into any settings file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_BRANCH_MOD_PLUGIN_TEST claude

MOD="$ROOT/.claude/mods/fm-branch-mod"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-branch-claude-mod-plugin)

expect_in_report() {
  local report=$1 needle=$2 what=$3
  case "$report" in
    *"$needle"*) : ;;
    *)
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION: $what (missing '$needle')"
      ;;
  esac
}

test_validate_strict() {
  local report
  if ! report=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin validate --strict "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION refused the supervision-branch mod under strict validation"
  fi
  # The scan is the engine's own reading of the module: the events it hooks,
  # the capabilities it calls, and the environment names it may read. Anything
  # more or less is a drift from docs/claude-supervision-branch.md.
  expect_in_report "$report" "hooks: session.start, turn.start, prompt.submit, tool.call, turn.step, session.compact, turn.complete" "the module hooks a different event set"
  expect_in_report "$report" "\$.agent.spawn" "the module never spawns the branch"
  expect_in_report "$report" "\$.model.complete" "the module never calls the classifier"
  expect_in_report "$report" "\$.tool.register" "the module never registers the branch's report tools"
  # The FM_CLASSIFY_* names are the fold vocabulary overrides bash honours
  # (bin/fm-classify-lib.sh); the canonical shared fold reads them through
  # the host env seam so the mod's verdicts track bash under an override too.
  expect_in_report "$report" "env reads: CLAUDE_CODE_CHILD_SESSION, CLAUDE_CODE_FORCE_SESSION_PERSISTENCE, FM_CLASSIFY_CAPTAIN_HELD_VERB, FM_CLASSIFY_PAUSED_VERB, FM_CLASSIFY_RESERVED_KEY_PREFIXES, FM_CLASSIFY_RESOLVE_VERB, FM_CONFIG_OVERRIDE, FM_HOME, FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE" "the module reads a different environment"
  expect_in_report "$report" "env writes: nothing" "the module writes the environment"
  case "$report" in
    *"http.fetch"*|*"env.set"*|*"ui.render"*)
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION scanned a capability the supervision-branch mod must not use"
      ;;
  esac
  pass "Claude Code $CLAUDE_VERSION validates the supervision-branch mod strictly: the documented hooks, the spawn, the classifier, and only the home-resolution, transcript-persistence, and fold-vocabulary environment"
}

test_plugin_suite() {
  local report
  if ! report=$(cd "$TMP_ROOT" && CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION failed the supervision-branch mod's plugin test suite"
  fi
  printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION ran no supervision-branch mod plugin test"
  }
  printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION reported supervision-branch mod plugin test failures"
  }
  pass "Claude Code $CLAUDE_VERSION runs the supervision-branch mod's plugin test suite clean: pin refusal, classification records, captain hand-back, and routine spawn"
}

test_validate_strict
test_plugin_suite
