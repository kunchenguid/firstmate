#!/usr/bin/env bash
# Behavioral tests for bin/fm-bot-manager-poll.py.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/fm-bot-manager-poll.test.py"
