#!/usr/bin/env bash
# Firstmate brain helper: query and ingest firstmate_ops.db.
# Phase 4+5: live population at closure + brain-query helper.
#
# Usage:
#   fm-brain.sh query <query-text> [max-results]
#     Query firstmate_ops.db for relevant findings. Prints JSON results.
#   fm-brain.sh add <task-id> --kind scout|decision --summary "<text>" --ref "<url>"
#     Ingest a durable finding at closeout.
#     --kind: scout (adds to fm_operations) or decision (adds to fm_decisions)
#     --summary: the durable finding text
#     --ref: reference URL or file path (PR URL, report path)
#
# Requires: CROF venv, projects/crof checkout, firstmate_ops.db
# Returns 0 on success, non-zero on any failure (does not block the caller).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BRAIN="$DATA/brains/firstmate_ops.db"
CROF_VENV="/Users/walter/Dev/crof/.venv/bin/python"
CROF_PATH="$FM_ROOT/projects/crof"

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //'; exit 2; }

check_brain() {
  if [ ! -f "$BRAIN" ]; then
    echo "brain absent: $BRAIN" >&2
    return 1
  fi
  if [ ! -f "$CROF_VENV" ]; then
    echo "crof venv absent: $CROF_VENV" >&2
    return 1
  fi
  if [ ! -d "$CROF_PATH" ]; then
    echo "crof checkout absent: $CROF_PATH" >&2
    return 1
  fi
}

cmd_query() {
  local query="${1:-}" max="${2:-5}"
  [ -z "$query" ] && { echo "error: query text required" >&2; return 2; }
  check_brain || return 1
  local err rc
  err=$(mktemp "$FM_HOME/state/.brain-q-XXXXXX") || return 1
  rc=0
  (cd "$CROF_PATH" && HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    PYTHONNOUSERSITE=1 PYTHONPATH="$CROF_PATH" \
    /usr/bin/arch -arm64 "$CROF_VENV" \
    "$DATA/brains/query_firstmate_ops.py" "$query" "$max") 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$err" >&2
    rm -f "$err"
    echo '{"error":"brain query failed"}'
    return 1
  fi
  rm -f "$err"
}

cmd_add() {
  local task="" kind="scout" summary="" ref=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 ;;
      --summary) summary="${2:-}"; shift 2 ;;
      --ref) ref="${2:-}"; shift 2 ;;
      *) task="$1"; shift ;;
    esac
  done
  [ -z "$task" ] && { echo "error: task id required" >&2; return 2; }
  [ -z "$summary" ] && { echo "error: --summary required" >&2; return 2; }
  case "$kind" in
    scout|decision) ;;
    *) echo "error: --kind must be scout or decision" >&2; return 2 ;;
  esac
  check_brain || return 1
  local err rc suffix
  suffix=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8) || return 1
  err=$(mktemp "$FM_HOME/state/.brain-a-XXXXXX") || return 1
  rc=0
  (cd "$CROF_PATH" && HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    PYTHONNOUSERSITE=1 PYTHONPATH="$CROF_PATH" \
    /usr/bin/arch -arm64 "$CROF_VENV" \
    "$DATA/brains/ingest_finding.py" \
    --kind "$kind" --summary "$summary" --ref "$ref" \
    --claim-ref "closeout:$kind:$task:$suffix") 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$err" >&2
    rm -f "$err"
    echo '{"error":"ingest failed"}'
    return 1
  fi
  rm -f "$err"
}

case "${1:-}" in
  query) shift; cmd_query "$@" ;;
  add) shift; cmd_add "$@" ;;
  *) usage ;;
esac
