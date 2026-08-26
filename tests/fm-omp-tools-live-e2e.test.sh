#!/usr/bin/env bash
# tests/fm-omp-tools-live-e2e.test.sh - opt-in proof gate for the candidate
# OMP adapter's empty tool and settings boundary.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

if [ "${FM_OMP_TOOLS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_TOOLS_LIVE_E2E=1 to require the session-free OMP consumer proof"
  exit 0
fi

OMP_BIN=$(command -v omp 2>/dev/null || true)
if [ -z "$OMP_BIN" ] || [ ! -x "$OMP_BIN" ]; then
  echo "not ok - exact omp/17.2.9 executable is unavailable" >&2
  exit 1
fi

if ! OMP_VERSION=$(fm_run_timed 5 "$OMP_BIN" --version 2>/dev/null); then
  echo "not ok - bounded omp --version probe failed" >&2
  exit 1
fi
if [ "$OMP_VERSION" != "omp/17.2.9" ]; then
  printf "not ok - expected exact omp/17.2.9, got '%s'\n" "${OMP_VERSION:-<none>}" >&2
  exit 1
fi

printf '%s\n' \
  "not ok - exact omp/17.2.9 has no available importable session-free configuration and tool consumer; candidate remains dormant" >&2
exit 1
