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

# Print the suite's skip line and return 1 when this environment cannot host an
# isolated lab session; print nothing and return 0 when it can. The verdict comes
# from bin/fm-herdr-lab.sh's gate, so a test never gates on "herdr" being on PATH
# (which proves nothing about session state) and never hard-fails on a
# precondition it cannot create. Callers decide whether to exit 0 or return 0.
# The context label names the gated work, which a file with more than one gate
# needs and a suite log always benefits from.
herdr_lab_gate_or_skip() { # <context>
  local reason
  reason=$(fm_herdr_lab_gate) && return 0
  printf 'skip: %s (%s)\n' "$reason" "${1:-real-herdr lab}"
  return 1
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
