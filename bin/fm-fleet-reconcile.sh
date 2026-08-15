#!/usr/bin/env bash
# fm-fleet-reconcile.sh - preservation-first fleet integrity actions.
#
# Usage:
#   fm-fleet-reconcile.sh scan [--json|--check]
#   fm-fleet-reconcile.sh recover-returned-secondmate <id>
#
# Scan is read-only. Returned-secondmate recovery delegates all task cleanup to
# fm-teardown.sh, which owns the identity, endpoint, lease, and route proofs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-fleet-reconcile.sh scan [--json|--check]
       fm-fleet-reconcile.sh recover-returned-secondmate <id>

Use scan for a read-only integrity report. The returned-secondmate action is
only for a home whose Firstmate seed receipt, empty returned shape, absent
runtime endpoint, and absent Treehouse lease all match exactly; it refuses
ambiguous or arbitrary missing homes and never uses --force.
EOF
}

case "${1:-}" in
  scan)
    shift
    case "${1:---compact}" in
      --json|--check|--compact) exec "$SCRIPT_DIR/fm-fleet-integrity.sh" "$1" ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  recover-returned-secondmate)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    exec "$SCRIPT_DIR/fm-teardown.sh" "$2" --recover-returned-secondmate
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
