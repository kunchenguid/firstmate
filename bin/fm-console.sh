#!/usr/bin/env bash
# Start the local Firstmate operator console.
#
# Usage: fm-console.sh [--home <firstmate-home>] [--port <port>]
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
exec python3 "$SCRIPT_DIR/fm-console.py" --root "$FM_ROOT" "$@"
