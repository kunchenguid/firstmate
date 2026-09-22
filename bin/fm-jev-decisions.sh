#!/usr/bin/env bash
# fm-jev-decisions.sh - triage open Firstmate decisions and blockers using Jev System One.
#
# Usage:
#   fm-jev-decisions.sh --task <task-id>
#   fm-jev-decisions.sh --status-file <path>
#   fm-jev-decisions.sh --all
#   fm-jev-decisions.sh --resolve-cmds [--task <task-id> | --all]
#   fm-jev-decisions.sh --json ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

exec python3 "$SCRIPT_DIR/fm-jev-decisions.py" "$@"
