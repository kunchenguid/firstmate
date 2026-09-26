#!/usr/bin/env bash
# Regression for the live foreign session-lock owner and non-owner Stop loop.
# The executable reproduction runs the real auto-arm and turn-end guard paths.
set -eu

# Isolate from the ambient fleet environment before anything else runs. This
# suite does not source tests/lib.sh - it delegates to a Python reproduction -
# so it calls the shared owner directly. bin/fm-test-env-lib.sh owns the
# pointer list; this is a caller, never a second copy of it.
# shellcheck source=bin/fm-test-env-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-test-env-lib.sh"
fm_test_env_isolate || exit 2

python3 "$(dirname "${BASH_SOURCE[0]}")/fm-turnend-foreign-owner-repro.py"
