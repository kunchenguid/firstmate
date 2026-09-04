#!/usr/bin/env bash
# Route one ready SQLite burst, or surface a captured exception burst.
# Usage: board-answers-handle.sh route [--config PATH]
#        board-answers-handle.sh capture <source-id> <sequence> <result-file>
# The Python helper owns idempotency, literal argv, and exception framing.
# FM_BOARD_PYTHON selects an absolute Python 3.14 executable; otherwise resolve
# python3 from PATH. Never silently fall back to the macOS system Python 3.9.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) printf 'usage: board-answers-handle.sh route [--config PATH] | capture <source> <seq> <result>\n'; exit 0 ;;
esac
PYTHON="${FM_BOARD_PYTHON:-$(command -v python3 || true)}"
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] || { printf 'board-answers: Python 3.14 is required\n' >&2; exit 1; }
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3,14) else 1)' || {
  printf 'board-answers: Python 3.14 or newer is required\n' >&2; exit 1;
}
exec "$PYTHON" "$SCRIPT_DIR/board-answers-handle.py" "$@"
