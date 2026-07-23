#!/usr/bin/env bash
# Cursor sessionStart adapter for the shared firstmate session-start nudge.
#
# Cursor sessionStart can inject additional_context into the conversation.
# This adapter runs bin/fm-sessionstart-nudge.sh and, when it prints the
# instruction, returns it as additional_context. Silence stays {}.
#
# Usage: wired from .cursor/hooks.json sessionStart; prints Cursor sessionStart
# JSON on stdout.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || {
  printf '%s\n' '{}'
  exit 0
}
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)" || {
  printf '%s\n' '{}'
  exit 0
}
[ -x "$ROOT/bin/fm-sessionstart-nudge.sh" ] || { printf '%s\n' '{}'; exit 0; }

MSG=$("$ROOT/bin/fm-sessionstart-nudge.sh" 2>/dev/null || true)
[ -n "$MSG" ] || { printf '%s\n' '{}'; exit 0; }

json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
    || printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | sed 's/^/"/;s/$/"/'
}

ESCAPED=$(json_escape "$MSG")
printf '{"additional_context":%s}\n' "$ESCAPED"
exit 0
