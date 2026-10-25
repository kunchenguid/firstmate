#!/usr/bin/env bash
# Remove nm-drain and its check registration. Usage: uninstall.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }; [ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: uninstall.sh [--dry-run] <fm-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P); DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-nm-drain; f=$FMH/state/0-nm-drain.check.sh
if [ -e "$f" ]; then
  [ -x "$FMH/bin/fm-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/fm-check-unregister.sh 0-nm-drain"; else env -u FM_STATE_OVERRIDE FM_HOME="$FMH" "$FMH/bin/fm-check-unregister.sh" 0-nm-drain; fi
fi
[ ! -e "$DEST/nm-drain.sh" ] || { echo "remove: $DEST/nm-drain.sh"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/nm-drain.sh"; }
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
echo 'prior nm-quiet, nm-update, and nm-upgrade checks are not known and cannot be restored'
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
