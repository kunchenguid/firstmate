#!/usr/bin/env bash
# fm-jev-privacy-guard.sh - Shell wrapper for Jev Inline Privacy & PII Guardrail.
#
# Inspects files, diffs, or text for personal tax, W-2/1099, SSN, and banking PII.
# Exits 0 if clean/allowed, 1 if quarantined/denied.
#
# Usage:
#   fm-jev-privacy-guard.sh [--file <path>] [--text <str>] [--quarantine] [--quarantine-dir <dir>] [--json]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

GUARD_PY="$FM_ROOT/bin/fm-jev-privacy-guard.py"

if [ ! -x "$GUARD_PY" ]; then
  # Fail-open: allow if guard engine missing
  exit 0
fi

exec python3 "$GUARD_PY" "$@"
