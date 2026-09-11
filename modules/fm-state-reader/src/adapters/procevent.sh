#!/usr/bin/env bash
# Registered-source adapter for immutable module JSON events.
# Usage: procevent.sh read|classify|terminal <captured-result>
# The process-event owner captures and acknowledges; this adapter never acts.
set -eu
case "${1:-}" in
  read) [ -f "${2:-}" ] && [ ! -L "$2" ] && /bin/cat "$2" ;;
  classify) printf 'proposal\n' ;;
  terminal) exit 0 ;;
  *) exit 2 ;;
esac
