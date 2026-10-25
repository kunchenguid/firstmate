#!/usr/bin/env bash
# Remove owner-guard hooks, merge gate, and installed copy. Usage: uninstall.sh [--dry-run] [<fm-home>]
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }; [ "$#" -le 1 ] || { echo 'usage: uninstall.sh [--dry-run] [<fm-home>]' >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-owner-guard; GDEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-git-identity; FMH=${1:-$(cat "$DEST/home" 2>/dev/null || true)}
if [ "$DRY" -eq 1 ]; then
  if [ -n "$FMH" ]; then "$SRC/install.sh" --dry-run --uninstall "$FMH"; else "$SRC/install.sh" --dry-run --uninstall; fi
  if [ -n "$FMH" ]; then "$SRC/install-scan.sh" --dry-run --uninstall "$FMH"; else "$SRC/install-scan.sh" --dry-run --uninstall; fi
else
  if [ -n "$FMH" ]; then "$SRC/install.sh" --uninstall "$FMH"; else "$SRC/install.sh" --uninstall; fi
  if [ -n "$FMH" ]; then "$SRC/install-scan.sh" --uninstall "$FMH"; else "$SRC/install-scan.sh" --uninstall; fi
fi
for f in "$DEST/owner-guard" "$DEST/home" "$GDEST/hooks.d/pre-commit/owner-guard" "$GDEST/hooks.d/pre-push/owner-guard"; do
  [ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
done
[ "$DRY" -eq 1 ] || { rmdir "$GDEST/hooks.d/pre-commit" "$GDEST/hooks.d/pre-push" "$GDEST/hooks.d" 2>/dev/null || true; rmdir "$DEST" 2>/dev/null || true; }
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
