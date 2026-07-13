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

# Return 0 when the safety tripwire can run, 1 when the valid default session is
# merely stopped, and 2 for malformed or unreadable fleet state. Callers may skip
# only status 1 so a broken Herdr API or tripwire still fails loudly.
herdr_test_lab_available() {
  local sessions state
  sessions=$(fm_herdr_lab_session_list fm-lab-preflight 2>/dev/null) || {
    echo "not ok - could not read Herdr fleet state for lab safety" >&2
    return 2
  }
  state=$(printf '%s' "$sessions" | jq -er '
    [.sessions[]? | select(.default == true)] as $defaults
    | if ($defaults | length) != 1 or $defaults[0].name != "default" then "invalid"
      elif $defaults[0].running == true then "running"
      elif $defaults[0].running == false then "stopped"
      else "invalid"
      end
  ' 2>/dev/null) || {
    echo "not ok - malformed Herdr fleet state for lab safety" >&2
    return 2
  }
  case "$state" in
    running) return 0 ;;
    stopped) return 1 ;;
    *)
      echo "not ok - Herdr fleet state lacks exactly one valid default session" >&2
      return 2
      ;;
  esac
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
