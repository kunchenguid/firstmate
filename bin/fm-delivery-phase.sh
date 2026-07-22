#!/usr/bin/env bash
# Manage the results-first delivery phase lifecycle for a ship task.
# Usage:
#   fm-delivery-phase.sh init <task-id> --project <name> --delivery-mode <mode> --yolo <on|off>
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

if ! fm_delivery_validate_id "$ID"; then
  echo "error: invalid task id: $ID" >&2
  exit 2
fi

INFLIGHT="$STATE/$ID.delivery.json"
RECEIPT_DIR="$DATA/$ID"
RECEIPT="$RECEIPT_DIR/delivery-receipt.json"
LOCK="$STATE/$ID.delivery.lock"

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
  mkdir -p "$STATE" || return 1
  chmod 700 "$STATE" || return 1
  tmp=$(mktemp "$INFLIGHT.tmp.XXXXXX") || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_delivery_atomic_replace "$tmp" "$INFLIGHT" 0600 || return 1
}

# Atomic write of the final receipt with mode 0600.
write_receipt() {
  local content=$1
  local tmp
  mkdir -p "$RECEIPT_DIR" || return 1
  chmod 700 "$RECEIPT_DIR" || return 1
  tmp=$(mktemp "$RECEIPT.tmp.XXXXXX") || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! ln "$tmp" "$RECEIPT" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: receipt already finalized for $ID" >&2
    return 1
  fi
  rm -f "$tmp"
}

acquire_mutation_lock() {
  local attempt=0
  mkdir -p "$STATE" || return 1
  chmod 700 "$STATE" || return 1
  while [ "$attempt" -lt 50 ]; do
    if mkdir "$LOCK" 2>/dev/null; then
      trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "error: delivery record busy for $ID" >&2
  return 1
}

release_mutation_lock() {
  rmdir "$LOCK" 2>/dev/null || true
  trap - EXIT HUP INT TERM
}

init_delivery() {
  local project=$1 mode=$2 yolo=$3 now doc
  [ ! -e "$INFLIGHT" ] || { echo "error: delivery record already exists for $ID" >&2; return 1; }
  case "$mode" in direct-PR|no-mistakes|local-only) ;; *) echo "error: invalid delivery mode: $mode" >&2; return 1 ;; esac
  case "$yolo" in on|off) ;; *) echo "error: invalid yolo value: $yolo" >&2; return 1 ;; esac
  now=$(fm_delivery_timestamp)
  doc=$(python3 - "$ID" "$project" "$mode" "$yolo" "$now" <<'PYEOF'
import json, sys
id, project, mode, yolo, now = sys.argv[1:6]
print(json.dumps({
    "schemaVersion": "firstmate.delivery-receipt.v1",
    "task": {"id": id, "project": project, "kind": "ship", "lane": "primary", "supports": None, "deliveryMode": mode, "yolo": yolo == "on"},
    "capability": {"summary": "", "acceptanceCriteria": [], "authorityClass": "routine"},
    "phase": "accepted",
    "phases": [{"name": "accepted", "startedAt": now, "completedAt": now, "budgetSeconds": 0, "result": "passed", "evidence": []}],
    "updatedAt": now
}))
PYEOF
) || return 1
  write_inflight "$doc" || return 1
  echo "phase: accepted recorded for $ID"
}

start_phase() {
  local phase=$1 budget=${2:-}
  [ -n "$budget" ] || budget=$(phase_budget_seconds "$phase")
  local ts now doc
  case "$budget" in ''|*[!0-9]*) echo "error: budget must be a non-negative integer" >&2; return 1 ;; esac
  [ -f "$INFLIGHT" ] || { echo "error: no accepted delivery record for $ID" >&2; return 1; }
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
if current not in phases or phases.index(phase) != phases.index(current) + 1:
    print(f"error: next phase after {current or 'none'} is not {phase}", file=sys.stderr)
    sys.exit(1)
entries = doc.get("phases", [])
if not entries or entries[-1].get("name") != current or entries[-1].get("completedAt") is None:
    print(f"error: current phase {current} is not completed", file=sys.stderr)
    sys.exit(1)
if entries[-1].get("result") not in {"passed", "not_applicable"}:
    print(f"error: current phase {current} did not succeed", file=sys.stderr)
    sys.exit(1)
doc["phase"] = phase
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
  if [ -n "$evidence" ]; then
    if [ "${#evidence}" -ne 64 ] || printf '%s' "$evidence" | grep -q '[^0-9a-f]'; then
      echo "error: --evidence must be a lowercase SHA-256 digest" >&2
      return 1
    fi
  fi
  case "$phase:$result" in
    validating:passed|released:passed|deployed:passed|smoke_verified:passed)
      [ -n "$evidence" ] || { echo "error: passed $phase requires --evidence" >&2; return 1; }
      ;;
  esac
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
if phase == "validating" and result != "passed":
    print("error: validating must pass", file=sys.stderr)
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
if doc.get("phase") != phase:
    print(f"error: cannot resume {phase} while current phase is {doc.get('phase')}", file=sys.stderr)
    sys.exit(1)
if not doc.get("block") or doc["block"].get("resolvedAt"):
    print("error: delivery is not blocked", file=sys.stderr)
    sys.exit(1)
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
  "$SCRIPT_DIR/fm-delivery-receipt.sh" finalize "$ID" "$@"
}

# Argument parsing -----------------------------------------------------------
case "$CMD" in
  init)
    PROJECT=
    MODE=
    YOLO=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --project) PROJECT=$2; shift 2 ;;
        --delivery-mode) MODE=$2; shift 2 ;;
        --yolo) YOLO=$2; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$PROJECT" ] || { echo "error: --project required for init" >&2; exit 2; }
    [ -n "$MODE" ] || { echo "error: --delivery-mode required for init" >&2; exit 2; }
    [ -n "$YOLO" ] || { echo "error: --yolo required for init" >&2; exit 2; }
    acquire_mutation_lock || exit 1
    init_delivery "$PROJECT" "$MODE" "$YOLO"
    release_mutation_lock
    ;;
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
    acquire_mutation_lock || exit 1
    start_phase "$PHASE" "$BUDGET"
    release_mutation_lock
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
    acquire_mutation_lock || exit 1
    complete_phase "$PHASE" "$RESULT" "$EVIDENCE"
    release_mutation_lock
    ;;
  block)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    REASON=$*
    acquire_mutation_lock || exit 1
    block_phase "$REASON"
    release_mutation_lock
    ;;
  resume)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    PHASE=$1
    acquire_mutation_lock || exit 1
    resume_phase "$PHASE"
    release_mutation_lock
    ;;
  status)
    status_phase
    ;;
  finalize)
    finalize_phase "$@"
    ;;
  *)
    echo "error: unknown command $CMD" >&2
    usage >&2
    exit 2
    ;;
esac
