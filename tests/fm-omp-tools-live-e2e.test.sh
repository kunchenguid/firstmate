#!/usr/bin/env bash
# tests/fm-omp-tools-live-e2e.test.sh - opt-in proof gate for the candidate
# OMP adapter's empty tool and settings boundary.
set -u

if [ "${FM_OMP_TOOLS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_TOOLS_LIVE_E2E=1 to require the session-free OMP consumer proof"
  exit 0
fi

printf '%s\n' \
  "not ok - requested omp/17.2.9 has no supported session-free configuration and tool consumer; executable provenance, version, and effective behavior remain unproven; candidate remains dormant without resolving or executing OMP" >&2
exit 1
