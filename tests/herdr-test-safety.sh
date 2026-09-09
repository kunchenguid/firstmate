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

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

# herdr_hold_pane_with_agent_process: put a real, long-lived NON-shell process
# in <pane>'s foreground and wait until herdr itself reports it.
#
# A `pane report-agent` registration alone no longer means "an agent is
# running here": fm_backend_herdr_pane_agent_state cross-checks the pane's
# real processes and reads a registration over a shell-only foreground as the
# stale husk it is (bin/backends/herdr.sh; docs/herdr-backend.md "Stale agent
# registration"). A live-agent fixture therefore needs a process, not just a
# registry row - `sleep` stands in for the harness so no agent, model, or
# token is spent. Returns 1 rather than proceeding if herdr never reports the
# process, so a fixture can never silently degrade into the husk shape it is
# supposed to be the opposite of.
herdr_hold_pane_with_agent_process() { # <session> <pane> [seconds]
  local session=$1 pane=$2 hold=${3:-900} attempt=0 names
  fm_herdr_lab_raw "$session" pane run "$pane" sleep "$hold" >/dev/null 2>&1 || return 1
  while [ "$attempt" -lt 50 ]; do
    names=$(fm_herdr_lab_raw "$session" pane process-info --pane "$pane" 2>/dev/null \
      | jq -r '.result.process_info.foreground_processes[]?.name' 2>/dev/null)
    case "$names" in
      *sleep*) return 0 ;;
    esac
    sleep 0.2
    attempt=$((attempt + 1))
  done
  return 1
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
