#!/usr/bin/env bash
# fm-dialog-hooks.sh - the call point of the prompt-submit and stop lifecycle
# hook events: the primary session's own dialog, handed to installed hooks
# (docs/configuration.md "Lifecycle hooks").
#
# Claude runs it from the tracked .claude/settings.json UserPromptSubmit and
# Stop registrations, beside bin/fm-host-mirror.sh and independent of it, with
# the harness hook payload on stdin. docs/configuration.md "Lifecycle hooks"
# owns the event payloads and missing-field defaults.
# The text is passed as said, byte for byte.
#
# Non-blocking by construction: the hooks run through bin/fm-hooks.sh (both
# events are non-blocking there), their stdout is discarded so nothing reaches
# the model's context, their failures go to state/.fm-hooks.log, and this
# script always exits 0 and prints nothing, so a hook can never hold, block,
# or change a prompt or a stop. Each hook is still bounded by FM_HOOK_TIMEOUT.
#
# A silent no-op that reads nothing when neither hooks/prompt-submit.d nor
# hooks/stop.d exists (bin/fm-hooks-lib.sh owns where they live): one
# directory test each, so with no hooks installed a prompt or stop costs only
# that. It also does nothing for a Cursor payload (Cursor loads the tracked
# Claude settings too and has no call point here), without jq, for any other
# hook event, and outside a genuine primary checkout (fm-primary-scope-lib.sh),
# so a crewmate worktree never emits the dialog.
#
# Usage: fm-dialog-hooks.sh claude    a UserPromptSubmit or Stop payload on stdin
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in
  -h | --help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
  claude) [ "$#" -eq 1 ] || exit 0 ;;
  *) exit 0 ;;
esac

# shellcheck source=bin/fm-hooks-lib.sh
. "$SCRIPT_DIR/fm-hooks-lib.sh"
fm_hooks_present prompt-submit || fm_hooks_present stop || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then empty
  elif .hook_event_name == "UserPromptSubmit" then "prompt-submit"
  elif .hook_event_name == "Stop" then "stop"
  else empty end' 2>/dev/null) || exit 0
[ -n "$EVENT" ] || exit 0
fm_hooks_present "$EVENT" || exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# shellcheck disable=SC2016 # A jq program: $names are jq variables.
EVENT_PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -c --arg event "$EVENT" --arg harness "$1" --arg home "$FM_HOME" '
  {session_id: (.session_id // null), prompt_id: (.prompt_id // .generation_id // null)}
  + if $event == "prompt-submit" then {prompt: (.prompt // null)}
    else {last_assistant_message: (.last_assistant_message // null),
          stop_hook_active: (.stop_hook_active == true), transcript_path: (.transcript_path // null)} end
  + {harness: $harness, home: $home}' 2>/dev/null) || exit 0

LOG=/dev/null
[ ! -d "$STATE" ] || LOG="$STATE/.fm-hooks.log"
fm_hooks_emit_json "$EVENT" "$EVENT_PAYLOAD" </dev/null >/dev/null 2>>"$LOG" || true
exit 0
