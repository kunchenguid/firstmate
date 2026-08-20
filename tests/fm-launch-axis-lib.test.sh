#!/usr/bin/env bash
# Characterization coverage for the shared per-harness effort-axis table.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-launch-axis-lib.sh disable=SC1091
. "$ROOT/bin/fm-launch-axis-lib.sh"

[ "$(effort_flag_for_harness claude max)" = "--effort 'max' " ] \
  || fail "Claude max effort flag changed"
[ "$(effort_flag_for_harness codex high)" = "-c 'model_reasoning_effort=\"high\"' " ] \
  || fail "Codex high effort flag changed"
[ "$(effort_flag_for_harness pi-signed max)" = "--thinking 'max' " ] \
  || fail "Pi-signed max effort flag changed"
[ -z "$(effort_flag_for_harness codex max)" ] \
  || fail "Codex max must not emit an unsupported launch flag"
[ -z "$(effort_flag_for_harness opencode high)" ] \
  || fail "OpenCode must not emit an unverified effort flag"

[ "$(fm_effort_axis_state claude max)" = supported ] \
  || fail "Claude max should be supported"
[ "$(fm_effort_axis_state codex max)" = capped ] \
  || fail "Codex max should be capped"
[ "$(fm_effort_axis_state opencode high)" = unsupported ] \
  || fail "OpenCode effort should be unsupported"

pass "launch-axis-lib maps supported, capped, and unsupported effort levels"
echo "# fm-launch-axis-lib.test.sh: all assertions passed"
