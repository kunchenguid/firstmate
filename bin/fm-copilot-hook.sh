#!/usr/bin/env bash
# Copilot CLI repository-hook adapter for Firstmate primary sessions.
# Usage: fm-copilot-hook.sh session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop|notification
#
# The shared scripts remain authoritative.
# This file translates only Copilot's native hook output objects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}

copilot_hook_root() {
  pwd -P 2>/dev/null
}

copilot_hook_home() {
  local root=${1:-}
  printf '%s\n' "${FM_HOME:-$root}"
}

copilot_hook_state() {
  local root=${1:-} home
  home=$(copilot_hook_home "$root")
  printf '%s\n' "${FM_STATE_OVERRIDE:-$home/state}"
}

copilot_notification_has_watcher_completion() {
  local payload=${1:-} root home policy command verdict
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e '.notification_type == "shell_completed"' >/dev/null 2>&1 || return 1
  command -v node >/dev/null 2>&1 || return 1
  root=$(copilot_hook_root) || return 1
  home=$(copilot_hook_home "$root")
  policy="$SCRIPT_DIR/fm-arm-command-policy.mjs"
  [ -f "$policy" ] || return 1
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    verdict=$(node "$policy" watcher-arm --root "$root" --home "$home" --command "$command" 2>/dev/null || true)
    [ "$verdict" = watch-arm ] && return 0
  done <<EOF
$(printf '%s' "$payload" | jq -r '
  [
    .command,
    .commandLine,
    .command_line,
    .toolArgs.command,
    .toolInput.command,
    .tool_input.command,
    .task.command,
    .task.commandLine,
    .task.command_line,
    .data.command,
    .data.commandLine,
    .data.command_line
  ]
  | map(select(type == "string" and length > 0))
  | unique
  | .[]
' 2>/dev/null)
EOF
  return 1
}

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
[ "$(fm_hook_actual_host)" = copilot ] || exit 0

case "$MODE" in
  session-start)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    OUT=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-session-start.XXXXXX") || exit 0
    trap 'rm -f "$OUT"' EXIT HUP INT TERM
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-sessionstart-run.sh" --copilot > "$OUT" 2>/dev/null || true
    [ -s "$OUT" ] || exit 0
    jq -Rs '{additionalContext:.}' < "$OUT"
    ;;
  pretool-arm)
    exec "$SCRIPT_DIR/fm-arm-pretool-check.sh" --copilot
    ;;
  pretool-cd)
    exec "$SCRIPT_DIR/fm-cd-pretool-check.sh" --copilot
    ;;
  pretool-subagent)
    exec "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --copilot
    ;;
  agent-stop)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    REASON_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-agent-stop.XXXXXX") || exit 0
    trap 'rm -f "$REASON_FILE"' EXIT HUP INT TERM
    if printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --copilot >/dev/null 2>"$REASON_FILE"; then
      exit 0
    else
      STATUS=$?
    fi
    [ "$STATUS" -eq 2 ] || exit 0
    REASON=$(cat "$REASON_FILE" 2>/dev/null || true)
    [ -n "$REASON" ] || REASON='Restore Firstmate supervision before ending this turn.'
    jq -cn --arg reason "$REASON" '{decision:"block",reason:$reason}'
    ;;
  notification)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    copilot_notification_has_watcher_completion "$PAYLOAD" || exit 0
    ROOT=$(copilot_hook_root) || exit 0
    STATE=$(copilot_hook_state "$ROOT")
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$ROOT" "$STATE" || exit 0
    # shellcheck source=bin/fm-operational-input.sh
    . "$SCRIPT_DIR/fm-operational-input.sh"
    BODY='FIRSTMATE WATCHER WAKE: shell_completed: bin/fm-watch-arm.sh

Run bin/fm-wake-drain.sh first and handle the queued wake or watcher failure. Start the next attached asynchronous arm only if supervision remains required.'
    fm_operational_input_encode watcher "$BODY" FOLLOWUP || exit 0
    jq -cn --arg text "$FOLLOWUP" '{additionalContext:$text}'
    ;;
  *)
    echo "usage: $(basename "$0") session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop|notification" >&2
    exit 2
    ;;
esac
