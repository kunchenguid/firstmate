#!/usr/bin/env bash
# fm-decider-check.sh - the decider lane's hourly poll.
#
# Prints exactly one line when the lane has work it can do without the captain,
# and nothing otherwise. That is the whole contract of a registered custom
# check: silence means "nothing to do", one line means "wake firstmate".
#
# It wakes for two conditions only:
#
#   - a Class A hold with no ruling in the ledger, which the lane can rule and
#     execute on its own;
#   - a hold whose readiness is `work`, which is stalled rather than held and
#     needs a worker dispatched to drive it to the one-act boundary.
#
# It stays silent when every hold is already at the one-act boundary waiting on
# the captain, because that is the healthy state and the daily digest is what
# carries it to him.
#
# Install it as a registered check from the home that holds the lock:
#
#   install -m 0700 bin/fm-decider-check.sh state/decider.check.sh
#   bin/fm-check-register.sh decider
#
# Retire it with bin/fm-check-unregister.sh decider.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/decider/rulings.md"
SCAN="$SCRIPT_DIR/fm-hold-scan.py"

[ -f "$SCAN" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

rows=$(python3 "$SCAN" 2>/dev/null) || exit 0
[ -n "$rows" ] || exit 0

ruled_ids=""
if [ -f "$LEDGER" ]; then
  ruled_ids=$(awk -F'|' '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    { id = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id); print id }
  ' "$LEDGER")
fi

printf '%s\n' "$rows" | RULED="$ruled_ids" python3 -c '
import os, sys, json
ruled = {line.strip() for line in os.environ.get("RULED", "").splitlines() if line.strip()}
unruled_a = []
stalled = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row["class"] == "A" and row["id"] not in ruled:
        unruled_a.append(row["id"])
    if row["readiness"] == "work":
        stalled.append(row["id"])
if not unruled_a and not stalled:
    raise SystemExit(0)
parts = []
if unruled_a:
    parts.append("class_a_unruled=%d (%s)" % (len(unruled_a), ",".join(unruled_a[:5])))
if stalled:
    parts.append("stalled=%d (%s)" % (len(stalled), ",".join(stalled[:5])))
print("decider: " + " ".join(parts))
'
