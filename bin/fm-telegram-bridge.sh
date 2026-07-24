#!/usr/bin/env bash
# Install, configure, start, stop, inspect, or uninstall the Hermes Telegram bridge.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-telegram-bridge.py" "$@"
