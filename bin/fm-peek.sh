#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-host-root-lib.sh
. "$SCRIPT_DIR/fm-host-root-lib.sh"

RAW_TARGET=$1
TASK_META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
if [ -z "$TASK_META" ]; then
  if TASK_META=$(fm_backend_meta_for_target "$RAW_TARGET" "$STATE" 2>/dev/null); then
    :
  else
    status=$?
    [ "$status" -ne 2 ] || {
      echo "error: backend target '$RAW_TARGET' matches multiple task records" >&2
      exit 2
    }
    TASK_META=
  fi
fi
if [ -n "$TASK_META" ]; then
  fm_host_root_assert_task_cwd "$FM_ROOT" "$TASK_META" || exit $?
else
  fm_host_root_assert_session_cwd "$FM_ROOT" || exit $?
fi

"$SCRIPT_DIR/fm-guard.sh" || true
[ -z "$TASK_META" ] || fm_backend_assert_recorded_endpoint_identity "$TASK_META" || exit $?

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
N=${2:-40}

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
