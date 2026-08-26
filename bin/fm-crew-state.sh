#!/usr/bin/env bash
# fm-crew-state.sh - print one deterministic current-state line for a crew.
#
# state/<id>.status is an append-only, best-effort EVENT LOG - crews append
# only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE.
#
# This script is a thin renderer over the ONE authoritative computed
# projection, fm_worker_state_project in bin/fm-worker-state-lib.sh, which
# owns the full reconciliation (run-step vs pane vs status log) and its
# provenance. bin/fm-peek.sh reads the exact same projection, so the two
# surfaces can never independently disagree about a worker's state - see
# that library's header for the record shape and reconciliation order.
#
# Output is one stable, parseable, token-tight line:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|remote-endpoint|none> · <detail>
#
# Read-only and side-effect free. Always exits 0 on a successful read
# regardless of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-worker-state-lib.sh
. "$SCRIPT_DIR/fm-worker-state-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

fm_worker_state_render_line "$(fm_worker_state_project "$ID")"
