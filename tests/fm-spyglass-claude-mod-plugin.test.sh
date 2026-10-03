#!/usr/bin/env bash
# The Claude Code Spyglass mod (.claude/mods/firstmate-spyglass) under the real installed
# Claude Code: `claude plugin validate --strict` on the physical folder and on the
# `.claude/skills/firstmate-spyglass` path the project auto-loads it from, then its own
# `claude plugin test` suites (tests/*.test.ts inside the mod), which run the hooks
# module in the engine's own host against a mocked clock, environment, file system,
# process runner, and drawing surface. No model turn is submitted and no credential is
# spent, so the guard runs by default wherever `claude` is installed; the portable checks
# that need no Claude Code binary live in tests/fm-spyglass-claude-mod.test.sh.
#
# The early-access function-hooks surface is default-off; the flag is set on this
# test's own processes only and never written into any settings file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_SPYGLASS_PLUGIN_TEST claude

MOD="$ROOT/.claude/mods/firstmate-spyglass"
AUTOLOAD_PATH="$ROOT/.claude/skills/firstmate-spyglass"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-spyglass-claude-mod-plugin)

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
  local path report
  for path in "$MOD" "$AUTOLOAD_PATH"; do
    if ! report=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin validate --strict "$path" 2>&1); then
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION refused the Spyglass mod at $path under strict validation"
    fi
    # The scan is the engine's own reading of the module: the events it will hook
    # and the environment names it may read. Anything more or less is a drift.
    expect_in_report "$report" "session.start" "the scan of $path does not hook session start"
    expect_in_report "$report" "ui.focus" "the scan of $path does not hook the focus ring"
    expect_in_report "$report" "command.run{command=fleet}" "the scan of $path does not serve /fleet"
    expect_in_report "$report" "ui.render{component=Pane, requestId=spyglass}" "the scan of $path does not draw the fleet pane"
    expect_in_report "$report" "ui.render{component=Pane, requestId=spyglass-session}" "the scan of $path does not draw the session pane"
    expect_in_report "$report" "env reads: CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, FM_HOME, FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE" "the scan of $path reads a different environment"
    expect_in_report "$report" "env writes: nothing" "the scan of $path writes the environment"
    case "$report" in
      *"fs.write"*|*"http.fetch"*|*"env.set"*|*"tool.call"*)
        printf '%s\n' "$report" >&2
        fail "Claude Code $CLAUDE_VERSION scanned a capability the Spyglass mod must not use at $path"
        ;;
    esac
  done
  pass "Claude Code $CLAUDE_VERSION validates the Spyglass mod strictly at its folder and its auto-load path, hooking exactly session start, /fleet, the focus ring, and its two panes, and writing neither files nor the environment"
}

test_plugin_suites() {
  local report
  if ! report=$(cd "$TMP_ROOT" && CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION failed the Spyglass mod's plugin test suites"
  fi
  printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION ran no Spyglass mod plugin test"
  }
  printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION reported Spyglass mod plugin test failures"
  }
  pass "Claude Code $CLAUDE_VERSION runs the Spyglass mod's plugin test suites clean: exact opt-in, silence outside a Firstmate home, the fleet and its status line, both panes, the update flag, and the read-only boundary"
}

test_validate_strict
test_plugin_suites
