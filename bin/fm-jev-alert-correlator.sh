#!/usr/bin/env bash
# fm-jev-alert-correlator.sh - Shell wrapper for Jev Semantic Alert Correlator.
#
# Correlates alerts and check outputs against active holds and known quiet windows.
# Exits 0 to absorb/suppress duplicate alert, 2 to escalate as genuine outage.
#
# Usage:
#   fm-jev-alert-correlator.sh --alert "<text>" [--source <name>] [--json]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

CORRELATOR_PY="$FM_ROOT/bin/fm-jev-alert-correlator.py"

if [ ! -x "$CORRELATOR_PY" ]; then
  # Fail-open: escalate if engine missing
  exit 2
fi

exec python3 "$CORRELATOR_PY" "$@"
