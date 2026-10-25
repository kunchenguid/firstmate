#!/usr/bin/env bash
# Remove only this guard's Claude hook and runtime adapters. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: uninstall.sh [--dry-run]" >&2; exit 2; }
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-read-guard
# Every Claude config folder: ~/.claude and each Claude account folder in the muxr registry the account pool launches
# workers with (CLAUDE_CONFIG_DIR), whose settings.json replaces ~/.claude's. Rerun after adding an account.
REG=${FM_CLAUDE_ACCOUNTS_REGISTRY:-$HOME/.muxr/plans/accounts-v1.json}
CLAUDE_DIRS=$( { echo "$HOME/.claude"; [ ! -e "$REG" ] || jq -r '.accounts[] | select(.provider == "claude") | .folder' "$REG" || echo "warning: cannot read $REG; only ~/.claude is covered" >&2; } | awk '!seen[$0]++')
while read -r d; do
  if [ -s "$d/settings.json" ] && jq -e '[.hooks.PreToolUse[]?.hooks[]? | (.command // "") | select(contains("fm-read-guard/guard.mjs"))] | length > 0' "$d/settings.json" >/dev/null; then
    jq '.hooks.PreToolUse = [.hooks.PreToolUse[] | .hooks |= map(select((.command // "") | contains("fm-read-guard/guard.mjs") | not)) | select(.hooks | length > 0)] | if .hooks.PreToolUse == [] then del(.hooks.PreToolUse) else . end | if .hooks == {} then del(.hooks) else . end' "$d/settings.json" > "$d/settings.json.tmp"
    [ "$DRY" -eq 1 ] || mv "$d/settings.json.tmp" "$d/settings.json"
  fi
done <<<"$CLAUDE_DIRS"
for f in "$DEST/guard.mjs" "$HOME/.pi/agent/extensions/fm-read-guard.ts" "$HOME/.config/opencode/plugins/fm-read-guard.js"; do
  [ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
done
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
