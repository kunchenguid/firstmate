#!/usr/bin/env bash
# Record Droid's SessionEnd as idle, and as a session-close marker for reason
# "other". Droid 0.230.0 sends "other" on /exit and Ctrl-C, but also when it
# closes a session and keeps running (after /clear, on a session reload, or for
# a Task subagent), so the marker is not proof of process exit by itself;
# fm_control_droid_session_ended also requires the process to be gone. Every
# other reason, including "clear", writes nothing.
set -u
set -o pipefail

[ "$#" -eq 3 ] || { echo 'usage: fm-droid-session-end-hook.sh <state-dir> <id> <gen>' >&2; exit 2; }
STATE=$1 ID=$2 GEN=$3
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

payload=$(cat)
"$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" idle \
  --gen "$GEN" --source droid-hook --event session-end >/dev/null 2>&1 || exit 0
jq -e '.reason == "other"' >/dev/null 2>&1 <<<"$payload" || exit 0
printf '%s\n' "$GEN" >"$STATE/$ID.droid-session-end"
