#!/usr/bin/env bash
# fm-jev-dep-harmonizer.sh - Wrapper for Jev Dependency Version Drift Harmonizer (Pattern 25).
#
# Scans project manifests across repositories, tracks shared library versions,
# and emits version drift and harmonization telemetry.
#
# Usage:
#   fm-jev-dep-harmonizer.sh [--roots <dir1,dir2>] [--drift-only] [--json]
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
HARMONIZER_PY="$FM_ROOT/bin/fm-jev-dep-harmonizer.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-dep-harmonizer.sh" >&2
  exit 1
fi

if [ ! -f "$HARMONIZER_PY" ]; then
  echo "error: $HARMONIZER_PY not found" >&2
  exit 1
fi

exec python3 "$HARMONIZER_PY" "$@"
