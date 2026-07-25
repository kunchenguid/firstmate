#!/usr/bin/env bash
# Phase 2 registry CLI wrapper.
# Usage: fm-phase2-registry.sh <registry.py args...>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
exec python3 "$FM_HOME/phase2/lib/registry.py" --home "$FM_HOME" "$@"
