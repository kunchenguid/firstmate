#!/usr/bin/env bash
# Record Droid's submitted prompt digest with its semantic busy event.
# Factory supplies the UserPromptSubmit JSON on stdin; only a SHA-256 digest
# is persisted, and a missing or malformed payload still opens the busy turn.
set -u
set -o pipefail

[ "$#" -eq 3 ] || { echo 'usage: fm-droid-prompt-hook.sh <state-dir> <id> <gen>' >&2; exit 2; }
STATE=$1 ID=$2 GEN=$3
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

if digest=$(jq -erj 'select(.hook_event_name == "UserPromptSubmit") | .prompt | select(type == "string")' \
    | fm_busy_prompt_sha256); then
  exec "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" busy \
    --gen "$GEN" --source droid-hook --event user-prompt-submit --prompt-sha256 "$digest"
fi
exec "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" busy \
  --gen "$GEN" --source droid-hook --event user-prompt-submit
