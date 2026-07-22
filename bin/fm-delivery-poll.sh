#!/usr/bin/env bash
# Byte-static trusted poll for delivery records.
# Mirrors the PR-poll trust model: reads only validated sidecar data and prints
# one current-state line.
# Usage:
#   fm-delivery-poll.sh <task-id>
#
# Trust rules:
#   - state/<id>.delivery.json must be a regular file, mode 0600, single-link,
#     on the state device.
#   - data/<id>/delivery-receipt.json must satisfy the same trust rules when present.
#   - The poll never writes state.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"

[ "$#" -ge 1 ] || { echo "usage: fm-delivery-poll.sh <task-id>" >&2; exit 2; }
ID=$1
fm_delivery_validate_id "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }

INFLIGHT="$STATE/$ID.delivery.json"
RECEIPT="$DATA/$ID/delivery-receipt.json"

state_device=$(fm_pr_file_device "$STATE") || {
  echo "error: cannot determine state device" >&2
  exit 1
}
data_device=$(fm_pr_file_device "$DATA") || {
  echo "error: cannot determine data device" >&2
  exit 1
}

validate_private_file() {
  local f=$1 device=$2
  fm_pr_private_file_valid "$f" 600 "$device" || return 1
}

# Read the current phase and any block from a trusted in-flight record.
current_state() {
  if [ ! -f "$INFLIGHT" ]; then
    printf 'none\n'
    return 0
  fi
  validate_private_file "$INFLIGHT" "$state_device" || {
    echo "error: unsafe delivery record $INFLIGHT" >&2
    exit 1
  }
  python3 - "$INFLIGHT" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    doc = json.load(fh)
phase = doc.get("phase", "none")
block = doc.get("block")
if block and not block.get("resolvedAt"):
    print(f"blocked:{block.get('reason','')}")
else:
    print(f"phase:{phase}")
PYEOF
}

# Read receipt presence and outcome from a trusted receipt.
receipt_state() {
  if [ ! -f "$RECEIPT" ]; then
    printf 'none\n'
    return 0
  fi
  validate_private_file "$RECEIPT" "$data_device" || {
    echo "error: unsafe receipt $RECEIPT" >&2
    exit 1
  }
  python3 - "$RECEIPT" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    doc = json.load(fh)
status = doc.get("outcome", {}).get("status", "")
print(f"receipt:{status}")
PYEOF
}

phase=$(current_state)
receipt=$(receipt_state)

if [ "$receipt" != "none" ]; then
  echo "delivery:$ID $receipt"
elif [ "$phase" != "none" ]; then
  echo "delivery:$ID $phase"
else
  echo "delivery:$ID none"
fi
