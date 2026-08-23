#!/usr/bin/env bash
# Characterization coverage for session-lock harness identity helpers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-session-lock-lib.sh disable=SC1091
. "$ROOT/bin/fm-session-lock-lib.sh"

test_harness_path_matching_requires_a_whole_path_component() {
  local claude_path="/opt/claude/versions/2.1.220"
  local ordinary_path="/opt/.claude/hooks/notify.sh"
  local cursor_path="/Users/u/.local/bin/cursor-agent"
  local cursor_share="/Users/u/.local/share/cursor-agent/versions/2026.08.11-e8db854/index.js"
  local cursor_hooks="/Users/u/.cursor/hooks/notify.sh"
  local cursor_app="/Applications/Cursor.app/Contents/MacOS/Cursor"
  local cursor_helper="/usr/bin/cursor-agent-helper"

  [ "$(fm_harness_path_name "$claude_path")" = claude ] \
    || fail "Claude install path was not identified as claude"
  if fm_harness_path_name "$ordinary_path"; then
    fail "ordinary Claude-named path was incorrectly identified as a harness"
  fi
  [ "$(fm_harness_path_name "$cursor_path")" = cursor-agent ] \
    || fail "cursor-agent install path was not identified as cursor-agent"
  [ "$(fm_harness_path_name "$cursor_share")" = cursor-agent ] \
    || fail "cursor-agent versioned install path was not identified as cursor-agent"
  if fm_harness_path_name "$cursor_hooks"; then
    fail "ordinary .cursor hook path was incorrectly identified as a harness"
  fi
  if fm_harness_path_name "$cursor_app"; then
    fail "Cursor.app was incorrectly identified as cursor-agent"
  fi
  if fm_harness_path_name "$cursor_helper"; then
    fail "cursor-agent-helper was incorrectly identified as cursor-agent"
  fi
  pass "session-lock-lib: harness matching accepts install components but rejects ordinary paths"
}

test_harness_path_matching_requires_a_whole_path_component
