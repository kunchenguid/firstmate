#!/usr/bin/env bash
# Firstmate per-turn quota instrumentation dispatcher.
#
# Usage:
#   bin/fm-turn-quota.sh write     # Record turn end instrumentation
#   bin/fm-turn-quota.sh report    # Print turn quota summary (default)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-report}" in
  write|writer)
    shift
    exec "$SCRIPT_DIR/fm-turn-quota-writer.sh" "$@"
    ;;
  read|reader|report|summary)
    shift
    exec "$SCRIPT_DIR/fm-turn-quota-reader.sh" "$@"
    ;;
  -h|--help)
    echo "usage: $(basename "$0") [write|report] [options]"
    exit 0
    ;;
  -*)
    exec "$SCRIPT_DIR/fm-turn-quota-reader.sh" "$@"
    ;;
  *)
    # An unrecognized subcommand must fail loudly: silently reporting instead of
    # recording turns them into a missing measurement nobody notices.
    echo "usage: $(basename "$0") [write|report] [options]" >&2
    exit 2
    ;;
esac
