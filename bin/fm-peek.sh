#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window> [lines=40]
#   <window> may be a bare firstmate window name (fm-xyz), resolved through
#   this home's state/<id>.meta, or explicit session:window.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

T=$(fm_backend_resolve_selector "$1" "$STATE")
N=${2:-40}

# The BACKEND is resolved the same way fm-send.sh resolves it: a bare `fm-<id>`
# target's meta, defaulting to tmux (the P1 compatibility contract) when the
# field is absent or the target carries no meta at all (an explicit
# session:window or an ad hoc bare window name).
BACKEND=tmux
case "$1" in
  fm-*)
    meta="$STATE/${1#fm-}.meta"
    [ -f "$meta" ] && BACKEND=$(fm_backend_of_meta "$meta")
    ;;
esac

fm_backend_capture "$BACKEND" "$T" "$N"
