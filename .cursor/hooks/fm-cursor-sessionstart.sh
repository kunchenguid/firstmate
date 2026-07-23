#!/usr/bin/env bash
# Cursor sessionStart adapter for the shared session-start nudge.
# fm-sessionstart-nudge.sh prints plain text; Cursor expects JSON with
# additional_context. Every silence and error path exits 0.
set -u

ROOT="${CURSOR_PROJECT_DIR:-$(pwd -P)}"
[ -x "$ROOT/bin/fm-sessionstart-nudge.sh" ] || exit 0

OUT=$("$ROOT/bin/fm-sessionstart-nudge.sh" 2>/dev/null || true)
[ -n "$OUT" ] || exit 0

command -v jq >/dev/null 2>&1 || {
  printf '%s\n' "$OUT"
  exit 0
}

jq -n --arg ctx "$OUT" '{additional_context: $ctx}'
exit 0
