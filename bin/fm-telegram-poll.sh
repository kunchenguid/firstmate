#!/usr/bin/env bash
# Trusted watcher check: emit one compact wake when signed Telegram inbox work exists.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
exec python3 "$SCRIPT_DIR/fm-telegram-bridge.py" poll --fm-home "$FM_HOME"
