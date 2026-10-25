#!/usr/bin/env bash
# Install or update the fleet kill guard (rule, Claude hook, pi and OpenCode adapters). Idempotent. Usage: install.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-kill-guard
STAMP=$(date +%s)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
# Every Claude config folder: ~/.claude and each Claude account folder in the muxr registry the account pool launches
# workers with (CLAUDE_CONFIG_DIR), whose settings.json replaces ~/.claude's. Rerun after adding an account.
REG=${FM_CLAUDE_ACCOUNTS_REGISTRY:-$HOME/.muxr/plans/accounts-v1.json}
CLAUDE_DIRS=$( { echo "$HOME/.claude"; [ ! -e "$REG" ] || jq -r '.accounts[] | select(.provider == "claude") | .folder' "$REG" || echo "warning: cannot read $REG; only ~/.claude is covered" >&2; } | awk '!seen[$0]++')
put() {
  local target=$1 new=$2
  if [ -e "$target" ] && cmp -s "$target" "$new"; then echo "unchanged: $target"; return; fi
  if [ -e "$target" ]; then diff -u "$target" "$new" || true; else echo "new: $target"; fi
  [ "$DRY" -eq 0 ] || return 0
  mkdir -p "$(dirname "$target")"
  if [ -e "$target" ]; then cp -p "$target" "$target.bak-kill-guard-$STAMP"; fi
  cp "$new" "$target.tmp-$STAMP" && mv "$target.tmp-$STAMP" "$target"
}

HOOK="node '$DEST/guard.mjs' --caller \$PPID"
put "$DEST/guard.mjs" "$SRC/guard.mjs"
[ "$DRY" -eq 1 ] || [ -d "$DEST/state" ] || mkdir -m 700 "$DEST/state" # private Main-approval audit, retained across updates
for a in pi-extension.ts opencode-plugin.js; do sed "s|__GUARD__|$DEST/guard.mjs|" "$SRC/$a" > "$TMP/$a"; done
if [ -d "$HOME/.pi/agent" ]; then put "$HOME/.pi/agent/extensions/fm-kill-guard.ts" "$TMP/pi-extension.ts"; else echo "skipped: pi (not installed)"; fi
if [ -d "$HOME/.config/opencode" ]; then put "$HOME/.config/opencode/plugins/fm-kill-guard.js" "$TMP/opencode-plugin.js"; else echo "skipped: opencode (not installed)"; fi
while read -r d; do
  [ -d "$d" ] || { echo "skipped: $d (claude not installed)"; continue; }
  { [ -s "$d/settings.json" ] && cat "$d/settings.json" || echo '{}'; } | jq --arg cmd "$HOOK" '
    .hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select((.command // "") | contains("fm-kill-guard/guard.mjs") | not)) | select(.hooks | length > 0)]
      + [{matcher: "Bash", hooks: [{type: "command", command: $cmd, timeout: 10}]}])' > "$TMP/settings.json"
  put "$d/settings.json" "$TMP/settings.json"
done <<<"$CLAUDE_DIRS"
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
