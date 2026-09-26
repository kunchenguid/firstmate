#!/usr/bin/env bash
# Send the current bounded fleet snapshot to the configured Discord channel in quiet mode.
# Usage: fm-discord-report.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

if [ "$(fm_afk_mode "$STATE")" != quiet ]; then
  echo "fm-discord-report: available only while quiet mode is active" >&2
  exit 4
fi

fm_discord_load_config
channel_id=${FM_DISCORD_CHANNELS%%,*}
channel_id=$(fm_discord_trim "$channel_id")
case "$channel_id" in ''|*[!0-9]*) echo "fm-discord-report: configure FM_DISCORD_CHANNEL_ID or FM_DISCORD_ALLOWED_CHANNELS" >&2; exit 2 ;; esac

report=$("$SCRIPT_DIR/fm-bearings-snapshot.sh") || exit $?
[ -n "$report" ] || { echo "fm-discord-report: fleet snapshot is empty" >&2; exit 1; }
exec "$SCRIPT_DIR/fm-discord-notify.sh" --report "$channel_id" "$report"
