#!/usr/bin/env bash
# fm-bridge.sh - launch the bridge terminal console (bin/fm-bridge-console.py).
#
# Usage: fm-bridge.sh [console args...]
#   All arguments pass through to fm-bridge-console.py; see its --help.
#
# Requires uv (https://docs.astral.sh/uv/) on PATH, or at
# ~/.local/bin/uv (the default install location). uv resolves the
# console's PEP 723 inline script dependencies (Textual) into a throwaway
# environment, so no global `pip install` is needed. Refuses clearly and
# exits 1 when uv cannot be found, naming the install command, rather than
# falling back to a bare `python3` that would fail on a missing import.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UV_BIN=""
if command -v uv >/dev/null 2>&1; then
  UV_BIN="uv"
elif [ -x "$HOME/.local/bin/uv" ]; then
  UV_BIN="$HOME/.local/bin/uv"
fi

if [ -z "$UV_BIN" ]; then
  echo "error: uv not found (checked PATH and ~/.local/bin/uv)." >&2
  echo "install it with: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

exec "$UV_BIN" run "$SCRIPT_DIR/fm-bridge-console.py" "$@"
