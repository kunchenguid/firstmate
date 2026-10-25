#!/usr/bin/env bash
# Install the fleet literal-path delete rule into the two pipeline-agent instruction surfaces for this
# Unix user: the pi extension every pi session loads, and a Claude Code SessionStart hook. One install
# reaches every pipeline agent (review, test, document, lint; any runtime home) on the machine.
# Idempotent: rerun it to update. Usage: install.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-pipeline-literal-delete
STAMP=$(date +%s)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

# put <target> <candidate> [jq-path]: replace target with candidate after a backup; prints the diff (JSON: only jq-path).
put() {
  local target=$1 new=$2 view=${3:-} old="$TMP/old"
  if [ -e "$target" ] && cmp -s "$target" "$new"; then echo "unchanged: $target"; return; fi
  if [ -n "$view" ]; then
    jq "$view" "$target" > "$old" 2>/dev/null || : > "$old"
    diff -u --label "$target (before) $view" --label "$target (after) $view" "$old" <(jq "$view" "$new") || true
  else
    diff -u --label "$target (before)" --label "$target (after)" "$target" "$new" 2>/dev/null || [ -e "$target" ] || echo "new: $target"
  fi
  [ "$DRY" -eq 0 ] || return 0
  mkdir -p "$(dirname "$target")"
  if [ -e "$target" ]; then cp -p "$target" "$target.bak-pipeline-literal-delete-$STAMP" && cp -p "$target" "$target.tmp-$STAMP"; fi
  cat "$new" > "$target.tmp-$STAMP" && mv "$target.tmp-$STAMP" "$target"
}

# starthook <settings.json>: merge one SessionStart entry, dropping any older rule entry.
starthook() {
  local file=$1 cmd="node '$DEST/context.mjs'"
  [ -d "$(dirname "$file")" ] || { echo "skipped: $file (Claude Code not installed)"; return; }
  # shellcheck disable=SC2016 # $cmd is a jq variable
  { [ -s "$file" ] && cat "$file" || echo '{}'; } | jq --arg cmd "$cmd" '
    .hooks.SessionStart = ([.hooks.SessionStart[]? | .hooks |= map(select((.command // "") | contains("fm-pipeline-literal-delete") | not)) | select(.hooks | length > 0)]
      + [{hooks: [{type: "command", command: $cmd, timeout: 10}]}])' > "$TMP/ss.json"
  put "$file" "$TMP/ss.json" .hooks.SessionStart
}

put "$DEST/rule.txt" "$SRC/rule.txt"
put "$DEST/context.mjs" "$SRC/context.mjs"
if [ -d "$HOME/.pi/agent" ]; then
  sed "s|__RULE_PATH__|$DEST/rule.txt|" "$SRC/pi-literal-delete.ts" > "$TMP/pi-literal-delete.ts"
  put "$HOME/.pi/agent/extensions/fm-literal-delete.ts" "$TMP/pi-literal-delete.ts"
else
  echo "skipped: $HOME/.pi/agent (pi not installed)"
fi
starthook "$HOME/.claude/settings.json"
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
