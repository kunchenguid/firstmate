#!/usr/bin/env bash
# fm-scorecard.sh - advisory outcome scorecard over fleet activity ledgers.
#
# Strictly read-only: it reads ledgers and the second mate registry, writes
# nothing, and never changes routing or dispatch configuration. Its numbers
# are advice for the captain's own judgment, never an automatic routing input.
# docs/fleet-ledger.md owns the ledger record contract and the scorecard's
# column definitions; bin/fm-scorecard.py owns the arithmetic.
#
# Usage:
#   fm-scorecard.sh [--home <dir>]... [--since <YYYY-MM-DD|epoch>] [--json]
#
# Without --home it reads this home's ledger plus the ledger of every local
# second mate home registered in data/secondmates.md; a remote route is listed
# as not read. Each --home replaces that default set with the named homes.
# A missing or empty ledger is reported as such, never an error.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_DATA_OVERRIDE resolve this
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 on success, 2 on a usage error, 1 when python3 is missing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF'
usage: fm-scorecard.sh [--home <dir>]... [--since <YYYY-MM-DD|epoch>] [--json]

Advisory outcome scorecard: per dispatch profile and task kind, how long tasks
took from dispatch to ready, how often they blocked or were relaunched, and how
many landed, were abandoned, or are still open. Read-only; it never routes work.

Default homes: this home plus every local second mate home in data/secondmates.md.
  --home <dir>   read this firstmate home instead (repeatable)
  --since <date> only tasks dispatched on or after this local date or Unix time
  --json         machine-readable output
EOF
}

args=()
homes=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }; homes+=("$2"); shift 2 ;;
    --since) [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }; args+=(--since "$2"); shift 2 ;;
    --json) args+=(--json); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "fm-scorecard: python3 is required" >&2; exit 1; }

if [ "${#homes[@]}" -gt 0 ]; then
  for h in "${homes[@]}"; do
    args+=(--ledger "$h" "${h%/}/state/fleet-ledger.jsonl")
  done
else
  args+=(--ledger this-home "$STATE/fleet-ledger.jsonl")
  if [ -f "$DATA/secondmates.md" ]; then
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "- "*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || continue
      if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
        args+=(--remote "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOST")
      else
        args+=(--ledger "$SECONDMATE_REGISTRY_ID" "${SECONDMATE_REGISTRY_HOME%/}/state/fleet-ledger.jsonl")
      fi
    done < "$DATA/secondmates.md"
  fi
fi

exec python3 "$SCRIPT_DIR/fm-scorecard.py" "${args[@]}"
