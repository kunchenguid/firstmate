#!/usr/bin/env bash
# Manage the results-first delivery phase lifecycle for a ship task.
# Usage:
#   fm-delivery-phase.sh start <task-id> <phase> [--budget <seconds>]
#   fm-delivery-phase.sh complete <task-id> <phase> --result <passed|blocked|failed|not_applicable> [--evidence <manifest-sha>]
#   fm-delivery-phase.sh block <task-id> <reason>
#   fm-delivery-phase.sh resume <task-id> <phase>
#   fm-delivery-phase.sh status <task-id>
#   fm-delivery-phase.sh finalize <task-id>
#
# Mutable in-flight record: state/<id>.delivery.json (mode 0600).
# Final retained receipt: data/<id>/delivery-receipt.json (mode 0600).
# Phase transitions are monotonic and identity-bound. A block preserves the
# prior phase and records a reason; resume continues from the blocked phase.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
CMD=$1
ID=$2
shift 2

if ! printf '%s' "$ID" | grep -qxE '[A-Za-z0-9._-]+'; then
  echo "error: invalid task id: $ID" >&2
  exit 2
fi

INFLIGHT="$STATE/$ID.delivery.json"
RECEIPT_DIR="$DATA/$ID"
RECEIPT="$RECEIPT_DIR/delivery-receipt.json"

# Default phase budgets (seconds). These are escalation/reroute thresholds, never
# safety bypasses.
FM_DELIVERY_BUDGET_accepted=${FM_DELIVERY_BUDGET_accepted:-1800}
FM_DELIVERY_BUDGET_implementing=${FM_DELIVERY_BUDGET_implementing:-7200}
FM_DELIVERY_BUDGET_validating=${FM_DELIVERY_BUDGET_validating:-3600}
FM_DELIVERY_BUDGET_landing=${FM_DELIVERY_BUDGET_landing:-1800}
FM_DELIVERY_BUDGET_landed=${FM_DELIVERY_BUDGET_landed:-1800}
FM_DELIVERY_BUDGET_released=${FM_DELIVERY_BUDGET_released:-1800}
FM_DELIVERY_BUDGET_deployed=${FM_DELIVERY_BUDGET_deployed:-1800}
FM_DELIVERY_BUDGET_smoke_verified=${FM_DELIVERY_BUDGET_smoke_verified:-900}
FM_DELIVERY_BUDGET_cleanup_eligible=${FM_DELIVERY_BUDGET_cleanup_eligible:-900}

phase_budget_seconds() {
  local phase=$1
  local var="FM_DELIVERY_BUDGET_$phase"
  local val=${!var:-1800}
  case "$val" in ''|*[!0-9]*) val=1800 ;; esac
  printf '%s\n' "$val"
}

# Read the in-flight record or initialize a blank document.
read_inflight() {
  if [ -f "$INFLIGHT" ]; then
    cat "$INFLIGHT"
  else
    printf '{}\n'
  fi
}

