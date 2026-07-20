#!/usr/bin/env bash
# Thin launcher for the durable session-memory owner.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-memory.js" "$@"
