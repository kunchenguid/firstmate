#!/usr/bin/env bash
# The parked-homes installer is verify-only; it writes no state to remove.
# Usage: uninstall.sh [<fm-home>]
set -euo pipefail
[ "$#" -le 1 ] || { echo 'usage: uninstall.sh [<fm-home>]' >&2; exit 2; }
if [ "$#" -eq 1 ]; then
  [ -d "$1" ] || { echo "error: home not found: $1" >&2; exit 1; }
elif [ -n "${FM_HOME:-}" ]; then
  [ -d "$FM_HOME" ] || { echo "error: home not found: $FM_HOME" >&2; exit 1; }
fi
echo 'not installed: parked-homes installer is verify-only'
