#!/usr/bin/env bash
# Test-only barrier around the real inbox producer's external rename.
# Usage: pause-inbox-publication.sh <code-root> <home> <control-dir> <message> [before|after]
set -euo pipefail
root=$1
export FM_HOME=$2 CONTROL=$3 PAUSE_MODE=${5:-before}
mkdir -p "$CONTROL"
mv() {
  local last=${!#} i
  case "$last" in
    "$FM_HOME"/state/inbox/*.note)
      if [ "$PAUSE_MODE" = after ]; then command mv "$@"; fi
      printf '%s\n' "$BASHPID" > "$CONTROL/producer-pid"
      touch "$CONTROL/paused"
      for ((i=0;i<600;i++)); do [ ! -f "$CONTROL/release" ] || break; sleep .05; done
      [ -f "$CONTROL/release" ] || return 90
      [ "$PAUSE_MODE" != after ] || return 0
      ;;
  esac
  command mv "$@"
}
export -f mv
exec bash "$root/bin/fm-inbox.sh" note "$4"
