#!/usr/bin/env bash
# Remove claude-quota's check registration, shim, and installed executable. Usage: uninstall.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: uninstall.sh [--dry-run] <fm-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P); DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-claude-quota; f=$FMH/state/claude-quota.check.sh
if [ -e "$f" ]; then
  [ -x "$FMH/bin/fm-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/fm-check-unregister.sh claude-quota"; else env -u FM_STATE_OVERRIDE FM_HOME="$FMH" "$FMH/bin/fm-check-unregister.sh" claude-quota; fi
fi
[ ! -e "$DEST/claude-quota.check.sh" ] || { echo "remove: $DEST/claude-quota.check.sh"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/claude-quota.check.sh"; }
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
