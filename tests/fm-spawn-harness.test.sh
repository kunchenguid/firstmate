#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh harness launch templates.
# These exercise harness recognition only: each spawn attempt fails fast at the
# missing-brief check, reached before any tmux/treehouse side effect.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-harness)

run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$TMP_ROOT" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# kimi-cli harness must be recognised and reach the missing-brief check.
test_kimi_cli_harness_recognised() {
  local out status proj
  proj="$TMP_ROOT/projects/fakeproj"
  mkdir -p "$proj" "$TMP_ROOT/data/audit-harness-k3"
  printf '# fake brief\n' > "$TMP_ROOT/data/audit-harness-k3/brief.md"
  out=$(run_spawn audit-harness-k3 projects/fakeproj kimi-cli)
  status=$?
  [ "$status" -ne 0 ] || fail "missing treehouse/tmux should exit non-zero"
  assert_not_contains "$out" "unknown harness" "kimi-cli should not be treated as unknown"
  pass "kimi-cli harness is recognised by launch template"
}

test_kimi_cli_harness_recognised
