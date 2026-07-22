#!/usr/bin/env bash
# Behavior tests for the partial cursor-agent crew oneshot adapter:
# launch template, harness usage listing, and crew-harness resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-agent-harness)

# Extract launch_template() from fm-spawn.sh and evaluate the cursor-agent case
# without running a full spawn (avoids backend/treehouse fixtures).
extract_launch_template() {
  # shellcheck disable=SC1090
  eval "$(sed -n '/^launch_template()/,/^}/p' "$ROOT/bin/fm-spawn.sh")"
}

test_usage_lists_cursor_agent() {
  assert_grep 'cursor-agent' "$ROOT/bin/fm-harness.sh" \
    "fm-harness.sh should list cursor-agent in usage/comments"
  pass "fm-harness.sh lists cursor-agent"
}

test_launch_template_cursor_agent() {
  local got
  extract_launch_template
  got=$(launch_template cursor-agent) || fail "launch_template cursor-agent returned non-zero"
  assert_contains "$got" 'cursor-agent -p --force --trust' \
    "launch template missing oneshot flags"
  # Intentional literals: template must contain the characters $(pwd) / $(cat …),
  # not their expansions. shellcheck SC2016 would otherwise false-positive.
  # shellcheck disable=SC2016
  assert_contains "$got" '--workspace "$(pwd)"' \
    "launch template missing --workspace"
  # shellcheck disable=SC2016
  assert_contains "$got" '"$(cat __BRIEF__)"' \
    "launch template missing brief cat"
  if launch_template cursor >/dev/null 2>&1; then
    fail "bare 'cursor' must not have a launch template (canonical name is cursor-agent)"
  fi
  pass "launch_template emits cursor-agent oneshot command"
}

test_crew_harness_resolves_cursor_agent() {
  local cfg got
  cfg="$TMP_ROOT/config"
  mkdir -p "$cfg"
  printf '%s\n' 'cursor-agent' > "$cfg/crew-harness"
  # Force own unknown: clear every Layer-1 marker detect_own checks, including
  # CURSOR_AGENT which this Builder session itself may set.
  got=$(
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT \
      FM_CONFIG_OVERRIDE="$cfg" \
      "$ROOT/bin/fm-harness.sh" crew
  )
  [ "$got" = "cursor-agent" ] || fail "crew resolved '$got', expected cursor-agent"
  pass "config/crew-harness=cursor-agent resolves crew to cursor-agent"
}

test_detect_own_cursor_agent_env() {
  local got cfg
  cfg="$TMP_ROOT/empty-config"
  mkdir -p "$cfg"
  got=$(
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      CURSOR_AGENT=1 \
      FM_CONFIG_OVERRIDE="$cfg" \
      "$ROOT/bin/fm-harness.sh"
  )
  [ "$got" = "cursor-agent" ] || fail "detect_own with CURSOR_AGENT=1 returned '$got'"
  pass "CURSOR_AGENT=1 detects as cursor-agent"
}

test_usage_lists_cursor_agent
test_launch_template_cursor_agent
test_crew_harness_resolves_cursor_agent
test_detect_own_cursor_agent_env
