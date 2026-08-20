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

  [ "$(fm_harness_path_name "$claude_path")" = claude ] \
    || fail "Claude install path was not identified as claude"
  if fm_harness_path_name "$ordinary_path"; then
    fail "ordinary Claude-named path was incorrectly identified as a harness"
  fi
  pass "session-lock-lib: harness matching accepts install components but rejects ordinary paths"
}

test_harness_path_matching_requires_a_whole_path_component
