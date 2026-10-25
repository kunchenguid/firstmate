#!/usr/bin/env bash
# Remove the GLM queue service and installed proxy. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }; [ "$#" -eq 0 ] || { echo 'usage: uninstall.sh [--dry-run]' >&2; exit 2; }
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-glm-queue/glm-queue.mjs; UNIT=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fm-glm-queue.service
if [ -e "$UNIT" ]; then
  if [ "$DRY" -eq 1 ]; then echo 'would stop and disable fm-glm-queue.service'; else systemctl --user disable --now fm-glm-queue.service; fi
  echo "remove: $UNIT"; [ "$DRY" -eq 1 ] || rm -f -- "$UNIT"
  [ "$DRY" -eq 1 ] || systemctl --user daemon-reload
  echo 'prior unit contents are not known and cannot be restored'
fi
[ ! -e "$DEST" ] || { echo "remove: $DEST"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST"; }
[ "$DRY" -eq 1 ] || rmdir "${DEST%/*}" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
