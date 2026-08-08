#!/usr/bin/env bash
# Fleet refill — fleet-depth quarantine (2026-08-08).
#
# The legacy capacity arithmetic is QUARANTINED: the owned-manifest/output
# mtime battery count and the DISPATCH-NEEDED verdict are disabled until the
# shared capacity projection (fm-fleet-capacity.v1) is cut over after parity
# proof. This script never emits a dispatch verdict and never stages work.
# The serialization-debt safety probe and the authoritative bead-query
# diagnostic remain.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Shadow-only parallel run (Task 3): --count-json emits the shared capacity
# object (fm-fleet-capacity.v1); FM_REFILL_SHADOW records that same object
# alongside the quarantined run. Neither path touches the quarantined verdict
# below: consumer decisions stay on the quarantine until the Task 13 cutover
# after parity proof. The snapshot is not modified in this task.
if [ "${1:-}" = "--count-json" ]; then
  # shellcheck source=bin/fm-capacity-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
  fm_capacity_project
  exit 0
fi
if [ -n "${FM_REFILL_SHADOW:-}" ]; then
  # shellcheck source=bin/fm-capacity-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
  fm_capacity_project > "$FM_REFILL_SHADOW"
fi

PROJECT="${FM_REFILL_PROJECT:-/home/holu/decision-os}"
SERIALIZATION_DEBT_PROBE="${FM_SERIALIZATION_DEBT_PROBE:-$FM_HOME/bin/fm-serialization-debt.sh}"

serialization_debt=0
"$SERIALIZATION_DEBT_PROBE" --project "$PROJECT" || serialization_debt=1

open_count="$(cd "$PROJECT" && br list --status open --json 2>/dev/null \
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("total", 0))
except Exception:
    print(-1)' 2>/dev/null || echo -1)"

echo "fleet-refill: capacity=unknown (quarantined); open_beads=$open_count; serialization_debt=$serialization_debt"
if [ "$serialization_debt" -ne 0 ]; then
  exit 1
fi
echo "fleet-ok: quarantine active - no dispatch verdict or staging"
exit 0
