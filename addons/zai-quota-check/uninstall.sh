#!/usr/bin/env bash
# Remove the Z.AI quota check from one firstmate home. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }; [ "$#" -eq 0 ] || { echo 'usage: uninstall.sh [--dry-run]' >&2; exit 2; }
FM_HOME=${FM_HOME:?set FM_HOME to the firstmate home}; f=$FM_HOME/state/zai-quota.check.sh
if [ -e "$f" ]; then
  [ -x "$FM_HOME/bin/fm-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FM_HOME/bin/fm-check-unregister.sh zai-quota"; else env -u FM_STATE_OVERRIDE FM_HOME="$FM_HOME" "$FM_HOME/bin/fm-check-unregister.sh" zai-quota; fi
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
