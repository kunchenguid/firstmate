#!/usr/bin/env bash
# tests/fm-bridge-console.test.sh - tests for the bridge terminal console
# (bin/fm-bridge-console.py, bin/fm_bridge_lib.py, bin/fm-bridge.sh).
#
# Fixture: tests/fixtures/fm-bridge-console/fm-bridge-snapshot.sample.json
# (read by both Python test files below, not by this shell wrapper directly).
#
# Two layers, because they prove different things:
#   1. tests/fm-bridge-console-lib.test.py - stdlib-only unittest over
#      formatting, thresholds, snapshot parsing, the quota-axi adapter, and
#      key-to-command mapping in bin/fm_bridge_lib.py. No Textual import
#      anywhere in that path, so it always runs, in any CI environment.
#   2. tests/fm-bridge-console-pilot.test.py - a Textual Pilot test driving
#      the real app headless against the fixture snapshot. It self-skips
#      (exit 0, "skip: textual not installed") when Textual is not
#      importable, so this suite never fails a CI lane with no Textual.
#      When `uv` is available, run it through `uv run --with textual` so it
#      exercises Textual the same way the real console does; otherwise fall
#      back to a plain interpreter, which still skips cleanly if Textual is
#      absent there too.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

LIB_TEST="$ROOT/tests/fm-bridge-console-lib.test.py"
PILOT_TEST="$ROOT/tests/fm-bridge-console-pilot.test.py"

if ! python3 "$LIB_TEST" 2>&1; then
  fail "fm-bridge-console-lib.test.py failed (see unittest output above)"
fi
pass "fm_bridge_lib.py: formatting, thresholds, snapshot parsing, and key mapping pass under plain python3"

UV_BIN=""
if command -v uv >/dev/null 2>&1; then
  UV_BIN="uv"
elif [ -x "$HOME/.local/bin/uv" ]; then
  UV_BIN="$HOME/.local/bin/uv"
fi

PILOT_OUT=""
if [ -n "$UV_BIN" ]; then
  PILOT_OUT=$("$UV_BIN" run --with textual python3 "$PILOT_TEST" 2>&1) || {
    printf '%s\n' "$PILOT_OUT" >&2
    fail "fm-bridge-console-pilot.test.py failed under uv run --with textual"
  }
else
  PILOT_OUT=$(python3 "$PILOT_TEST" 2>&1) || {
    printf '%s\n' "$PILOT_OUT" >&2
    fail "fm-bridge-console-pilot.test.py failed"
  }
fi
printf '%s\n' "$PILOT_OUT"
case "$PILOT_OUT" in
  skip:*) pass "Textual pilot test skipped cleanly (Textual not installed)" ;;
  *"ok - "*) pass "Textual pilot: main screen, peek modal, and timeline modal render against the fixture" ;;
  *) fail "Textual pilot test produced unexpected output: $PILOT_OUT" ;;
esac
