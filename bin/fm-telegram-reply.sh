#!/usr/bin/env bash
# Send one idempotent, request-correlated private Telegram reply through Hermes.
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
exec python3 "$SCRIPT_DIR/fm-telegram-bridge.py" reply "${args[@]}" --fm-home "$FM_HOME"
