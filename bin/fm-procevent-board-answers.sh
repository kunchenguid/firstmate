#!/usr/bin/env bash
# Board adapter for the existing process-event capture/apply/acknowledge seam.
# Usage: fm-procevent-board-answers.sh autohandle|handle <source> <seq> <result>
#        fm-procevent-board-answers.sh self-announcing|terminal|--help
# Successful routing announces through the task's resolved status and board DB;
# only exceptions remain unacknowledged and wake firstmate. This source stays
# registered; the board daemon starts its next runner after each completion.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) printf 'usage: fm-procevent-board-answers.sh {handle|autohandle} <source> <seq> <result>\n'; exit 0 ;;
  self-announcing) [ "$#" -eq 1 ]; exit $? ;;
  terminal) exit 1 ;;
  handle|autohandle) shift; exec "$SCRIPT_DIR/board/board-answers-handle.sh" capture "$@" ;;
  *) printf 'board-answers: unknown adapter command\n' >&2; exit 1 ;;
esac
