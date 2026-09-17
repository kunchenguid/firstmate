#!/usr/bin/env bash
# tests/fm-presenter-blocks.test.sh - CI entry point for the presenter
# technical-content-blocks pytest suites in tests/presenter/blocks and
# tests/presenter/artifacts.
#
# The portable CI lanes execute only tests/*.test.sh, so the Python suites
# behind presenter.blocks and presenter.artifacts are invisible to CI without
# this wrapper: a green CI run would never execute the slice's own tests
# anywhere. The wrapper builds an ephemeral venv with pinned pytest, NumPy,
# matplotlib, and SymPy versions and runs both suites through the public
# pytest interface, asserting the passed count so an empty collection cannot
# pass. Missing prerequisites hard-fail rather than gate-skip: hosted CI
# provides python3 and pip (the herdr lane already asserts python3), and a
# silent skip would turn required presenter coverage into a false green - the
# same posture as the Pi extension typecheck lane's --fail-on-gate-skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Pins match the versions the suites were developed and reviewed against.
PYTEST_PIN=9.1.1
NUMPY_PIN=2.3.5
MATPLOTLIB_PIN=3.10.7
SYMPY_PIN=1.14.0

BLOCKS_SUITE="$ROOT/tests/presenter/blocks"
ARTIFACTS_SUITE="$ROOT/tests/presenter/artifacts"
TMP_ROOT=$(fm_test_tmproot fm-presenter-blocks)

test_python3_prerequisites_are_present() {
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to run the presenter blocks suite"
  python3 -m venv --help >/dev/null 2>&1 \
    || fail "python3 venv module is required to build the ephemeral presenter test environment"
  pass "python3 and its venv module are available"
}

test_pytest_suites_pass_under_pinned_deps() {
  local venv_python="$TMP_ROOT/venv/bin/python"
  local out summary passed
  python3 -m venv "$TMP_ROOT/venv" >/dev/null 2>&1 \
    || fail "ephemeral venv creation failed"
  PIP_DISABLE_PIP_VERSION_CHECK=1 "$venv_python" -m pip install --quiet \
    "pytest==$PYTEST_PIN" \
    "numpy==$NUMPY_PIN" \
    "matplotlib==$MATPLOTLIB_PIN" \
    "sympy==$SYMPY_PIN" \
    >"$TMP_ROOT/pip-install.log" 2>&1 \
    || fail "pinned pytest/NumPy/matplotlib/SymPy install failed; see pip-install.log in the test temp root"
  # MPLCONFIGDIR keeps matplotlib's font-cache and config writes inside the
  # ephemeral temp root instead of the invoking user's home.
  out=$(MPLCONFIGDIR="$TMP_ROOT/mplconfig" PYTHONDONTWRITEBYTECODE=1 \
    "$venv_python" -m pytest "$BLOCKS_SUITE" "$ARTIFACTS_SUITE" -q 2>&1) \
    || { printf '%s\n' "$out"; fail "presenter blocks pytest suites failed"; }
  summary=$(printf '%s\n' "$out" | tail -n 1)
  passed=${summary%% passed*}
  case $passed in
    ''|*[!0-9]*)
      printf '%s\n' "$out"
      fail "could not read a passed count from the pytest summary: $summary"
      ;;
  esac
  [ "$passed" -ge 1 ] || { printf '%s\n' "$out"; fail "pytest collected no presenter blocks tests"; }
  printf '%s\n' "$summary"
  pass "presenter blocks suites pass under pinned pytest ($passed tests)"
}

test_python3_prerequisites_are_present
test_pytest_suites_pass_under_pinned_deps
