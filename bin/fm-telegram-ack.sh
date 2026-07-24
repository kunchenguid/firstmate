#!/usr/bin/env bash
# Mark a correlated Telegram inbox request processed after its reply/link succeeds.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
exec python3 "$SCRIPT_DIR/fm-telegram-bridge.py" ack "$@" --fm-home "$FM_HOME"
