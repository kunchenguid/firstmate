#!/usr/bin/env bash
# Remove claude-model-guard's settings entries and executable. Usage: uninstall.sh [--dry-run] [--config-dir <dir>]
set -euo pipefail
DRY=0 DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
while [ "$#" -gt 0 ]; do case "$1" in --dry-run) DRY=1 ;; --config-dir) DIR=${2:?--config-dir needs a path}; shift ;; *) echo 'usage: uninstall.sh [--dry-run] [--config-dir <dir>]' >&2; exit 2 ;; esac; shift; done
F=$DIR/settings.json; DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-claude-model-guard; HOOK=$DEST/refuse-model.sh; T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
if [ -s "$F" ]; then
  jq --arg h claude-haiku-5-5 --arg c "$HOOK" 'if .env.ANTHROPIC_DEFAULT_SONNET_MODEL == $h then del(.env.ANTHROPIC_DEFAULT_SONNET_MODEL) else . end | if .env.ANTHROPIC_DEFAULT_FABLE_MODEL == $h then del(.env.ANTHROPIC_DEFAULT_FABLE_MODEL) else . end | if .hooks.UserPromptSubmit then .hooks.UserPromptSubmit |= map(select(any(.hooks[]?; .command == $c) | not)) else . end | if .hooks.PreToolUse then .hooks.PreToolUse |= map(select(any(.hooks[]?; .command == $c) | not)) else . end' "$F" > "$T/settings"
  if ! cmp -s "$F" "$T/settings"; then echo "update: $F"; if [ "$DRY" -eq 0 ]; then stamp=$(date +%s); cp -p "$F" "$F.bak-claude-model-guard-$stamp"; mv "$T/settings" "$F"; fi; fi
fi
[ ! -e "$HOOK" ] || { echo "remove: $HOOK"; [ "$DRY" -eq 1 ] || rm -f -- "$HOOK"; }
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
