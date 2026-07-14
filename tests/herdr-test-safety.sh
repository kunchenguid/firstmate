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
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

# The lab's fleet-state tripwire (fm_herdr_lab_prepare) requires exactly one
# RUNNING default session, so on a machine where herdr is installed but its
# default session is stopped every prepare refuses. Probe that precondition so
# real-Herdr tests can skip cleanly, mirroring the herdr-not-installed skip.
herdr_lab_ready() { # <session>
  fm_herdr_lab_fleet_state "$1" >/dev/null 2>&1
}

herdr_lab_skip() {
  echo "skip: herdr default session is not running (lab fleet-state precondition)"
  exit 0
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
