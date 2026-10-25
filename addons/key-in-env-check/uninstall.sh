#!/usr/bin/env bash
# Remove key-in-env-check's home shim, check registration, and installed script. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }; [ "$#" -eq 0 ] || { echo 'usage: uninstall.sh [--dry-run]' >&2; exit 2; }
FM_HOME=${FM_HOME:?set FM_HOME to the firstmate home}; DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-key-in-env-check; f=$FM_HOME/state/key-in-env-check.check.sh
if [ -e "$f" ]; then
  [ -x "$FM_HOME/bin/fm-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FM_HOME/bin/fm-check-unregister.sh key-in-env-check"; else env -u FM_STATE_OVERRIDE FM_HOME="$FM_HOME" "$FM_HOME/bin/fm-check-unregister.sh" key-in-env-check; fi
fi
[ ! -e "$DEST/key-in-env-check" ] || { echo "remove: $DEST/key-in-env-check"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/key-in-env-check"; }
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
