#!/usr/bin/env bash
# fm-claude-approval-hook.sh - Claude's approval-gate adapter for the semantic
# busy-state contract.
#
# Why this exists: Claude's busy source is hook-owned - UserPromptSubmit opens a
# turn and Stop closes it - so a turn that stops at Claude's own permission
# dialog fires no closing hook and the task keeps classifying `busy`. Firstmate
# then reads the worker as working and absorbs its quiet pane as provably-working
# until the wedge threshold, so a worker that needs one keystroke to continue is
# only surfaced minutes later, through a possible-wedge reason that does not name
# the gate. The turn genuinely IS open, so `busy` is not the wrong answer; what
# was missing is that the turn is parked at a gate nothing in firstmate's key
# plane can answer.
#
# Claude emits that gate as a structured Notification payload carrying
# notification_type=permission_prompt, which is a semantic source in exactly the
# sense bin/fm-busy-lib.sh requires: a machine-readable lifecycle event the
# harness itself publishes, never a reading of rendered pane text. This script is
# the adapter that turns it into one busy-contract event, and PostToolUse or
# PostToolUseFailure is the resume half: a tool that actually ran proves the gate
# was answered, whether or not the tool then succeeded.
#
# Usage: fm-claude-approval-hook.sh <state-dir> <id> --gen <gen>
#   The hook payload arrives as JSON on stdin. bin/fm-spawn.sh registers this
#   script for Notification, PostToolUse, and PostToolUseFailure with the same
#   gen it embeds in the task's other Claude hooks.
#
# Contract with the record owner: this script never writes the record itself.
# bin/fm-busy-event.sh stays its only writer and bin/fm-busy-lib.sh stays the
# only owner of the record format, the gen binding, and classification.
#
# Always exits 0 and prints nothing on stdout or stderr. A hook that failed
# loudly here would feed its own diagnostics back into the worker's turn, and a
# hook that cannot record the gate must leave the worker exactly as it was: the
# gate then simply stays invisible, which is the behavior that existed before
# this adapter.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh" 2>/dev/null || exit 0

STATE=${1:-}
ID=${2:-}
GEN=''
shift 2 2>/dev/null || exit 0
while [ $# -gt 0 ]; do
  case "$1" in
    --gen) GEN=${2:-}; shift 2 || exit 0 ;;
    *) shift ;;
  esac
done
[ -n "$STATE" ] && [ -n "$ID" ] && [ -n "$GEN" ] || exit 0

# Bounded read: a hook payload is a single small JSON object, and an adapter on
# the worker's own turn must never block on an unbounded stream.
PAYLOAD=$(head -c 65536 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

# Matched in-process rather than through grep: this runs on the worker's own
# turn after every tool call, so each avoided fork is latency the worker pays.
payload_has() {  # <extended-regex>
  local __re=$1
  [[ $PAYLOAD =~ $__re ]]
}

# Two independent positive signals, either of which carries the verdict, so no
# single vendor string is load-bearing: the typed notification_type field, and
# the human-readable message naming permission. Claude's other observed
# notification (notification_type=idle_prompt, message "Claude is waiting for
# your input") matches neither, which is what keeps an idle composer out of the
# approval gate.
notification_is_permission_gate() {
  payload_has '"notification_type"[[:space:]]*:[[:space:]]*"permission_prompt"' \
    || payload_has '"message"[[:space:]]*:[[:space:]]*"[^"]*[Pp]ermission'
}

apply() {  # <event>
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" busy \
    --gen "$GEN" --source claude-hook --event "$1" >/dev/null 2>&1 || true
}

if payload_has '"hook_event_name"[[:space:]]*:[[:space:]]*"Notification"'; then
  notification_is_permission_gate || exit 0
  apply "$FM_BUSY_APPROVAL_EVENT"
  exit 0
fi

if payload_has '"hook_event_name"[[:space:]]*:[[:space:]]*"PostToolUse(Failure)?"'; then
  # The resume half. A tool that ran is proof the gate was answered, and Claude
  # reports a failed tool through PostToolUseFailure instead of PostToolUse, so
  # both count: the outcome is irrelevant to the gate. This fires after EVERY
  # tool call, so it stays a cheap read that writes only while the record still
  # stands at the gate. Answering "no" runs no tool, so that path is closed by
  # the turn's own Stop instead.
  fm_busy_approval_wait "$STATE" "$ID" claude || exit 0
  apply approval-answered
fi

exit 0
