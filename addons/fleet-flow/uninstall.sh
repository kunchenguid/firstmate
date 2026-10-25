#!/usr/bin/env bash
# Remove the installed fleet-flow check. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo 'usage: uninstall.sh [--dry-run]' >&2; exit 2; }
f=${XDG_DATA_HOME:-$HOME/.local/share}/fm-fleet-flow/fm-flow-check.sh
[ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
[ "$DRY" -eq 1 ] || rmdir "${f%/*}" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
