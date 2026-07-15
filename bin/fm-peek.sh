#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh [--backend <name>] <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta. External endpoints require an explicit
#   Herdr, zellij, Orca, or cmux backend through --backend.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

EXPLICIT_BACKEND=""
if [ "${1:-}" = --backend ]; then
  [ $# -ge 3 ] || { echo "usage: fm-peek.sh [--backend <name>] <target> [lines=40]" >&2; exit 2; }
  EXPLICIT_BACKEND=$2
  shift 2
  fm_backend_validate "$EXPLICIT_BACKEND" || exit 1
fi

RAW_TARGET=$1
N=${2:-40}

if [ -n "$EXPLICIT_BACKEND" ]; then
  if fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" >/dev/null 2>&1; then
    echo "error: --backend is only for external endpoints; task selector '$RAW_TARGET' already has recorded metadata" >&2
    exit 1
  fi
  META=$(fm_backend_meta_for_window "$RAW_TARGET" "$STATE" 2>/dev/null || true)
  if [ -n "$META" ]; then
    RECORDED_BACKEND=$(fm_backend_of_meta "$META")
    if [ "$RECORDED_BACKEND" != "$EXPLICIT_BACKEND" ]; then
      echo "error: explicit backend '$EXPLICIT_BACKEND' conflicts with backend '$RECORDED_BACKEND' recorded in $META" >&2
      exit 1
    fi
  fi
  T=$RAW_TARGET
  BACKEND=$EXPLICIT_BACKEND
  EXPECTED_LABEL=""
else
  T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
  BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
  EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")
fi

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
