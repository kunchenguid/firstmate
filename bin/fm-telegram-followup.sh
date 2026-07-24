#!/usr/bin/env bash
# Check or post a bounded task milestone/final reply to its Telegram origin.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

args=()
for arg in "$@"; do
  if [ "$arg" = - ]; then
    args+=(--stdin)
  else
    args+=("$arg")
  fi
done
exec python3 "$SCRIPT_DIR/fm-telegram-bridge.py" followup "${args[@]}" --fm-home "$FM_HOME"
