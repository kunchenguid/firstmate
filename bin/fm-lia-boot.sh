#!/usr/bin/env bash
# fm-lia-boot.sh - Deterministic Firstmate CLI bridge for Lia executive co-pilot boot.
#
# Provides a single-shot, idempotent entrypoint to boot or warm-attach to Lia.
# Wraps projects/lia/scripts/boot.py, enforces a hard timeout ceiling, and guarantees
# structured JSON output on all outcomes.
#
# Usage: bin/fm-lia-boot.sh [--model <model>] [--harness <harness>] [--pane <pane>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LIA_SCRIPT="$FM_ROOT/projects/lia/scripts/boot.py"

if [ ! -f "$LIA_SCRIPT" ]; then
  printf '{"status":"FAILED","mode":"ERROR","phase":"PREFLIGHT","error":"projects/lia/scripts/boot.py not found"}\n'
  exit 1
fi

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

TIMEOUT_LIMIT=15

fm_run_timed "$TIMEOUT_LIMIT" python3 "$LIA_SCRIPT" --launch "$@"
RC=$?

if [ "$RC" -eq 124 ]; then
  printf '{"status":"FAILED","mode":"ERROR","phase":"TIMEOUT","error":"Lia boot exceeded 15s budget"}\n'
  exit 1
fi

exit "$RC"
