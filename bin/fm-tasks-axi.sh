#!/usr/bin/env bash
# Run one routine tasks-axi command against the active Firstmate home's backlog.
#
# Usage:
#   bin/fm-tasks-axi.sh <tasks-axi command> [args...]
#
# FM_HOME selects the operational home and defaults to this tracked code root.
# The wrapper passes an absolute --file path for $FM_HOME/data/backlog.md, so a
# split operational home never falls through to the tracked root's .tasks.toml.
# It runs tasks-axi from the operational home, preserving the tracked .tasks.toml
# defaults when code and operational home are the same and tasks-axi's equivalent
# markdown defaults when a split data-only home has no tracked config.
# config/backlog-backend=manual refuses routine tasks-axi use. Validated backlog
# handoffs remain separate and continue to call tasks-axi directly because their
# scripts pass both source and destination paths explicitly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

if [ "$#" -lt 1 ]; then
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

if fm_backlog_backend_manual "$CONFIG"; then
  echo "error: config/backlog-backend=manual selects manual backlog editing; tasks-axi was not run" >&2
  exit 1
fi
if ! fm_tasks_axi_compatible; then
  echo "error: a compatible tasks-axi is required; run bin/fm-bootstrap.sh for the required version" >&2
  exit 1
fi

fm_tasks_axi_run "$FM_HOME" "$@"
