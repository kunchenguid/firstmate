#!/usr/bin/env bash
# Track pending decisions sent via Telegram inline keyboards, manage timeouts,
# and clean up stale decision state.
#
# When firstmate sends a decision message with inline keyboard buttons to the
# captain via Telegram, it records the decision here so it can track outcomes,
# time out stale decisions, and clean up the message's keyboard after a decision
# is made (or timeout).
#
# Usage:
#   fm-tg-decision.sh record <task-id> <chat_id> <message_id> [--timeout <secs>]
#     Record a pending decision for a task. Default timeout 86400s (24h).
#
#   fm-tg-decision.sh resolve <task-id> <action>
#     Resolve a pending decision (action is merge, skip, approve, decline).
#     Edits the Telegram message to remove keyboard and show outcome.
#
#   fm-tg-decision.sh timeout [--max-age <secs>]
#     Scan all pending decisions, time out any past their expiry.
#     Edits timed-out messages to show "Decision timed out" and removes keyboard.
#
#   fm-tg-decision.sh list
#     List all pending decisions.
#
#   fm-tg-decision.sh clear <task-id>
#     Clear a decision record without editing the Telegram message.
#
# Decision state is stored in state/tg-decisions/<task-id>.json:
#   {task_id, chat_id, message_id, expiry_epoch, created_epoch, action_ts}
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DECISIONS_DIR="$STATE/tg-decisions"

# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

usage() {
  echo "usage: fm-tg-decision.sh record <task-id> <chat_id> <message_id> [--timeout <secs>]" >&2
  echo "       fm-tg-decision.sh resolve <task-id> <action>" >&2
  echo "       fm-tg-decision.sh timeout [--max-age <secs>]" >&2
  echo "       fm-tg-decision.sh list" >&2
  echo "       fm-tg-decision.sh clear <task-id>" >&2
}

command -v jq >/dev/null 2>&1 || { echo "fm-tg-decision: jq not found" >&2; exit 1; }

safe_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift

