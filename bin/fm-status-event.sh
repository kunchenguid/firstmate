#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: fm-status-event.sh append <state-dir> <task-id> <status-line>" >&2
  echo "       fm-status-event.sh resolve <state-dir> <task-id> <resolved-status-line>" >&2
  echo "       fm-status-event.sh self-append <state-dir> <task-id> <status-line>" >&2
  echo "       fm-status-event.sh self-resolve <state-dir> <task-id> <resolved-status-line>" >&2
  echo "       fm-status-event.sh record <state-dir> <task-id> <status-line> <epoch>" >&2
  exit 2
}

MODE=${1:-}
STATE=${2:-}
ID=${3:-}
LINE=${4:-}
[ -n "$STATE" ] && [ -n "$ID" ] && [ -n "$LINE" ] || usage
case "$ID" in ''|*[!A-Za-z0-9._-]*) usage ;; esac

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

case "$MODE" in
  append|resolve|self-append|self-resolve)
    at=$(date +%s)
    ;;
  record)
    at=${5:-}
    case "$at" in ''|*[!0-9]*) usage ;; esac
    ;;
  *) usage ;;
esac
case "$(status_line_verb "$LINE")" in
  working) state=working ;;
  needs-decision) state=parked ;;
  blocked) state=blocked ;;
  "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") state=paused ;;
  "done") state="done" ;;
  failed) state=failed ;;
  *) state= ;;
esac
if [ "$MODE" = resolve ] || [ "$MODE" = self-resolve ]; then
  [ "$(status_line_verb "$LINE")" = "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}" ] || usage
  state=working
fi
if [ "$MODE" = record ]; then
  [ -z "$state" ] || "$SCRIPT_DIR/fm-dashboard-transition.sh" record "$STATE" "$ID" "$state" "$at"
else
  case "$MODE" in
    resolve|self-resolve)
      "$SCRIPT_DIR/fm-dashboard-transition.sh" "$MODE" "$STATE" "$ID" "$at" "$LINE"
      ;;
    append|self-append)
      "$SCRIPT_DIR/fm-dashboard-transition.sh" "$MODE" "$STATE" "$ID" "$state" "$at" "$LINE"
      ;;
  esac
fi
