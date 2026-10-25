#!/usr/bin/env bash
# Remove pipeline-literal-delete adapters and its Claude hook. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: uninstall.sh [--dry-run]" >&2; exit 2; }
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-pipeline-literal-delete
SETTINGS=$HOME/.claude/settings.json
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
if [ -s "$SETTINGS" ] && jq -e '[.hooks.SessionStart[]?.hooks[]? | (.command // "") | select(contains("fm-pipeline-literal-delete"))] | length > 0' "$SETTINGS" >/dev/null; then
  jq '.hooks.SessionStart = ([.hooks.SessionStart[]? | .hooks |= map(select((.command // "") | contains("fm-pipeline-literal-delete") | not)) | select(.hooks | length > 0)])' "$SETTINGS" > "$TMP/settings.json"
  if ! cmp -s "$SETTINGS" "$TMP/settings.json"; then
    echo "update: $SETTINGS"
    if [ "$DRY" -eq 0 ]; then stamp=$(date +%s); cp -p "$SETTINGS" "$SETTINGS.bak-pipeline-literal-delete-$stamp"; mv "$TMP/settings.json" "$SETTINGS"; fi
  fi
fi
f=$HOME/.pi/agent/extensions/fm-literal-delete.ts
[ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
for f in rule.txt context.mjs; do [ ! -e "$DEST/$f" ] || { echo "remove: $DEST/$f"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/$f"; }; done
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 1 ] || true
[ "$DRY" -eq 1 ] && echo "dry run: nothing written" || true
