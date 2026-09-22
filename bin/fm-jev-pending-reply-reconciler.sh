#!/usr/bin/env bash
# fm-jev-pending-reply-reconciler.sh - Shell wrapper for Jev Pending-Reply Auto-Reconciler.
#
# Inspects blocked pending-reply lines across seat status logs, distinguishing
# expired automated infrastructure/config pings from genuine actionable Captain
# work orders, and resolving superseded bookkeeping blocks.
#
# Usage:
#   fm-jev-pending-reply-reconciler.sh [--seat <name>] [--all] [--reconcile] [--json]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

RECONCILER_PY="$FM_ROOT/bin/fm-jev-pending-reply-reconciler.py"

if [ ! -x "$RECONCILER_PY" ]; then
  echo "error: $RECONCILER_PY is missing or not executable" >&2
  exit 1
fi

exec python3 "$RECONCILER_PY" "$@"
