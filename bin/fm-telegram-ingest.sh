#!/usr/bin/env bash
# Accept one HMAC-signed Hermes Telegram envelope on stdin.
# Refuses intake unless this Firstmate home has live supervision.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_TELEGRAM_WATCHER_GRACE:-90}" "$FM_HOME"; then
  echo "fm-telegram-ingest: Firstmate supervision is offline; request not accepted" >&2
  exit 4
fi

exec python3 "$SCRIPT_DIR/fm-telegram-bridge.py" ingest --fm-home "$FM_HOME"
