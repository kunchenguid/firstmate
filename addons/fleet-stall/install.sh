#!/usr/bin/env bash
# Install or update fleet-stall: copy the check to
# ${XDG_DATA_HOME:-~/.local/share}/fm-fleet-stall/fleet-stall-check, write the home's
# state/fleet-stall.check.sh as a one-line shim that execs it (mode 700, the old
# file kept as .bak-fleet-stall-<stamp> when it differs), and register the
# fleet-stall check with the home's bin/fm-check-register.sh. Idempotent.
# Usage: install.sh [--dry-run]  (FM_HOME must name the home that runs it)
set -euo pipefail
dry=0
[ "${1:-}" = --dry-run ] && dry=1
FM_HOME=${FM_HOME:?set FM_HOME to the firstmate home that runs the check}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fleet-stall-check
dest=${XDG_DATA_HOME:-$HOME/.local/share}/fm-fleet-stall/fleet-stall-check
check=$FM_HOME/state/fleet-stall.check.sh
shim=$(printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$dest")
if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $dest, write $check as a shim to it (mode 700) and register the fleet-stall check"
  exit 0
fi
mkdir -p "${dest%/*}" "$FM_HOME/state"
install -m 755 "$src" "$dest"
if [ "$(cat "$check" 2>/dev/null)" != "$shim" ]; then
  bak=$check.bak-fleet-stall-$(date +%s)
  [ ! -e "$check" ] || { cp -p "$check" "$bak"; echo "backup: $bak"; }
  printf '%s\n' "$shim" > "$check"
fi
chmod 700 "$check"
if [ -x "$FM_HOME/bin/fm-check-register.sh" ]; then
  env -u FM_STATE_OVERRIDE "$FM_HOME/bin/fm-check-register.sh" fleet-stall
fi
echo "installed $dest; $check execs it"
