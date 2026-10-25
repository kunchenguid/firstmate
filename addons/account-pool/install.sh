#!/usr/bin/env bash
# account-pool install.sh - verify the wiring for one firstmate home; changes nothing. The add-on
# works through hook lines in the home's bin/fm-spawn.sh and bin/fm-control.sh sourcing this checkout.
# Usage: install.sh <fm-home>
set -u
home=${1:-${FM_HOME:-}}
[ -n "$home" ] && [ -d "$home" ] || { echo "account-pool install: usage: install.sh <fm-home>" >&2; exit 1; }
lib=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/fm-account-pool-lib.sh
addons=${FM_ADDONS_DIR:-$home/projects/firstmate-addons}
status=0
if [ -f "$addons/account-pool/bin/fm-account-pool-lib.sh" ]; then
  cmp -s "$addons/account-pool/bin/fm-account-pool-lib.sh" "$lib" && echo "add-on checkout: $addons (lib matches)" || echo "add-on checkout: $addons (lib DIFFERS from this checkout)"
else
  echo "MISSING: add-on checkout at $addons/account-pool (set FM_ADDONS_DIR)"; status=1
fi
for f in fm-spawn.sh fm-control.sh; do
  grep -q 'fm_account_hook' "$home/bin/$f" 2>/dev/null && echo "fork hook: bin/$f calls fm_account_hook" || { echo "MISSING: fm_account_hook lines in $home/bin/$f"; status=1; }
done
[ -f "$home/config/account-pool" ] && echo "pool file: $home/config/account-pool" || echo "pool file: absent (the pool is off)"
exit "$status"
