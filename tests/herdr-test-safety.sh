#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh}
# shellcheck source=/dev/null
. "$HERDR_LAB_HELPER"

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

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

# Route a test's indirect CLI calls through the existing guarded lab owner.
# Caller installs its teardown trap and provisions the exact session first.
# The wrapper never grants lifecycle authority; those verbs remain helper-only.
herdr_test_guard_cli() { # <lab-session> <wrapper-dir> [helper]
  local session=$1 wrapper=$2 helper=${3:-$HERDR_LAB_HELPER} real
  fm_herdr_lab_validate_name "$session" || return 1
  real=$(command -v herdr) || return 1
  mkdir -p "$wrapper" || return 1
  cat > "$wrapper/herdr" <<EOF
#!/usr/bin/env bash
set -eu
real=$(printf '%q' "$real")
helper=$(printf '%q' "$helper")
lab=$(printf '%q' "$session")
if [ "\${FM_HERDR_TEST_HELPER_CALL:-}" = 1 ]; then exec "\$real" "\$@"; fi
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$lab" ] || { echo 'refused foreign test session' >&2; exit 97; }
  unset 'args[n-1]' 'args[n-2]'
fi
FM_HERDR_TEST_HELPER_CALL=1 exec "\$helper" run "\$lab" "\${args[@]}"
EOF
  chmod +x "$wrapper/herdr"
}
