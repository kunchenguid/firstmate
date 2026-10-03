#!/usr/bin/env bash
# Behavior tests for the committed Claude hook commands in .claude/settings.json:
# with CLAUDE_PROJECT_DIR unset, every hook command must exit 0 without ever
# reaching its target script, so a non-Claude harness (or an empty project dir)
# never sees a command-not-found hook failure.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTINGS="$ROOT/.claude/settings.json"

test_every_hook_command_exits_zero_with_unset_project_dir() {
  local count=0 hook_command status
  [ -f "$SETTINGS" ] || fail "missing $SETTINGS"
  command -v jq >/dev/null 2>&1 || fail "jq is required to enumerate hook commands"

  while IFS= read -r hook_command; do
    count=$((count + 1))
    status=0
    env -u CLAUDE_PROJECT_DIR -u GROK_AGENT -u GROK_HOOK_EVENT \
      bash -c "$hook_command" </dev/null >/dev/null 2>&1 || status=$?
    [ "$status" -eq 0 ] || fail "hook command $count exited $status with CLAUDE_PROJECT_DIR unset: $hook_command"
  done < <(jq -r '.hooks[][].hooks[].command' "$SETTINGS")

  [ "$count" -gt 0 ] || fail "no hook commands enumerated from $SETTINGS"
  pass "all $count tracked Claude hook commands exit 0 with CLAUDE_PROJECT_DIR unset"
}

test_every_hook_command_exits_zero_with_unset_project_dir
