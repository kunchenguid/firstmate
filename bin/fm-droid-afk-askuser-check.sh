#!/usr/bin/env bash
# Droid AskUser PreToolUse guard for away mode.
# Exit 2 with a Droid deny object while away; otherwise exit 0 without output.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# shellcheck source=bin/fm-primary-scope-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ -e "$STATE/.afk" ] || exit 0

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"This AskUser call is denied, not answered. Do not retry it or ask the captain in plain text while away mode is active. Record the decision with bin/fm-captain-hold.sh hold, creating a new held task if needed, and continue other independently authorized work. Away mode grants no additional approval, merge, destructive, irreversible, or security authority."}' >&2
exit 2
