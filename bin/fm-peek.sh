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

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
# A task whose meta records host= runs on a remote machine, so its pane is not on
# any backend this home can address. Ask the host to capture it instead; the
# relay client is a no-op for every ordinary local task.
if [ -f "$STATE/$RAW_TARGET.meta" ] && grep -q '^host=' "$STATE/$RAW_TARGET.meta" 2>/dev/null; then
  exec "$SCRIPT_DIR/fm-relay-host.sh" peek "$RAW_TARGET" "${2:-40}"
fi
T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
N=${2:-40}

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

# Read from the tmux server the target's own metadata records. A selector with no
# metadata (the explicit session:window escape hatch) resolves to the ambient
# fleet socket, exactly as before (bin/fm-tmux-lib.sh's fm_tmux_socket_of_meta).
fm_backend_bind_meta "$BACKEND" "$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)" || exit 1

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
