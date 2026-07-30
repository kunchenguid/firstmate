#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

# herdr_test_neutral_config: point this test process at an empty scratch config
# directory. Call it from any test that asserts the DEFAULT "firstmate"
# workspace label while resolving the adapter against this repo root: when that
# root is also a live firstmate home, its own config/herdr-workspace-label would
# otherwise change the label under test. Not applied at source time, because a
# test driving fm-spawn.sh against a scratch home needs that home's real config
# directory (config/herdr-presentation-spaces, config/backend).
herdr_test_neutral_config() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-neutral-config.XXXXXX") || return 1
  export FM_CONFIG_OVERRIDE="$dir"
  printf '%s' "$dir"
}
