#!/usr/bin/env bash
# Characterization coverage for the gate-agent refusal library's env guard.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gate-refuse-lib)
GATE_LIB="$ROOT/bin/fm-gate-refuse-lib.sh"

run_guard_with_env_marker() {
  (
    cd "$TMP_ROOT" || exit 111
    unset FM_GATE_REFUSE_BYPASS
    export NO_MISTAKES_GATE=1
    # shellcheck source=/dev/null
    . "$GATE_LIB"
    fm_refuse_if_gate_agent
  ) 2>&1
}

output=$(run_guard_with_env_marker)
rc=$?
expect_code 3 "$rc" "env marker must refuse with the gate exit code"
assert_contains "$output" 'NO_MISTAKES_GATE set' \
  "env marker refusal must identify the active signal"

pass "fm-gate-refuse-lib refuses a gate agent from the environment marker"
echo "# fm-gate-refuse-lib.test.sh: all assertions passed"
