#!/usr/bin/env bash
# fm-skill-stats.sh - thin shim for the fleet per-skill statistics reader, which lives in firstmate-addons.
#
# The reader moved to the firstmate-addons repository (fleet-stats/bin/fm-skill-stats.sh,
# importing fm_stats_lib from that same folder); this shim only resolves that
# checkout and execs it with FM_BIN pointing at this fork's bin/, the same
# contract as the fm-dashboard.sh shim.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${FM_HOME:-$CODE_ROOT}"
ADDONS_DIR="${FM_ADDONS_DIR:-$HOME_DIR/projects/firstmate-addons}"
TARGET="$ADDONS_DIR/fleet-stats/bin/fm-skill-stats.sh"
if [ ! -f "$TARGET" ]; then
  echo "fm-skill-stats: firstmate-addons checkout not found (set FM_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
FM_BIN="$SCRIPT_DIR" FM_HOME="$HOME_DIR" exec "$TARGET" "$@"
