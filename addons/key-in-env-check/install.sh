#!/usr/bin/env bash
# Install or update key-in-env-check: copy the check to ${XDG_DATA_HOME:-~/.local/share}/fm-key-in-env-check/,
# write the home's state/key-in-env-check.check.sh as a shim that execs it (old file kept as .bak) and
# register it with the home's bin/fm-check-register.sh. Idempotent. Usage: install.sh [--dry-run]  (FM_HOME names the home)
set -euo pipefail
dry=0
[ "${1:-}" = --dry-run ] && dry=1
FM_HOME=${FM_HOME:?set FM_HOME to the firstmate home that runs the check}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/key-in-env-check
dest=${XDG_DATA_HOME:-$HOME/.local/share}/fm-key-in-env-check/key-in-env-check
check=$FM_HOME/state/key-in-env-check.check.sh
shim=$(printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$dest")
if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $dest, write $check as a shim to it (mode 700) and register the key-in-env-check check"
  exit 0
fi
mkdir -p "${dest%/*}" "$FM_HOME/state"
install -m 755 "$src" "$dest"
if [ "$(cat "$check" 2>/dev/null)" != "$shim" ]; then
  bak=$check.bak-key-in-env-check-$(date +%s)
  [ ! -e "$check" ] || { cp -p "$check" "$bak"; echo "backup: $bak"; }
  printf '%s\n' "$shim" > "$check"
fi
chmod 700 "$check"
if [ -x "$FM_HOME/bin/fm-check-register.sh" ]; then
  env -u FM_STATE_OVERRIDE "$FM_HOME/bin/fm-check-register.sh" key-in-env-check
fi
echo "installed $dest; $check execs it"
