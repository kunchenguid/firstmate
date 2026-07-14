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
HERDR_TEST_LAB_HELPER="$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"
HERDR_TEST_REAL_PATH=${HERDR_TEST_REAL_PATH:-$PATH}
HERDR_TEST_SHIM_DIR=
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_LAB_HELPER"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  local rc=0
  PATH="$HERDR_TEST_REAL_PATH" "$HERDR_TEST_LAB_HELPER" teardown "$1" || rc=$?
  [ -z "$HERDR_TEST_SHIM_DIR" ] || rm -rf "$HERDR_TEST_SHIM_DIR"
  HERDR_TEST_SHIM_DIR=
  return "$rc"
}

herdr_test_provision() { # <session>
  PATH="$HERDR_TEST_REAL_PATH" "$HERDR_TEST_LAB_HELPER" provision "$1"
}

herdr_test_stop() { # <session>
  PATH="$HERDR_TEST_REAL_PATH" "$HERDR_TEST_LAB_HELPER" stop "$1"
}

herdr_test_route_calls() { # <session>
  local session=$1
  HERDR_TEST_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-test-shim.XXXXXX")
  cat > "$HERDR_TEST_SHIM_DIR/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$session' ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = '$session' ] || exit 98
fi
PATH='$HERDR_TEST_REAL_PATH' exec '$HERDR_TEST_LAB_HELPER' run '$session' "\${args[@]}"
EOF
  chmod +x "$HERDR_TEST_SHIM_DIR/herdr"
  PATH="$HERDR_TEST_SHIM_DIR:$HERDR_TEST_REAL_PATH"
  export PATH
}
