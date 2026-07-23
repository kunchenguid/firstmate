#!/usr/bin/env bash
# Cursor stop adapter for the shared primary turn-end guard.
# Cursor stop payloads carry loop_count instead of stop_hook_active.
# On guard exit 2, return followup_message so the agent repairs supervision.
set -u

ROOT="${CURSOR_PROJECT_DIR:-$(pwd -P)}"
GUARD="$ROOT/bin/fm-turnend-guard.sh"
[ -x "$GUARD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

loop_count=$(printf '%s' "$payload" | jq -r '.loop_count // 0' 2>/dev/null) || exit 0
stop_active=false
[ "$loop_count" -gt 0 ] && stop_active=true

synth=$(jq -n --argjson active "$stop_active" '{stop_hook_active: $active}')
stderr_file=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-cursor.XXXXXX") || exit 0
trap 'rm -f "$stderr_file"' EXIT

printf '%s' "$synth" | "$GUARD" 2>"$stderr_file"
rc=$?
[ "$rc" -eq 2 ] || exit 0

jq -n --rawfile msg "$stderr_file" '{followup_message: $msg}'
exit 0
