#!/usr/bin/env bash
# Captain dashboard CLI. bin/fm-board.py owns config, routes, and runtime schema.
# Usage: fm-board.sh <serve|ingest|decision|live|answered|refresh|arm-answers|backup> [--help]
# FM_BOARD_PYTHON selects an absolute Python 3.14 executable; otherwise resolve
# python3 from PATH. Never silently fall back to the macOS system Python 3.9.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${FM_BOARD_PYTHON:-$(command -v python3 || true)}"
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] || { printf 'fm-board: Python 3.14 is required\n' >&2; exit 1; }
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3,14) else 1)' || {
  printf 'fm-board: Python 3.14 or newer is required\n' >&2; exit 1;
}
exec "$PYTHON" "$SCRIPT_DIR/fm-board.py" "$@"
