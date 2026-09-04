#!/usr/bin/env bash
# Route one ready SQLite burst, or surface a captured exception burst.
# Usage: board-answers-handle.sh route [--config PATH]
#        board-answers-handle.sh capture <source-id> <sequence> <result-file>
# The Python helper owns idempotency, literal argv, and exception framing.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) printf 'usage: board-answers-handle.sh route [--config PATH] | capture <source> <seq> <result>\n'; exit 0 ;;
esac
exec "${FM_BOARD_PYTHON:-python3}" "$SCRIPT_DIR/board-answers-handle.py" "$@"
