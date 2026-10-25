#!/usr/bin/env bash
# Remove route-change's installed copy and link. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo 'usage: uninstall.sh [--dry-run]' >&2; exit 2; }
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-route-change/route-change; LINK=$HOME/.local/bin/route-change
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$DEST" ]; then echo "remove: $LINK"; [ "$DRY" -eq 1 ] || rm -f -- "$LINK"; fi
[ ! -e "$DEST" ] || { echo "remove: $DEST"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST"; }
[ "$DRY" -eq 1 ] || rmdir "${DEST%/*}" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
