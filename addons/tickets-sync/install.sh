#!/usr/bin/env bash
# Usage: FM_HOME=<fleet home> install.sh [--dry-run]
#
# Installs the sync, its writer and the two watcher checks it owns, and
# registers both checks. The sync check publishes work as tickets; the stale
# check writes nothing and prints one line per board ticket whose state
# disagrees with its PR and backlog item, or that no home's work accounts for,
# so its stdout is a Main wake and its silence means the board is true.
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd -P)
dest=${XDG_DATA_HOME:-$HOME/.local/share}/fm-tickets-sync
: "${FM_HOME:?set FM_HOME to the fleet home with data/secondmates.md}"
if [ "${1:-}" = --dry-run ]; then echo "would install $dest and register tickets-sync and tickets-stale"; exit; fi
[ "$#" = 0 ] || { echo 'usage: install.sh [--dry-run]' >&2; exit 2; }
mkdir -p "$dest/tickets-sync" "$dest/fleet-dashboard" "$FM_HOME/state"
install -m 755 "$src/tickets-sync/"{sync,ticket}.py "$dest/tickets-sync/"
install -m 644 "$src/tickets-sync/"{lane,hierarchy}.py "$dest/tickets-sync/"
install -m 644 "$src/fleet-dashboard/task_rows.py" "$dest/fleet-dashboard/task_rows.py"
mkdir -p "$dest/fleet-dashboard/fm-dashboard/icons"; cp -f "$src"/fleet-dashboard/fm-dashboard/icons/* "$dest/fleet-dashboard/fm-dashboard/icons/"
printf '#!/usr/bin/env bash\nexport FM_HOME=%q\nexec python3 %q 2>&1\n' "$FM_HOME" "$dest/tickets-sync/sync.py" > "$FM_HOME/state/tickets-sync.check.sh"
printf '#!/usr/bin/env bash\nexport FM_HOME=%q\nexec python3 %q --check 2>&1\n' "$FM_HOME" "$dest/tickets-sync/sync.py" > "$FM_HOME/state/tickets-stale.check.sh"
chmod 700 "$FM_HOME/state/tickets-sync.check.sh" "$FM_HOME/state/tickets-stale.check.sh"
env -u FM_STATE_OVERRIDE "$FM_HOME/bin/fm-check-register.sh" tickets-sync
env -u FM_STATE_OVERRIDE "$FM_HOME/bin/fm-check-register.sh" tickets-stale
