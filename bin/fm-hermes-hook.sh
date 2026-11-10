#!/usr/bin/env bash
# Hermes native shell-hook receiver: <state-dir> <task-id> <busy-gen> <busy|idle>.
# Reads native JSON on stdin. Accept only the native tui platform (subagent
# and gateway hooks are ignored). Bind the native turn id so compression may
# rotate the session id without losing the end notification. Busy
# events and turn-ended notifications use the shared generation-bound writer.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${1:?state required}
ID=${2:?task id required}
GEN=${3:?generation required}
VERDICT=${4:?verdict required}
case "$ID:$GEN" in *[!A-Za-z0-9._:-]*) exit 1 ;; esac
case "$VERDICT" in busy|idle) ;; *) exit 1 ;; esac
PAYLOAD=$(cat)
[ "$(printf '%s' "$PAYLOAD" | jq -r '.extra.platform // ""')" = tui ] || exit 0
SESSION=$(printf '%s' "$PAYLOAD" | jq -er '.extra.turn_id | select(type == "string" and test("^[A-Za-z0-9_:-]+$"))') || exit 1
BINDING="$STATE/$ID.hermes-hooks/$GEN.session"
if [ "$VERDICT" = busy ]; then
  (umask 077; printf '%s\n' "$SESSION" > "$BINDING.tmp" && mv "$BINDING.tmp" "$BINDING")
fi
[ -f "$BINDING" ] || exit 0
[ "$(cat "$BINDING")" = "$SESSION" ] || exit 0
args=()
[ "$VERDICT" != idle ] || args=(--turn-ended)
"$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" "$VERDICT" --gen "$GEN" --source hermes-hook --event "$VERDICT" "${args[@]}" >/dev/null
