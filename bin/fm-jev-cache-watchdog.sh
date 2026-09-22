#!/usr/bin/env bash
# fm-jev-cache-watchdog.sh - Jev Model Context & Prompt Cache Degradation Watchdog (Pattern 22)
#
# Shell wrapper for bin/fm-jev-cache-watchdog.py.
# Inspects prompt cache hit rates and context limits across active fleet agent sessions.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PYTHON_BIN="python3"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "warning: python3 not available; skipping Jev cache watchdog" >&2
  exit 0
fi

ENGINE="$SCRIPT_DIR/fm-jev-cache-watchdog.py"
if [ ! -f "$ENGINE" ]; then
  echo "warning: $ENGINE not found; skipping Jev cache watchdog" >&2
  exit 0
fi

exec "$PYTHON_BIN" "$ENGINE" "$@"
