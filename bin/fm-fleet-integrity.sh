#!/usr/bin/env bash
# fm-fleet-integrity.sh - bounded read-only integrity inspection.
#
# Usage: fm-fleet-integrity.sh [--json|--compact|--check]
#
# It reads the structured fleet snapshot in local-only mode so startup and
# operator inspection never contact a remote secondmate. It never changes the
# backlog, task metadata, endpoints, worktrees, or route registry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-fleet-integrity.sh [--json|--compact|--check]

Inspect backlog, task metadata, runtime, worktree, and persistent-route
consistency without changing any durable record.

--json    print the fm-fleet-integrity.v1 object
--compact print one actionable line per integrity failure (default)
--check   print the same compact report and exit 1 when a failure exists
EOF
}

case "${1:---compact}" in
  -h|--help) usage; exit 0 ;;
  --json|--compact|--check) MODE=$1 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || {
  echo "fm-fleet-integrity: jq not found" >&2
  exit 1
}

SNAPSHOT=$(FM_SNAPSHOT_LOCAL_ONLY=1 \
  FM_CREW_STATE_NM_TIMEOUT="${FM_FLEET_INTEGRITY_CREW_STATE_TIMEOUT:-1}" \
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || {
  echo "fm-fleet-integrity: fleet snapshot failed" >&2
  exit 1
}
INTEGRITY=$(printf '%s\n' "$SNAPSHOT" | jq -e '.integrity' 2>/dev/null) || {
  echo "fm-fleet-integrity: snapshot has no integrity object" >&2
  exit 1
}

if [ "$MODE" = --json ]; then
  printf '%s\n' "$INTEGRITY"
  exit 0
fi

if printf '%s\n' "$INTEGRITY" | jq -e '.valid == true' >/dev/null; then
  printf '%s\n' 'Fleet integrity: clear.'
  exit 0
fi

printf '%s\n' "$INTEGRITY" | jq -r '
  "Fleet integrity: attention required (" + ((.counts.issues // (.failures | length)) | tostring) + " issue(s)).",
  (.failures[] |
    "- [" + .classification + "] " + (.id // "route") + ": " + .reason + ". Action: " + (.action // "inspect the durable records."))
'

[ "$MODE" = --check ] && exit 1
exit 0