case "$cmd" in
  record)
    TASK_ID=${1:-}
    CHAT_ID=${2:-}
    MSG_ID=${3:-}
    if [ -z "$TASK_ID" ] || [ -z "$CHAT_ID" ] || [ -z "$MSG_ID" ]; then usage; exit 2; fi
    shift 3

    safe_id "$TASK_ID" || { echo "fm-tg-decision: unsafe task id: $TASK_ID" >&2; exit 2; }
    case "$CHAT_ID" in ''|*[!0-9]*) echo "fm-tg-decision: unsafe chat_id: $CHAT_ID" >&2; exit 2 ;; esac
    case "$MSG_ID" in ''|*[!0-9]*) echo "fm-tg-decision: unsafe message_id: $MSG_ID" >&2; exit 2 ;; esac

    TIMEOUT=86400
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --timeout)
          shift
          TIMEOUT=${1:-86400}
          case "$TIMEOUT" in ''|*[!0-9]*) echo "fm-tg-decision: --timeout needs a positive integer" >&2; exit 2 ;; esac
          ;;
        *) usage; exit 2 ;;
      esac
      shift
    done

    NOW=$(date +%s)
    EXPIRY=$((NOW + TIMEOUT))

    mkdir -p "$DECISIONS_DIR" 2>/dev/null || { echo "fm-tg-decision: cannot create decisions directory" >&2; exit 1; }
    jq -cn --arg task_id "$TASK_ID" --arg chat_id "$CHAT_ID" --arg msg_id "$MSG_ID" \
      --argjson expiry "$EXPIRY" --argjson created "$NOW" \
      '{task_id:$task_id,chat_id:$chat_id,message_id:$msg_id,expiry_epoch:$expiry,created_epoch:$created,resolved:false}' \
      > "$DECISIONS_DIR/$TASK_ID.json" 2>/dev/null || {
      echo "fm-tg-decision: cannot write decision record" >&2
      exit 1
    }
    printf 'recorded decision for %s in chat %s msg %s (expires %s)\n' "$TASK_ID" "$CHAT_ID" "$MSG_ID" "$EXPIRY"
    ;;

  resolve)
    TASK_ID=${1:-}
    ACTION=${2:-}
    if [ -z "$TASK_ID" ] || [ -z "$ACTION" ]; then usage; exit 2; fi

    safe_id "$TASK_ID" || { echo "fm-tg-decision: unsafe task id: $TASK_ID" >&2; exit 2; }

    DECISION_FILE="$DECISIONS_DIR/$TASK_ID.json"
    if [ ! -f "$DECISION_FILE" ]; then
      echo "fm-tg-decision: no pending decision for $TASK_ID" >&2
      exit 1
    fi

    CHAT_ID=$(jq -r '.chat_id // empty' "$DECISION_FILE" 2>/dev/null) || CHAT_ID=
    MSG_ID=$(jq -r '.message_id // empty' "$DECISION_FILE" 2>/dev/null) || MSG_ID=

    if [ -z "$CHAT_ID" ] || [ -z "$MSG_ID" ]; then
      echo "fm-tg-decision: malformed decision record for $TASK_ID" >&2
      rm -f "$DECISION_FILE"
      exit 1
    fi

    # Mark decision resolved and remove keyboard.
    NOW=$(date +%s)
    jq -c --arg action "$ACTION" --argjson resolved_at "$NOW" \
      '.resolved = true | .action = $action | .resolved_epoch = $resolved_at' \
      "$DECISION_FILE" > "$DECISION_FILE.tmp" 2>/dev/null && mv "$DECISION_FILE.tmp" "$DECISION_FILE" || true

    # Remove the keyboard from the decision message.
    fmtg_load_config
    if [ -n "$FMTG_DRY" ] || [ -n "$FMTG_TOKEN" ]; then
      if ! fmtg_edit_reply_markup "$CHAT_ID" "$MSG_ID"; then
        echo "fm-tg-decision: warning: could not remove keyboard from chat $CHAT_ID msg $MSG_ID" >&2
      fi
    fi

    printf 'resolved decision for %s: %s (chat %s msg %s)\n' "$TASK_ID" "$ACTION" "$CHAT_ID" "$MSG_ID"
    ;;

  timeout)
    MAX_AGE=86400
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --max-age) shift; MAX_AGE=${1:-86400}; case "$MAX_AGE" in ''|*[!0-9]*) echo "fm-tg-decision: --max-age needs an integer" >&2; exit 2 ;; esac ;;
        *) usage; exit 2 ;;
      esac
      shift
    done

    NOW=$(date +%s)
    fmtg_load_config

    if [ ! -d "$DECISIONS_DIR" ]; then
      exit 0
    fi

    for f in "$DECISIONS_DIR"/*.json; do
      [ -e "$f" ] || continue
      resolved=$(jq -r '.resolved // false' "$f" 2>/dev/null) || resolved=false
      [ "$resolved" = "true" ] && continue

      expiry=$(jq -r '.expiry_epoch // 0' "$f" 2>/dev/null) || expiry=0
      case "$expiry" in ''|*[!0-9]*) expiry=0 ;; esac
      [ "$expiry" -gt 0 ] 2>/dev/null || continue

      if [ "$NOW" -gt "$expiry" ]; then
        task_id=$(basename "$f" .json)
        chat_id=$(jq -r '.chat_id // empty' "$f" 2>/dev/null) || chat_id=
        msg_id=$(jq -r '.message_id // empty' "$f" 2>/dev/null) || msg_id=

        if [ -n "$chat_id" ] && [ -n "$msg_id" ] && { [ -n "$FMTG_DRY" ] || [ -n "$FMTG_TOKEN" ]; }; then
          fmtg_edit_reply_markup "$chat_id" "$msg_id" 2>/dev/null || true
        fi

        jq -c --argjson now "$NOW" '.resolved = true | .action = "timeout" | .resolved_epoch = $now' \
          "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || true
        printf 'timed out decision for %s\n' "$task_id"
      fi
    done
    ;;

  list)
    if [ ! -d "$DECISIONS_DIR" ]; then
      echo "No pending decisions."
      exit 0
    fi
    count=0
    for f in "$DECISIONS_DIR"/*.json; do
      [ -e "$f" ] || continue
      task_id=$(basename "$f" .json)
      resolved=$(jq -r '.resolved // false' "$f" 2>/dev/null) || resolved=false
      action=$(jq -r '.action // "pending"' "$f" 2>/dev/null) || action="pending"
      if [ "$resolved" = "true" ]; then
        printf '%s - resolved: %s\n' "$task_id" "$action"
      else
        expiry=$(jq -r '.expiry_epoch // 0' "$f" 2>/dev/null) || expiry=0
        printf '%s - pending (expires %s)\n' "$task_id" "$expiry"
      fi
      count=$((count + 1))
    done
    [ "$count" -gt 0 ] || echo "No pending decisions."
    ;;

  clear)
    TASK_ID=${1:-}
    if [ -z "$TASK_ID" ]; then usage; exit 2; fi
    safe_id "$TASK_ID" || { echo "fm-tg-decision: unsafe task id: $TASK_ID" >&2; exit 2; }
    DECISION_FILE="$DECISIONS_DIR/$TASK_ID.json"
    if [ -f "$DECISION_FILE" ]; then
      rm -f "$DECISION_FILE"
      printf 'cleared decision record for %s\n' "$TASK_ID"
    else
      echo "fm-tg-decision: no decision record for $TASK_ID" >&2
      exit 1
    fi
    ;;

  *) usage; exit 2 ;;
esac
