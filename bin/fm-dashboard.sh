#!/usr/bin/env bash
# fm-dashboard.sh - thin shim for the fleet dashboard, which lives in firstmate-addons.
#
# The dashboard moved to the firstmate-addons repository
# (fleet-dashboard/fm-dashboard.sh plus its fleet-dashboard/fm-dashboard/ app);
# this shim only resolves that checkout and execs it with FM_BIN pointing at
# this fork's bin/, so the add-on runs the fork's helper scripts.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${FM_HOME:-$CODE_ROOT}"
ADDONS_DIR="${FM_ADDONS_DIR:-$HOME_DIR/projects/firstmate-addons}"
TARGET="$ADDONS_DIR/fleet-dashboard/fm-dashboard.sh"
if [ ! -f "$TARGET" ]; then
  echo "fm-dashboard: firstmate-addons checkout not found (set FM_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
FM_BIN="$SCRIPT_DIR" exec "$TARGET" "$@"
