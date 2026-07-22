#!/usr/bin/env bash
# Validate and finalize a results-first delivery receipt.
# Usage:
#   fm-delivery-receipt.sh validate <task-id> [inflight|receipt]
#   fm-delivery-receipt.sh finalize <task-id> --branch <branch> --candidate-sha <sha> [--merge-sha <sha>|--local-landed-sha <sha>]
#
# validate reads state/<id>.delivery.json or data/<id>/delivery-receipt.json and
# applies the schema and exact-identity checks. finalize builds a receipt from
# the in-flight record plus provided identity fields and atomically publishes it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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

validate_inflight() {
  if [ ! -f "$INFLIGHT" ]; then
    echo "error: no in-flight record for $ID" >&2
    return 1
  fi
  local state_device
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_private_file_valid "$INFLIGHT" 600 "$state_device" || {
    echo "error: unsafe in-flight record for $ID" >&2
    return 1
  }
  fm_delivery_validate_inflight "$(cat "$INFLIGHT")"
}

validate_receipt() {
  local expected_mode='' expected_candidate=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expected-mode) expected_mode=$2; shift 2 ;;
      --expected-candidate-sha) expected_candidate=$2; shift 2 ;;
      *) echo "error: unknown validate option $1" >&2; return 2 ;;
    esac
  done
  if [ ! -f "$RECEIPT" ]; then
    echo "error: no receipt for $ID" >&2
    return 1
  fi
  local receipt data_device
  data_device=$(fm_pr_file_device "$DATA") || return 1
  fm_pr_private_file_valid "$RECEIPT" 600 "$data_device" || {
    echo "error: unsafe receipt for $ID" >&2
    return 1
  }
  receipt=$(cat "$RECEIPT") || return 1
  fm_delivery_validate_receipt "$receipt" "$ID" "$expected_mode" "$expected_candidate" || return 1
  fm_delivery_verify_receipt_evidence "$receipt" "$DATA" "$ID"
}

