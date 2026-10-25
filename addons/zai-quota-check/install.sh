#!/usr/bin/env bash
# Install or update zai-quota-check: copy the check into $FM_HOME/state/ as
# zai-quota.check.sh (mode 700, the state-check convention) and register the
# zai-quota check with the home's bin/fm-check-register.sh. Idempotent.
# Usage: install.sh [--dry-run]  (FM_HOME must name the home that runs it)
set -euo pipefail
dry=0
[ "${1:-}" = --dry-run ] && dry=1
FM_HOME=${FM_HOME:?set FM_HOME to the firstmate home that runs the check}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/zai-quota-check
dest=$FM_HOME/state/zai-quota.check.sh
if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $dest (mode 700) and register the zai-quota check"
  exit 0
fi
mkdir -p "$FM_HOME/state"
cp -p "$src" "$dest"
chmod 700 "$dest"
if [ -x "$FM_HOME/bin/fm-check-register.sh" ]; then
  "$FM_HOME/bin/fm-check-register.sh" zai-quota
fi
echo "installed $dest"
