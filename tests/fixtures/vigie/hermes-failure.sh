#!/usr/bin/env bash
set -u
case "${VIGIE_FIXTURE_FAILURE:-nonzero}" in
  timeout) sleep 30 ;;
  nonzero) printf 'bounded stdout evidence\n'; printf 'bounded stderr evidence\n' >&2; exit 7 ;;
  invalid-json)
    case "$*" in
      "kanban stats --json"|"kanban show --json "*) printf '{invalid\n' ;;
      *) printf 'unknown but successful output\n' ;;
    esac
    ;;
  oversized)
    python3 -c 'print("x" * 5000)'
    ;;
  *) exit 64 ;;
esac
