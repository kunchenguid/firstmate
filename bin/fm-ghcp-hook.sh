#!/usr/bin/env bash
# GitHub Copilot CLI hook transport for primary and worker sessions.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${COPILOT_CLI:-}" = 1 ] || exit 0

case "${1:-}" in
  session-start)
    PAYLOAD=$(cat 2>/dev/null || true)
    DIGEST=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-sessionstart-run.sh" 2>/dev/null || true)
    [ -n "$DIGEST" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    jq -n --arg c "$DIGEST" '{additionalContext:$c}' 2>/dev/null || true
    ;;
  primary-stop)
    exec "$SCRIPT_DIR/fm-copilot-stop.sh"
    ;;
  notification)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    TYPE=$(printf '%s' "$PAYLOAD" | jq -r '
      if type == "object" and (.notification_type | type) == "string" then .notification_type
      else error("notification_type")
      end
    ' 2>/dev/null) || exit 0
    case "$TYPE" in shell_completed|shell_detached_completed) ;; *) exit 0 ;; esac

    FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
    FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
    STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
    GRACE=${FM_GUARD_GRACE:-300}
    # shellcheck source=bin/fm-operational-input.sh
    . "$SCRIPT_DIR/fm-operational-input.sh"
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$SCRIPT_DIR/fm-session-lock-lib.sh"
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$SCRIPT_DIR/fm-supervision-lib.sh"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"

    fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
    fm_session_lock_owned_by_self "$STATE" || exit 0
    [ -e "$STATE/.afk" ] && exit 0
    fm_supervision_status "$STATE" "$GRACE"
    [ "$FM_SUP_NEEDED" = true ] || exit 0
    fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME" && exit 0

    if [ "$FM_SUP_QUEUE_PENDING" = true ]; then
      BODY='A tracked asynchronous watcher task completed and durable supervision input is waiting. Run bin/fm-wake-drain.sh first, handle every presented event, and run its exact WAKE_ACK_REQUIRED command. If supervision is still needed afterward, start the next watcher as one native asynchronous shell task.'
      KIND=watcher
    else
      BODY='A tracked asynchronous watcher task completed without leaving a healthy watcher or a queued event. Inspect the completed shell task output. If supervision is still needed, start bin/fm-watch-arm.sh again as one native asynchronous shell task; on Windows use ./bin/fm-watch-arm.ps1. Never use a shell ampersand.'
      KIND=turn-end-guard
    fi
    fm_operational_input_encode "$KIND" "$BODY" CONTEXT || exit 0
    jq -n --arg c "$CONTEXT" '{additionalContext:$c}' 2>/dev/null || true
    ;;
  pretool)
    case "${2:-}" in
      arm) exec "$SCRIPT_DIR/fm-arm-pretool-check.sh" --copilot ;;
      cd) exec "$SCRIPT_DIR/fm-cd-pretool-check.sh" --copilot ;;
      subagent) exec "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --copilot ;;
      *) exit 0 ;;
    esac
    ;;
  worker-event)
    [ "$#" -eq 7 ] || exit 0
    STATE=$2
    ID=$3
    GEN=$4
    VERDICT=$5
    EVENT=$6
    TURNEND=$7
    case "$VERDICT" in busy|idle) ;; *) exit 0 ;; esac
    case "$ID:$GEN:$EVENT" in
      *[!A-Za-z0-9._:-]*) exit 0 ;;
    esac
    if "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" "$VERDICT" \
      --gen "$GEN" --source copilot-hook --event "$EVENT" >/dev/null 2>&1; then
      if [ "$TURNEND" != "-" ]; then
        touch "$TURNEND" 2>/dev/null || true
      fi
      if [ "$EVENT" = user-prompt-submitted ]; then
        ACK="$STATE/$ID.copilot-prompt-submitted"
        ACK_TMP="$ACK.tmp.$$"
        if printf '%s:%s:%s\n' "$GEN" "$$" "${RANDOM:-0}" > "$ACK_TMP" 2>/dev/null; then
          mv -f "$ACK_TMP" "$ACK" 2>/dev/null || rm -f "$ACK_TMP"
        fi
      fi
    fi
    ;;
  *)
    exit 0
    ;;
esac
exit 0
