#!/usr/bin/env bash
# Install or update the drain CLI for this user, register its watcher check in one firstmate home, and retire the
# three checks it replaces (nm-quiet, nm-update, nm-upgrade). Idempotent. Usage: install.sh [--dry-run] <fm-home>
# The check id sorts first so a check that wakes every sweep (a wake ends the sweep) cannot starve the drain.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/fm-check-register.sh" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-nm-drain
ID=0-nm-drain
SHIM=$(printf '#!/usr/bin/env bash\nexec %q check %q\n' "$DEST/nm-drain.sh" "$FMH")

run() {
  if [ "$DRY" -eq 1 ]; then echo "would run: $*"; else "$@"; fi
}

if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/nm-drain.sh -> $DEST/nm-drain.sh"
  echo "would write: $FMH/state/$ID.check.sh:"
  printf '%s\n' "$SHIM" | sed 's/^/  /'
else
  mkdir -p "$DEST"
  install -m 755 "$SRC/nm-drain.sh" "$DEST/nm-drain.sh"
  printf '%s\n' "$SHIM" > "$FMH/state/$ID.check.sh"
  chmod 700 "$FMH/state/$ID.check.sh"
fi
# An FM_STATE_OVERRIDE in the caller env, even empty, would redirect the unregister away from FMH/state.
run env -u FM_STATE_OVERRIDE FM_HOME="$FMH" "$FMH/bin/fm-check-register.sh" "$ID"
for old in nm-quiet nm-update nm-upgrade; do
  if [ -e "$FMH/state/$old.check.sh" ] || [ -e "$FMH/state/$old.check-trust" ]; then
    run env -u FM_STATE_OVERRIDE FM_HOME="$FMH" "$FMH/bin/fm-check-unregister.sh" "$old"
  else
    echo "absent: $FMH/state/$old.check.sh"
  fi
done
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
