#!/usr/bin/env bash
# fm-route-domain.sh - classify and route incoming task or brief to a secondmate domain using Jev System One.
#
# Usage:
#   fm-route-domain.sh --task "<description>"
#   fm-route-domain.sh --brief <path-to-brief>
#   fm-route-domain.sh --json ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

exec python3 "$SCRIPT_DIR/fm-route-domain.py" "$@"