finalize_receipt() {
  local branch='' candidate='' merge='' local_landed='' rollback_evidence=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch) branch=$2; shift 2 ;;
      --candidate-sha) candidate=$2; shift 2 ;;
      --merge-sha) merge=$2; shift 2 ;;
      --local-landed-sha) local_landed=$2; shift 2 ;;
      --rollback-evidence) rollback_evidence=$2; shift 2 ;;
      *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$branch" ] || { echo "error: --branch required" >&2; exit 2; }
  [ -n "$candidate" ] || { echo "error: --candidate-sha required" >&2; exit 2; }
  fm_delivery_validate_sha "$candidate" || { echo "error: invalid candidate SHA" >&2; exit 2; }
  candidate=$(fm_delivery_sha_lower "$candidate")
  if [ -n "$merge" ]; then
    fm_delivery_validate_sha "$merge" || { echo "error: invalid merge SHA" >&2; exit 2; }
    merge=$(fm_delivery_sha_lower "$merge")
  fi
  if [ -n "$local_landed" ]; then
    fm_delivery_validate_sha "$local_landed" || { echo "error: invalid local landed SHA" >&2; exit 2; }
    local_landed=$(fm_delivery_sha_lower "$local_landed")
  fi
  if [ -n "$rollback_evidence" ]; then
    if [ "${#rollback_evidence}" -ne 64 ] || printf '%s' "$rollback_evidence" | grep -q '[^0-9a-f]'; then
      echo "error: --rollback-evidence must be a lowercase SHA-256 digest" >&2
      exit 2
    fi
  fi
  local source
  source=$(python3 - "$branch" "$candidate" "$merge" "$local_landed" <<'PYEOF'
import json, sys
branch, candidate, merge, local_landed = sys.argv[1:5]
doc = {"branch": branch, "candidateSha": candidate, "prUrl": None, "prHeadSha": None, "mergeSha": None, "localCandidateSha": None, "localLandedSha": None}
if merge:
    doc["mergeSha"] = merge
if local_landed:
    doc["localLandedSha"] = local_landed
print(json.dumps(doc))
PYEOF
)
  if [ -f "$RECEIPT" ]; then
    echo "error: receipt already exists for $ID" >&2
    return 1
  fi
  if [ ! -f "$INFLIGHT" ]; then
    echo "error: no in-flight record for $ID" >&2
    return 1
  fi
  local doc receipt mode
  doc=$(cat "$INFLIGHT")
  mode=$(python3 - "$doc" <<'PYEOF'
import json, sys
print(json.loads(sys.argv[1]).get("task", {}).get("deliveryMode", ""))
PYEOF
) || return 1
  case "$mode" in
    direct-PR|no-mistakes)
      [ -n "$merge" ] && [ -z "$local_landed" ] || { echo "error: $mode requires --merge-sha only" >&2; return 1; }
      ;;
    local-only)
      [ -n "$local_landed" ] && [ -z "$merge" ] || { echo "error: local-only requires --local-landed-sha only" >&2; return 1; }
      ;;
    *) echo "error: in-flight record has unsupported delivery mode" >&2; return 1 ;;
  esac
  receipt=$(python3 - "$ID" "$source" "$doc" "$rollback_evidence" <<'PYEOF'
import json, sys
id, source_json, doc_json, rollback_evidence = sys.argv[1:5]
source = json.loads(source_json)
doc = json.loads(doc_json)
phase_map = {phase.get("name"): phase for phase in doc.get("phases", [])}
def result(name):
    return phase_map.get(name, {}).get("result")
def evidence(name):
    return phase_map.get(name, {}).get("evidence", [])
release_app = "applicable" if result("released") == "passed" else "not_applicable"
deployment_app = "applicable" if result("deployed") == "passed" else "not_applicable"
if deployment_app == "applicable" and not rollback_evidence:
    print("error: applicable deployment requires --rollback-evidence", file=sys.stderr)
    sys.exit(1)
if deployment_app == "not_applicable" and rollback_evidence:
    print("error: rollback evidence is invalid when deployment is not applicable", file=sys.stderr)
    sys.exit(1)
receipt = {
    "schemaVersion": "firstmate.delivery-receipt.v1",
    "task": doc.get("task", {}),
    "capability": doc.get("capability", {"summary": "", "acceptanceCriteria": [], "authorityClass": "routine"}),
    "source": source,
    "phases": doc.get("phases", []),
    "validation": {"commands": [], "ci": {"requiredChecks": [], "headSha": source["candidateSha"], "result": result("validating"), "evidence": evidence("validating")}, "security": {"result": "not_assessed", "evidence": []}},
    "release": {"applicability": release_app, "mode": "project_owned" if release_app == "applicable" else "none", "version": None, "artifact": {"uri": None, "digest": None, "sourceSha": source["candidateSha"]}, "receipt": evidence("released")},
    "deployment": {"applicability": deployment_app, "environment": None, "target": None, "artifactDigest": None, "receipt": evidence("deployed")},
    "smoke": {"command": [], "result": result("smoke_verified"), "observations": evidence("smoke_verified")},
    "rollback": {"mode": "repair_proof" if deployment_app == "applicable" else "not_applicable", "previewCommand": [], "result": "passed" if rollback_evidence else "not_applicable", "receipt": rollback_evidence or None},
    "provider": {"applicability": "not_used", "receipt": None},
    "outcome": {"status": "delivered", "completedAt": doc.get("updatedAt", "")}
}
print(json.dumps(receipt))
PYEOF
)
  if ! fm_delivery_validate_receipt "$receipt" "$ID" "$mode" "$candidate"; then
    echo "error: receipt validation failed" >&2
    return 1
  fi
  if ! fm_delivery_verify_receipt_evidence "$receipt" "$DATA" "$ID"; then
    echo "error: receipt evidence validation failed" >&2
    return 1
  fi
  mkdir -p "$RECEIPT_DIR" || return 1
  chmod 700 "$RECEIPT_DIR" || return 1
  local tmp
  tmp=$(mktemp "$RECEIPT.tmp.XXXXXX") || return 1
  printf '%s\n' "$receipt" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! ln "$tmp" "$RECEIPT" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: receipt already exists for $ID" >&2
    return 1
  fi
  rm -f "$tmp"
  # Re-assert the mode explicitly rather than trusting ln/mktemp+umask
  # interaction across platforms: the receipt must be 0600 regardless of the
  # process umask in effect at write time.
  chmod 600 "$RECEIPT" || return 1
  echo "receipt finalized for $ID"
}

case "$CMD" in
  validate)
    KIND=${1:-inflight}
    [ "$#" -eq 0 ] || shift
    case "$KIND" in
      inflight) validate_inflight ;;
      receipt) validate_receipt "$@" ;;
      *) echo "error: validate kind must be inflight or receipt" >&2; exit 2 ;;
    esac
    ;;
  finalize)
    finalize_receipt "$@"
    ;;
  *)
    echo "error: unknown command $CMD" >&2
    usage >&2
    exit 2
    ;;
esac
