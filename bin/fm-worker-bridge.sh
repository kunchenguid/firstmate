#!/usr/bin/env bash
# Stable foreground identity for the Python bridge, including macOS Python.app
# launchers which replace argv[0]. See fm-worker-bridge.py --help for arguments.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec -a fm-worker-bridge bash -c 'python3 "$@"; exit "$?"' bridge "$SCRIPT_DIR/fm-worker-bridge.py" "$@"
