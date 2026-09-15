#!/usr/bin/env bash
# tests/fm-presenter-render-docx.test.sh - CI entry point for the presenter
# render_docx pytest suite in tests/presenter/render_docx.
#
# The portable CI lanes execute only tests/*.test.sh, so the Python suite
# behind presenter.render_docx is invisible to CI without this wrapper: a
# green CI run would never execute the slice's own tests anywhere. The
# wrapper builds an ephemeral venv with pinned pytest, python-docx, and
# Pillow versions and runs the suite through the public pytest interface,
# asserting the passed count so an empty collection cannot pass. Missing
# prerequisites hard-fail rather than gate-skip: hosted CI provides python3
# and pip (the herdr lane already asserts python3), and a silent skip would
# turn required presenter coverage into a false green - the same posture as
# the Pi extension typecheck lane's --fail-on-gate-skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Pins match the versions the suite was developed and reviewed against.
PYTEST_PIN=9.1.1
PYTHON_DOCX_PIN=1.2.0
PILLOW_PIN=12.3.0

SUITE="$ROOT/tests/presenter/render_docx"
TMP_ROOT=$(fm_test_tmproot fm-presenter-render-docx)

# The pinned install is this required lane's only network-dependent step, so a
# transient hosted-runner network hiccup must not red-flag CI: retry a bounded
# number of times, then fail loud with the final attempt's log. A genuinely
# broken pin never passes; it just fails on the last attempt instead of the
# first.
install_pinned_test_deps() {
  local venv_python="$1" log="$2" attempt
  for attempt in 1 2 3; do
    if PIP_DISABLE_PIP_VERSION_CHECK=1 "$venv_python" -m pip install --quiet \
      "pytest==$PYTEST_PIN" \
      "python-docx==$PYTHON_DOCX_PIN" \
      "pillow==$PILLOW_PIN" \
      >"$log" 2>&1; then
      return 0
    fi
  done
  return 1
}

test_python3_prerequisites_are_present() {
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to run the presenter render_docx suite"
  python3 -m venv --help >/dev/null 2>&1 \
    || fail "python3 venv module is required to build the ephemeral presenter test environment"
  pass "python3 and its venv module are available"
}

test_pytest_suite_passes_under_pinned_deps() {
  local venv_python="$TMP_ROOT/venv/bin/python"
  local out summary passed
  python3 -m venv "$TMP_ROOT/venv" >/dev/null 2>&1 \
    || fail "ephemeral venv creation failed"
  install_pinned_test_deps "$venv_python" "$TMP_ROOT/pip-install.log" \
    || fail "pinned pytest/python-docx/Pillow install failed after 3 attempts; see pip-install.log in the test temp root"
  out=$(PYTHONDONTWRITEBYTECODE=1 "$venv_python" -m pytest "$SUITE" -q 2>&1) \
    || { printf '%s\n' "$out"; fail "presenter render_docx pytest suite failed"; }
  summary=$(printf '%s\n' "$out" | tail -n 1)
  passed=${summary%% passed*}
  case $passed in
    ''|*[!0-9]*)
      printf '%s\n' "$out"
      fail "could not read a passed count from the pytest summary: $summary"
      ;;
  esac
  [ "$passed" -ge 1 ] || { printf '%s\n' "$out"; fail "pytest collected no presenter render_docx tests"; }
  printf '%s\n' "$summary"
  pass "presenter render_docx suite passes under pinned pytest ($passed tests)"
}

test_python3_prerequisites_are_present
test_pytest_suite_passes_under_pinned_deps
