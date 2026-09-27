#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
# A selector whose historical metadata records a removed persistent or remote
# home is refused before any local backend adapter is asked to read it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
N=${2:-40}

REMOTE_META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
if [ -n "$REMOTE_META" ] && { [ "$(fm_meta_get "$REMOTE_META" kind)" = secondmate ] || [ -n "$(fm_meta_get "$REMOTE_META" remote_host)" ]; }; then
  echo "error: $RAW_TARGET is a historical secondmate record; remote capture is no longer supported" >&2
  exit 1
fi

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
