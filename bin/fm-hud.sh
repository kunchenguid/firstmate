#!/usr/bin/env bash
# fm-hud.sh - Captain HUD: a read-only, project-agnostic status dashboard.
#
# Renders a single-glance snapshot of whatever this firstmate home is doing:
# the selected task's mission, worker health, banked checkpoints, and AI
# subscription quota (session/weekly windows, never the composite all_models
# row). Zero model calls, zero mutation - see bin/fm-hud.py's module docstring
# for the exact collector contract and why it never hardcodes a project, task
# id, branch, or slice name.
#
# Usage:
#   fm-hud.sh                 watch mode, redraws every few seconds
#   fm-hud.sh --once          single snapshot
#   fm-hud.sh --json          normalized state as JSON, no ANSI
#   fm-hud.sh --task <id>     select an explicit task instead of auto-discovery
#   fm-hud.sh --project <name>  filter to one project by display name
#
# All logic lives in bin/fm-hud.py (stdlib only); this wrapper only resolves
# FM_HOME the same way every other fm-*.sh script does and execs the
# interpreter actually on PATH.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

PYTHON_BIN="${FM_HUD_PYTHON:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "fm-hud: python3 not found on PATH" >&2
  exit 1
fi

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-hud.py" "$@"
