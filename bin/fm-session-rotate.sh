#!/usr/bin/env bash
# bin/fm-session-rotate.sh — CLI for context watermarks and automated session rotation
# Usage:
#   fm-session-rotate.sh check <task-id> [--threshold <tokens>]
#   fm-session-rotate.sh generate-handoff <task-id> [--worktree <path>] [--summary "<text>"] [--next "<text>"]
#   fm-session-rotate.sh rotate <task-id> [--threshold <tokens>] [--summary "<text>"] [--next "<text>"]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-session-rotate-lib.sh
. "$SCRIPT_DIR/fm-session-rotate-lib.sh"
# shellcheck source=bin/fm-meta-lib.sh
if [ -f "$SCRIPT_DIR/fm-meta-lib.sh" ]; then
  . "$SCRIPT_DIR/fm-meta-lib.sh"
fi

usage() {
  echo "usage: fm-session-rotate.sh check <task-id> [--threshold <tokens>]"
  echo "       fm-session-rotate.sh generate-handoff <task-id> [--worktree <path>] [--summary \"<text>\"] [--next \"<text>\"]"
  echo "       fm-session-rotate.sh rotate <task-id> [--threshold <tokens>] [--force] [--summary \"<text>\"] [--next \"<text>\"]"
  echo ""
  echo "Commands:"
  echo "  check             Check if task context exceeds threshold (default 80,000 tokens)"
  echo "  generate-handoff  Generate structured state/<id>.handoff.md markdown"
  echo "  rotate            Generate handoff and relaunch only when over threshold (or --force)"
}

if [ $# -lt 2 ]; then
  usage >&2
  exit 1
fi

ACTION="$1"
TASK_ID="$2"
shift 2

THRESHOLD=$FM_SESSION_ROTATE_DEFAULT_THRESHOLD
SUMMARY="Context watermark exceeded threshold; seamless rotation triggered."
NEXT_STEPS="Continue implementation according to brief and handoff summary."
WORKTREE=""
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)
      THRESHOLD="$2"
      shift 2 ;;
    --summary)
      SUMMARY="$2"
      shift 2 ;;
    --next)
      NEXT_STEPS="$2"
      shift 2 ;;
    --worktree)
      WORKTREE="$2"
      shift 2 ;;
    --force)
      FORCE=1
      shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "fm-session-rotate: unknown argument '$1'" >&2
      exit 1 ;;
  esac
done

# If worktree not passed explicitly, attempt to resolve from state/<id>.meta
if [ -z "$WORKTREE" ] && [ -f "$STATE_DIR/$TASK_ID.meta" ]; then
  WORKTREE=$(sed -n 's/^worktree=//p' "$STATE_DIR/$TASK_ID.meta" 2>/dev/null || echo "")
fi

case "$ACTION" in
  check)
    ESTIMATED=$(fm_session_estimate_task_tokens "$STATE_DIR" "$TASK_ID")
    echo "Task: $TASK_ID | Estimated context tokens: $ESTIMATED | Threshold: $THRESHOLD"
    if [ "$ESTIMATED" -ge "$THRESHOLD" ]; then
      echo "Status: ROTATION_NEEDED"
      exit 1
    else
      echo "Status: WITHIN_BUDGET"
      exit 0
    fi
    ;;

  generate-handoff)
    HANDOFF_FILE=$(fm_session_generate_handoff "$STATE_DIR" "$DATA_DIR" "$TASK_ID" "$WORKTREE" "$SUMMARY" "$NEXT_STEPS")
    echo "Handoff generated: $HANDOFF_FILE"
    ;;

  rotate)
    ESTIMATED=$(fm_session_estimate_task_tokens "$STATE_DIR" "$TASK_ID")
    echo "Task: $TASK_ID | Estimated context tokens: $ESTIMATED | Threshold: $THRESHOLD"
    if [ "$ESTIMATED" -lt "$THRESHOLD" ] && [ "$FORCE" -ne 1 ]; then
      echo "Status: WITHIN_BUDGET"
      echo "error: rotate refused; estimated tokens $ESTIMATED are below threshold $THRESHOLD (pass --force to rotate anyway)" >&2
      exit 1
    fi
    echo "Rotating session for $TASK_ID (estimated tokens: $ESTIMATED / $THRESHOLD)..."
    HANDOFF_FILE=$(fm_session_generate_handoff "$STATE_DIR" "$DATA_DIR" "$TASK_ID" "$WORKTREE" "$SUMMARY" "$NEXT_STEPS")
    echo "Handoff generated: $HANDOFF_FILE"

    if [ -f "$SCRIPT_DIR/fm-control.sh" ]; then
      exec "$SCRIPT_DIR/fm-control.sh" "$TASK_ID" relaunch --note-file "$HANDOFF_FILE"
    else
      echo "error: bin/fm-control.sh not found" >&2
      exit 1
    fi
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac
