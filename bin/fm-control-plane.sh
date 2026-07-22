#!/usr/bin/env bash
# fm-control-plane.sh - evidence-backed software fleet orientation.
#
# Usage:
#   fm-control-plane.sh [--sources <path>] [--json]
#   fm-control-plane.sh [--sources <path>] --attention-fingerprint
#
# The command is read-only.
# It reconciles the explicitly registered software sources, prints a captain-
# facing orientation by default, and exposes `fm-control-plane.v1` with --json.
# Source registration, work-item proof records, trust boundaries, and the
# guarantee boundary are owned by docs/control-plane.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

command -v node >/dev/null 2>&1 || {
  echo "fm-control-plane: node not found" >&2
  exit 127
}

exec node "$SCRIPT_DIR/fm-control-plane.mjs" \
  --root "$FM_ROOT" \
  --home "$FM_HOME" \
  "$@"
