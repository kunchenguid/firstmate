#!/usr/bin/env bash
# Copilot CLI repository-hook adapter for Firstmate primary sessions.
# Usage: fm-copilot-hook.sh session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop|notification
#
# The shared scripts remain authoritative.
# This file translates only Copilot's native hook output objects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-copilot-watcher-receipt-lib.sh
. "$SCRIPT_DIR/fm-copilot-watcher-receipt-lib.sh"
MODE=${1:-}

copilot_hook_real_dir() {
  local dir=${1:-}
  [ -n "$dir" ] || return 1
  CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P
}

copilot_hook_root() {
  pwd -P 2>/dev/null
}

copilot_hook_home() {
  local root=${1:-} home
  home=${FM_HOME:-$root}
  copilot_hook_real_dir "$home" || printf '%s\n' "$home"
}

copilot_hook_state() {
  local root=${1:-} state
  state=${FM_STATE_OVERRIDE:-$(copilot_hook_home "$root")/state}
  copilot_hook_real_dir "$state" || printf '%s\n' "$state"
}

copilot_notification_has_named_watcher_completion() {
  local payload=${1:-} title message
  [ -n "$payload" ] || return 1
  title=$(printf '%s' "$payload" | jq -r '.title // empty' 2>/dev/null) || return 1
  case "$title" in
    'Arm Firstmate watcher'|'Arm the Firstmate watcher') ;;
    *) return 1 ;;
  esac
  message=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null) || return 1
  printf '%s\n' "$message" | grep -Fq "Shell command \"$title\" (shellId: " || return 1
  printf '%s\n' "$message" | grep -Eq '^Shell command "Arm( the)? Firstmate watcher" \(shellId: [0-9]+\) has completed successfully\. Use read_bash with shellId "[0-9]+" to retrieve the output\.$'
}

copilot_notification_receipt_missing() {
  local state=${1:-} state_real receipt dir
  [ -n "$state" ] || return 1
  state_real=$(fm_copilot_watch_receipt_real_dir "$state") || return 1
  receipt=$(fm_copilot_watch_receipt_path "$state_real") || return 1
  dir=${receipt%/*}
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(fm_copilot_watch_receipt_mode "$dir")" = 700 ] || return 1
  fi
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
}

copilot_notification_has_explicit_failure() {
  local payload=${1:-}
  [ -n "$payload" ] || return 1
  printf '%s' "$payload" | jq -e '
    def sources: [., .data?, .task?, .result?, .toolResult?];
    any(sources[]?;
      (.success? == false)
      or (((.exitCode? // .exit_code? // .exitStatus? // .exit_status?) as $code
           | ($code | type) == "number" and $code != 0))
      or (((.status? // empty) as $status
           | ($status | type) == "string"
             and ($status | ascii_downcase | test("^(fail(ed|ure)?|error)$"))))
    )
  ' >/dev/null 2>&1
}

copilot_notification_has_success_evidence() {
  local payload=${1:-}
  [ -n "$payload" ] || return 1
  copilot_notification_has_named_watcher_completion "$payload" && return 0
  printf '%s' "$payload" | jq -e '
    def sources: [., .data?, .task?, .result?, .toolResult?];
    any(sources[]?;
      (.success? == true)
      or (((.exitCode? // .exit_code? // .exitStatus? // .exit_status?) as $code
           | ($code | type) == "number" and $code == 0))
      or (((.status? // empty) as $status
           | ($status | type) == "string"
             and ($status | ascii_downcase) == "success"))
    )
  ' >/dev/null 2>&1
}

copilot_notification_has_watcher_completion() {
  local payload=${1:-} root=${2:-} home=${3:-} state=${4:-}
  local policy command verdict saw_command=0 can_classify=0
  [ -n "$payload" ] || return 1
  [ -n "$root" ] && [ -n "$home" ] && [ -n "$state" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e '.notification_type == "shell_completed"' >/dev/null 2>&1 || return 1
  policy="$SCRIPT_DIR/fm-arm-command-policy.mjs"
  if command -v node >/dev/null 2>&1 && [ -f "$policy" ]; then
    can_classify=1
  fi
  while IFS= read -r -d '' command; do
    [ -n "$command" ] || continue
    saw_command=1
    [ "$can_classify" -eq 1 ] || continue
    verdict=$(node "$policy" watcher-arm --root "$root" --home "$home" --command "$command" 2>/dev/null || true)
    if [ "$verdict" = watch-arm ]; then
      if fm_copilot_watch_receipt_claim "$root" "$home" "$state" >/dev/null 2>&1; then
        return 0
      fi
      copilot_notification_receipt_missing "$state" || return 1
      copilot_notification_has_explicit_failure "$payload" && return 1
      copilot_notification_has_success_evidence "$payload" || return 1
      return 0
    fi
  done < <(printf '%s' "$payload" | jq -j '
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
  | unique[]
  | ., "\u0000"
' 2>/dev/null)
  [ "$saw_command" -eq 0 ] || return 1
  copilot_notification_has_named_watcher_completion "$payload" || return 1
  fm_copilot_watch_receipt_claim "$root" "$home" "$state"
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
    ROOT=$(copilot_hook_root) || exit 0
    HOME=$(copilot_hook_home "$ROOT")
    STATE=$(copilot_hook_state "$ROOT")
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$ROOT" "$STATE" || exit 0
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
    ROOT=$(copilot_hook_root) || exit 0
    HOME=$(copilot_hook_home "$ROOT")
    STATE=$(copilot_hook_state "$ROOT")
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$ROOT" "$STATE" || exit 0
    copilot_notification_has_watcher_completion "$PAYLOAD" "$ROOT" "$HOME" "$STATE" || exit 0
    # shellcheck source=bin/fm-operational-input.sh
    . "$SCRIPT_DIR/fm-operational-input.sh"
    BODY='FIRSTMATE WATCHER WAKE: shell_completed: bin/fm-watch-arm.sh

Inspect the completed task result for the reason line when needed. Run bin/fm-wake-drain.sh first, handle every emitted wake, reconcile open decisions and unread status lines, then run the exact WAKE_ACK_REQUIRED --ack-through command printed by the drain. Until that post-handling acknowledgement, interruption leaves the work durable for idempotent re-handling. Start the next attached asynchronous arm only if supervision remains required.'
    fm_operational_input_encode watcher "$BODY" FOLLOWUP || exit 0
    jq -cn --arg text "$FOLLOWUP" '{additionalContext:$text}'
    ;;
  *)
    echo "usage: $(basename "$0") session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop|notification" >&2
    exit 2
    ;;
esac
