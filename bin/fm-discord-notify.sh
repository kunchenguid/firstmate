#!/usr/bin/env bash
# Send one firstmate-initiated decision to the configured self-hosted Discord channel.
# Usage: fm-discord-notify.sh <captain-hold|ask-user|pr-ready> <task-id> <key> <summary> <option|option...> [status-task-id]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

retry_pending=0
if [ "${1:-}" = --retry-pending ]; then
  [ "$#" -eq 1 ] || { echo "usage: fm-discord-notify.sh --retry-pending" >&2; exit 2; }
  retry_pending=1
elif [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
  echo "usage: fm-discord-notify.sh <captain-hold|ask-user|pr-ready> <task-id> <key> <summary> <option|option...> [status-task-id]" >&2
  exit 2
fi
if [ "$retry_pending" -eq 0 ]; then
  trigger=$1 task_id=$2 decision_key=$3 summary=$4 options=$5
  status_task_id=${6:-$task_id}
fi
fm_discord_load_config
[ -n "${FM_DISCORD_TOKEN:-}" ] || exit 0
[ "$retry_pending" -eq 1 ] || [ -n "${FM_DISCORD_CHANNELS:-}" ] || exit 0
command -v node >/dev/null 2>&1 || { echo "fm-discord-notify: missing node for self-hosted Discord" >&2; exit 1; }

if [ "$retry_pending" -eq 1 ]; then
  export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DISCORD_BOT_TOKEN="$FM_DISCORD_TOKEN"
  exec node "$SCRIPT_DIR/fm-discord-notify.js" --retry-pending
fi

case "$task_id" in ''|.*|*[!A-Za-z0-9._-]*) echo "fm-discord-notify: invalid task id" >&2; exit 2 ;; esac
case "$decision_key" in ''|.*|*[!A-Za-z0-9._-]*) echo "fm-discord-notify: invalid decision key" >&2; exit 2 ;; esac
case "$trigger:$decision_key" in
  captain-hold:captain-hold-*) ;;
  ask-user:nm-*) ;;
  pr-ready:pr-ready-*) ;;
  *) echo "fm-discord-notify: trigger does not match its decision key" >&2; exit 2 ;;
esac
case "$summary" in *$'\n'*|*$'\r'*) echo "fm-discord-notify: summary must be one line" >&2; exit 2 ;; esac

channel_id=${FM_DISCORD_CHANNELS%%,*}
case "$channel_id" in ''|*[!0-9]*) echo "fm-discord-notify: configured channel id is invalid" >&2; exit 2 ;; esac
IFS='|' read -r -a option_list <<< "$options"
[ "${#option_list[@]}" -gt 0 ] || { echo "fm-discord-notify: at least one option is required" >&2; exit 2; }
for option in "${option_list[@]}"; do
  [ -n "$option" ] || { echo "fm-discord-notify: options must not be empty" >&2; exit 2; }
done

export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DISCORD_BOT_TOKEN="$FM_DISCORD_TOKEN"
exec node "$SCRIPT_DIR/fm-discord-notify.js" "$trigger" "$task_id" "$decision_key" \
  "$summary" "$channel_id" "$status_task_id" "${option_list[@]}"