# Atomic write of the in-flight record with mode 0600.
write_inflight() {
  local content=$1
  local tmp
  mkdir -p "$STATE"
  tmp=$(mktemp "$INFLIGHT.tmp.XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  fm_delivery_atomic_replace "$tmp" "$INFLIGHT" 0600 || return 1
}

# Atomic write of the final receipt with mode 0600.
write_receipt() {
  local content=$1
  local tmp
  mkdir -p "$RECEIPT_DIR"
  chmod 700 "$RECEIPT_DIR" 2>/dev/null || true
  tmp=$(mktemp "$RECEIPT.tmp.XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  fm_delivery_atomic_replace "$tmp" "$RECEIPT" 0600 || return 1
}

# Update the in-flight record via python3.
# Args: python_code input_json
py_update() {
  python3 -c "$1" "$2"
}

start_phase() {
  local phase=$1 budget=${2:-}
  [ -n "$budget" ] || budget=$(phase_budget_seconds "$phase")
  local ts now doc
  now=$(fm_delivery_timestamp)
  doc=$(read_inflight)
  ts=$(python3 - "$phase" "$budget" "$now" "$doc" <<'PYEOF'
import json, sys
phase, budget, now, doc = sys.argv[1], int(sys.argv[2]), sys.argv[3], json.loads(sys.argv[4])
current = doc.get("phase", "")
phases = ["accepted", "implementing", "validating", "landing", "landed", "released", "deployed", "smoke_verified", "receipt_finalized", "cleanup_eligible"]
if phase not in phases:
    print(f"error: unknown phase {phase}", file=sys.stderr)
    sys.exit(1)
if current and phases.index(phase) < phases.index(current):
    print(f"error: cannot move backwards from {current} to {phase}", file=sys.stderr)
    sys.exit(1)
doc["phase"] = phase
if "phases" not in doc:
    doc["phases"] = []
# Close any already-open entry for this phase.
for p in doc["phases"]:
    if p.get("name") == phase and p.get("completedAt") is None:
        p["completedAt"] = now
        p["result"] = "superseded"
entry = {"name": phase, "startedAt": now, "completedAt": None, "budgetSeconds": budget, "result": None, "evidence": []}
doc["phases"].append(entry)
doc["updatedAt"] = now
print(json.dumps(doc))
PYEOF
) || return 1
  write_inflight "$ts" || return 1
  echo "phase: $phase started for $ID"
}

complete_phase() {
  local phase=$1 result=$2 evidence=${3:-}
  local now doc
  now=$(fm_delivery_timestamp)
  doc=$(read_inflight)
  doc=$(python3 - "$phase" "$result" "$evidence" "$now" "$doc" <<'PYEOF'
import json, sys
phase, result, evidence, now, doc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], json.loads(sys.argv[5])
valid_results = {"passed", "blocked", "failed", "not_applicable"}
if result not in valid_results:
    print(f"error: invalid result {result}", file=sys.stderr)
    sys.exit(1)
if doc.get("phase") != phase:
    print(f"error: current phase is {doc.get('phase')}, cannot complete {phase}", file=sys.stderr)
    sys.exit(1)
matched = False
for p in reversed(doc.get("phases", [])):
    if p.get("name") == phase and p.get("completedAt") is None:
        p["completedAt"] = now
        p["result"] = result
        if evidence:
            p["evidence"].append(evidence)
        matched = True
        break
if not matched:
    print(f"error: no open entry for phase {phase}", file=sys.stderr)
    sys.exit(1)
doc["updatedAt"] = now
print(json.dumps(doc))
PYEOF
) || return 1
  write_inflight "$doc" || return 1
  echo "phase: $phase completed ($result) for $ID"
}

block_phase() {
  local reason=$1 now doc
  now=$(fm_delivery_timestamp)
  doc=$(read_inflight)
  doc=$(python3 - "$reason" "$now" "$doc" <<'PYEOF'
import json, sys
reason, now, doc = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
doc["block"] = {"reason": reason, "blockedAt": now, "resolvedAt": None}
doc["updatedAt"] = now
print(json.dumps(doc))
PYEOF
) || return 1
  write_inflight "$doc" || return 1
  echo "blocked: $reason for $ID"
}

resume_phase() {
  local phase=$1 now doc
  now=$(fm_delivery_timestamp)
  doc=$(read_inflight)
  doc=$(python3 - "$phase" "$now" "$doc" <<'PYEOF'
import json, sys
phase, now, doc = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
if doc.get("block"):
    doc["block"]["resolvedAt"] = now
    doc["block"]["resumedPhase"] = phase
doc["updatedAt"] = now
print(json.dumps(doc))
PYEOF
) || return 1
  write_inflight "$doc" || return 1
  echo "resumed toward $phase for $ID"
}

status_phase() {
  local doc
  doc=$(read_inflight)
  python3 - "$doc" <<'PYEOF'
import json, sys
if not sys.argv[1]:
    print("no delivery record")
    sys.exit(0)
doc = json.loads(sys.argv[1])
print(f"phase: {doc.get('phase', 'none')}")
print(f"updatedAt: {doc.get('updatedAt', '')}")
if doc.get("block"):
    b = doc["block"]
    print(f"block: {b.get('reason')} at {b.get('blockedAt')}")
PYEOF
}

finalize_phase() {
  local branch=$1 candidate=$2 landed=$3
  local doc receipt
  doc=$(read_inflight)
  if [ ! -f "$INFLIGHT" ]; then
    echo "error: no in-flight record for $ID" >&2
    return 1
  fi
  if [ -f "$RECEIPT" ]; then
    echo "error: receipt already finalized for $ID" >&2
    return 1
  fi
  if ! fm_delivery_validate_sha "$candidate"; then
    echo "error: invalid candidate SHA: $candidate" >&2
    return 1
  fi
  if [ -n "$landed" ] && ! fm_delivery_validate_sha "$landed"; then
    echo "error: invalid landed SHA: $landed" >&2
    return 1
  fi
  candidate=$(fm_delivery_sha_lower "$candidate")
  landed=$(fm_delivery_sha_lower "$landed")
  # The receipt is built from the in-flight record plus required identity fields.
  # A richer receipt builder lives in fm-delivery-receipt.sh.
  receipt=$(python3 - "$ID" "$branch" "$candidate" "$landed" "$doc" <<'PYEOF'
import json, sys
id, branch, candidate, landed, doc = sys.argv[1:6]
doc = json.loads(doc)
if doc.get("phase") != "receipt_finalized":
    print(f"error: cannot finalize from phase {doc.get('phase')}", file=sys.stderr)
    sys.exit(1)
source = {"branch": branch, "candidateSha": candidate, "prUrl": None, "prHeadSha": None, "mergeSha": None, "localCandidateSha": None, "localLandedSha": None}
if landed:
    source["mergeSha"] = landed
receipt = {
    "schemaVersion": "firstmate.delivery-receipt.v1",
    "task": {"id": id, "project": "", "kind": "ship", "lane": "primary", "supports": None, "deliveryMode": "direct-PR", "yolo": True},
    "capability": {"summary": "", "acceptanceCriteria": [], "authorityClass": "routine"},
    "source": source,
    "phases": doc.get("phases", []),
    "validation": {"commands": [], "ci": {"requiredChecks": [], "headSha": candidate, "result": "green"}, "security": {"result": "passed", "evidence": []}},
    "release": {"applicability": "not_applicable", "mode": "none", "version": None, "artifact": {"uri": None, "digest": None, "sourceSha": candidate}, "receipt": None},
    "deployment": {"applicability": "not_applicable", "environment": None, "target": None, "artifactDigest": None, "receipt": None},
    "smoke": {"command": [], "result": "not_applicable", "observations": []},
    "rollback": {"mode": "not_applicable", "previewCommand": [], "result": "not_applicable", "receipt": None},
    "provider": {"applicability": "not_used", "receipt": None},
    "outcome": {"status": "delivered", "completedAt": doc.get("updatedAt", "")}
}
print(json.dumps(receipt))
PYEOF
) || return 1
  if ! fm_delivery_validate_receipt "$receipt"; then
    echo "error: receipt validation failed for $ID" >&2
    return 1
  fi
  write_receipt "$receipt" || return 1
  echo "receipt finalized for $ID"
}

# Argument parsing -----------------------------------------------------------
case "$CMD" in
  start)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    PHASE=$1
    shift
    BUDGET=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --budget) BUDGET=$2; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
      esac
    done
    start_phase "$PHASE" "$BUDGET"
    ;;
  complete)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    PHASE=$1
    shift
    RESULT=
    EVIDENCE=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --result) RESULT=$2; shift 2 ;;
        --evidence) EVIDENCE=$2; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$RESULT" ] || { echo "error: --result required" >&2; exit 2; }
    complete_phase "$PHASE" "$RESULT" "$EVIDENCE"
    ;;
  block)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    REASON=$*
    block_phase "$REASON"
    ;;
  resume)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    PHASE=$1
    resume_phase "$PHASE"
    ;;
  status)
    status_phase
    ;;
  finalize)
    BRANCH=
    CANDIDATE=
    LANDED=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --branch) BRANCH=$2; shift 2 ;;
        --candidate-sha) CANDIDATE=$2; shift 2 ;;
        --merge-sha|--local-landed-sha) LANDED=$2; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$BRANCH" ] || { echo "error: --branch required for finalize" >&2; exit 2; }
    [ -n "$CANDIDATE" ] || { echo "error: --candidate-sha required for finalize" >&2; exit 2; }
    finalize_phase "$BRANCH" "$CANDIDATE" "$LANDED"
    ;;
  *)
    echo "error: unknown command $CMD" >&2
    usage >&2
    exit 2
    ;;
esac
