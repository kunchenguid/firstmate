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
export FM_ROOT
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
LIA_SCRIPT="$FM_ROOT/projects/lia/scripts/boot.py"
if [ ! -f "$LIA_SCRIPT" ] && [ -f "${HOME:-}/.lia/boot.py" ]; then
  LIA_SCRIPT="${HOME:-}/.lia/boot.py"
fi

if [ ! -f "$LIA_SCRIPT" ]; then
  printf '{"status":"FAILED","mode":"ERROR","phase":"PREFLIGHT","error":"projects/lia/scripts/boot.py not found"}\n'
  exit 1
fi

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

TIMEOUT_LIMIT=15

BOOT_OUTPUT=$(fm_run_timed "$TIMEOUT_LIMIT" python3 "$LIA_SCRIPT" --launch "$@")
RC=$?

if [ "$RC" -eq 124 ]; then
  printf '{"status":"FAILED","mode":"ERROR","phase":"TIMEOUT","error":"Lia boot exceeded 15s budget"}\n'
  exit 1
fi

if [ -n "$BOOT_OUTPUT" ]; then
  printf '%s\n' "$BOOT_OUTPUT"
fi

if [ "$RC" -eq 0 ]; then
  GREETINGS=(
    "Welcome to the bridge, Lia. Engine room standing by."
    "Welcome aboard, Lia. Systems nominal, Jala online."
    "Good to have the bridge online, Lia. Standing by for directives."
    "Welcome back, Lia. IPC link active, ready."
    "Welcome back, Lia. Good to have you on the bridge again."
    "The bridge is yours, Lia. Engine room is primed and ready."
    "Welcome on deck, Lia. Fleet is under way, awaiting your helm."
    "Welcome back, Lia. Core systems synchronized, Jala standing by."
    "Welcome aboard, Lia. Ship is ready, let's get to work."
    "Lia, welcome. Systems shipshape, standing by."
  )
  RANDOM_IDX=$(( RANDOM % ${#GREETINGS[@]} ))
  GREETING="${GREETINGS[$RANDOM_IDX]}"

  if command -v herdr >/dev/null 2>&1; then
    herdr agent prompt lia "$GREETING" >/dev/null 2>&1 || true
  elif [ -x "$SCRIPT_DIR/fm-send.sh" ]; then
    "$SCRIPT_DIR/fm-send.sh" lia "$GREETING" || true
  fi
fi

exit "$RC"
