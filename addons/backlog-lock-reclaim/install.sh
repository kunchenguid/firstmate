#!/usr/bin/env bash
# Install or update the backlog-lock-reclaim check for this user and point one firstmate home's
# state/backlog-lock-reclaim.check.sh at it through an exec shim, backing up a replaced check first, then register it.
# Idempotent. Usage: install.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/fm-check-register.sh" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-backlog-lock-reclaim
CHECK=$FMH/state/backlog-lock-reclaim.check.sh
SHIM=$(printf '#!/usr/bin/env bash\nexec %q %q\n' "$DEST/backlog-lock-reclaim.check.sh" "$FMH")
BAK=
[ ! -e "$CHECK" ] || [ "$(cat "$CHECK")" = "$SHIM" ] || BAK=$CHECK.bak-backlog-lock-reclaim-$(date +%s)

if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/backlog-lock-reclaim.check.sh -> $DEST/backlog-lock-reclaim.check.sh"
  [ -z "$BAK" ] || echo "would back up: $CHECK -> $BAK"
  echo "would write: $CHECK:"
  printf '%s\n' "$SHIM" | sed 's/^/  /'
  echo "would run: $FMH/bin/fm-check-register.sh backlog-lock-reclaim"
  echo "dry run: nothing written"
  exit 0
fi
mkdir -p "$DEST"
install -m 755 "$SRC/backlog-lock-reclaim.check.sh" "$DEST/backlog-lock-reclaim.check.sh"
[ -z "$BAK" ] || { cp -p "$CHECK" "$BAK"; echo "backed up: $BAK"; }
printf '%s\n' "$SHIM" > "$CHECK"
chmod 700 "$CHECK"
# An FM_STATE_OVERRIDE in the caller env, even empty, would register away from FMH/state.
env -u FM_STATE_OVERRIDE FM_HOME="$FMH" "$FMH/bin/fm-check-register.sh" backlog-lock-reclaim
echo "installed: $CHECK -> $DEST/backlog-lock-reclaim.check.sh"
