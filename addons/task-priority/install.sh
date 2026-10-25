#!/usr/bin/env bash
# Install or update the task priority check at a known path. Idempotent.
# Usage: install.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-task-priority
if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/bin/fm-task-priority-check.sh -> $DEST/check.sh"
  echo "dry run: nothing written"
else
  mkdir -p "$DEST"
  install -m 755 "$SRC/bin/fm-task-priority-check.sh" "$DEST/check.sh"
  echo "installed: $DEST/check.sh"
fi
