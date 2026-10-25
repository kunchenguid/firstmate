#!/usr/bin/env bash
# Remove the supervisor-work guard: the PreToolUse hook install.sh merged into
# ~/.claude/settings.json, then the installed files. Idempotent. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -le 1 ] || { echo "usage: uninstall.sh [--dry-run] [<fm-home>]" >&2; exit 2; }
FMH=
if [ "$#" -eq 1 ]; then
  [ -d "$1" ] || { echo "uninstall.sh: home is not a directory: $1" >&2; exit 2; }
  FMH=$(cd "$1" && pwd -P)
fi
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-supervisor-guard
SETTINGS=$HOME/.claude/settings.json
STAMP=$(date +%s)
TMP=$(mktemp -d)
on_exit() {
  rm -rf -- "$TMP"
}
trap on_exit EXIT

if [ -n "$FMH" ] && [ -f "$DEST/home" ]; then
  grep -Fvx -- "$FMH" "$DEST/home" > "$TMP/home" || :
  if [ -s "$TMP/home" ]; then
    diff -u --label "$DEST/home (before)" --label "$DEST/home (after)" "$DEST/home" "$TMP/home" || true
    if [ "$DRY" -eq 0 ]; then
      cp -p "$DEST/home" "$DEST/home.bak-supervisor-guard-$STAMP"
      cat "$TMP/home" > "$DEST/home.tmp-$STAMP" && mv "$DEST/home.tmp-$STAMP" "$DEST/home"
    fi
    [ "$DRY" -eq 1 ] || { echo "homes remain; hook and files retained"; exit 0; }
    echo "dry run: remaining homes retain hook and files"
    exit 0
  fi
fi

if [ -s "$SETTINGS" ] && jq -e '[.hooks.PreToolUse[]?.hooks[]? | (.command // "") | select(contains("fm-supervisor-work-pretool-check.sh"))] | length > 0' "$SETTINGS" >/dev/null; then
  jq '.hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select((.command // "") | contains("fm-supervisor-work-pretool-check.sh") | not)) | select(.hooks | length > 0)])' \
    "$SETTINGS" > "$TMP/settings.json"
  if cmp -s "$SETTINGS" "$TMP/settings.json"; then
    echo "unchanged: $SETTINGS"
  else
    diff -u --label "$SETTINGS (before)" --label "$SETTINGS (after)" "$SETTINGS" "$TMP/settings.json" || true
    if [ "$DRY" -eq 0 ]; then
      cp -p "$SETTINGS" "$SETTINGS.bak-supervisor-guard-$STAMP"
      cat "$TMP/settings.json" > "$SETTINGS.tmp-$STAMP" && mv "$SETTINGS.tmp-$STAMP" "$SETTINGS"
    fi
  fi
fi

for f in fm-supervisor-work-pretool-check.sh fm-supervisor-work-decide.mjs fm-supervisor-work-command-policy.mjs home; do
  if [ -e "$DEST/$f" ]; then
    echo "remove: $DEST/$f"
    [ "$DRY" -eq 1 ] || rm -f -- "$DEST/$f"
  fi
done
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
