#!/usr/bin/env bash
# Supervised bridge from Socket Mode frames to the existing Slack wake contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-slack-lib.sh
. "$SCRIPT_DIR/fm-slack-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fms_load_config
fms_socket_configured || exit 2
command -v node >/dev/null 2>&1 || exit 2

FM_SLACK_APP_TOKEN="$FMS_APP_TOKEN" node "$SCRIPT_DIR/fm-slack-socket.mjs" | while IFS= read -r frame; do
  envelope_id=$(printf '%s\n' "$frame" | jq -r '.envelope_id // empty' 2>/dev/null) || exit 2
  event=$(printf '%s\n' "$frame" | jq -c '.event // empty' 2>/dev/null) || exit 2
  [ -n "$envelope_id" ] && [ -n "$event" ] || exit 2
  wake=$(printf '%s\n' "$event" \
    | FM_SLACK_APP_TOKEN="$FMS_APP_TOKEN" "$SCRIPT_DIR/fm-slack-socket-event.sh" "$envelope_id") || exit 2
  [ -n "$wake" ] || continue
  ts=$(printf '%s\n' "$event" | jq -r '.ts // .event_ts // empty' 2>/dev/null) || exit 2
  fm_wake_append check "slack-socket:$ts" "check: $SCRIPT_DIR/fm-slack-socket.sh: $wake" || exit 2
done
pipeline_status=("${PIPESTATUS[@]}")
[ "${pipeline_status[0]}" -eq 0 ] || exit "${pipeline_status[0]}"
exit "${pipeline_status[1]}"
