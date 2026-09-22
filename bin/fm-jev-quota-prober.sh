#!/usr/bin/env bash
# fm-jev-quota-prober.sh - Shell wrapper for Jev Pattern 9 Pre-Flight Quota Prober.
#
# Usage:
#   bin/fm-jev-quota-prober.sh --harness <harness> [--model <model>] [--auto-divert] [--json]
#   bin/fm-jev-quota-prober.sh --check-all [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PYTHON_EXEC="${FM_PYTHON:-python3}"

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-quota-prober.py" "$@"

