#!/usr/bin/env bash
# Turn the owner rules off in one firstmate home, giving config/merge-gate back to its previous gate.
# Usage: uninstall.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: uninstall.sh [--dry-run] <fm-home>' >&2; exit 2; }
f=$(cd "$1" && pwd -P)/config/owner-rules
MG=${f%owner-rules}merge-gate PREV=$MG.pre-owner-rules
[ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
if [ -f "$MG" ] && grep -qxF '# fm-owner-rules merge gate' "$MG"; then
  if [ -e "$PREV" ] || [ -L "$PREV" ]; then echo "restore: $PREV -> $MG"; [ "$DRY" -eq 1 ] || mv "$PREV" "$MG"
  else echo "remove: $MG"; [ "$DRY" -eq 1 ] || rm -f -- "$MG"; fi
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
