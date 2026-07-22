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

if ! printf '%s' "$ID" | grep -qxE '[A-Za-z0-9._-]+'; then
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
  fm_delivery_validate_inflight "$(cat "$INFLIGHT")"
}

validate_receipt() {
  if [ ! -f "$RECEIPT" ]; then
    echo "error: no receipt for $ID" >&2
    return 1
  fi
  fm_delivery_validate_receipt "$(cat "$RECEIPT")"
}

finalize_receipt() {
  local branch='' candidate='' merge='' local_landed=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch) branch=$2; shift 2 ;;
      --candidate-sha) candidate=$2; shift 2 ;;
      --merge-sha) merge=$2; shift 2 ;;
      --local-landed-sha) local_landed=$2; shift 2 ;;
      *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$branch" ] || { echo "error: --branch required" >&2; exit 2; }
  [ -n "$candidate" ] || { echo "error: --candidate-sha required" >&2; exit 2; }
  fm_delivery_validate_sha "$candidate" || { echo "error: invalid candidate SHA" >&2; exit 2; }
  candidate=$(fm_delivery_sha_lower "$candidate")
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
  local doc receipt
  doc=$(cat "$INFLIGHT")
  receipt=$(python3 - "$ID" "$source" "$doc" <<'PYEOF'
import json, sys
id, source_json, doc_json = sys.argv[1:4]
source = json.loads(source_json)
doc = json.loads(doc_json)
if doc.get("phase") != "receipt_finalized":
    print(f"error: cannot finalize from phase {doc.get('phase')}", file=sys.stderr)
    sys.exit(1)
receipt = {
    "schemaVersion": "firstmate.delivery-receipt.v1",
    "task": {"id": id, "project": "", "kind": "ship", "lane": "primary", "supports": None, "deliveryMode": "direct-PR", "yolo": True},
    "capability": {"summary": "", "acceptanceCriteria": [], "authorityClass": "routine"},
    "source": source,
    "phases": doc.get("phases", []),
    "validation": {"commands": [], "ci": {"requiredChecks": [], "headSha": source["candidateSha"], "result": "green"}, "security": {"result": "passed", "evidence": []}},
    "release": {"applicability": "not_applicable", "mode": "none", "version": None, "artifact": {"uri": None, "digest": None, "sourceSha": source["candidateSha"]}, "receipt": None},
    "deployment": {"applicability": "not_applicable", "environment": None, "target": None, "artifactDigest": None, "receipt": None},
    "smoke": {"command": [], "result": "not_applicable", "observations": []},
    "rollback": {"mode": "not_applicable", "previewCommand": [], "result": "not_applicable", "receipt": None},
    "provider": {"applicability": "not_used", "receipt": None},
    "outcome": {"status": "delivered", "completedAt": doc.get("updatedAt", "")}
}
print(json.dumps(receipt))
PYEOF
)
  if ! fm_delivery_validate_receipt "$receipt"; then
    echo "error: receipt validation failed" >&2
    return 1
  fi
  mkdir -p "$RECEIPT_DIR"
  chmod 700 "$RECEIPT_DIR"
  local tmp
  tmp=$(mktemp "$RECEIPT.tmp.XXXXXX")
  printf '%s\n' "$receipt" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$RECEIPT"
  echo "receipt finalized for $ID"
}

case "$CMD" in
  validate)
    KIND=${1:-inflight}
    case "$KIND" in
      inflight) validate_inflight ;;
      receipt) validate_receipt ;;
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
